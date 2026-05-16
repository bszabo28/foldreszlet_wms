# OENY HRSZ WMS proxy — leírás

Lokális reverse proxy konténer, amellyel az `oeny.hu` HRSZ WMS-rétege
(`hrsz:foldreszlet`) használhatóvá válik QGIS-ben — annak ellenére, hogy a
szerver GetCapabilities-szolgáltatása hibás.

## 1. Miért van erre szükség

Az `oeny.hu` GeoServer WMS-e három különböző állapotot mutat:

- A **GetMap működik.** Ezt bizonyítja a böngészőből kimásolt `curl`:
  érvényes, 26 KB-os PNG-t adott vissza.
- A **WMS GetCapabilities nem működik.** `java.lang.IllegalArgumentException:
  Null charset name` hibával száll el.
- A **GeoWebCache WMTS GetCapabilities sem működik.** Ezt külön teszttel
  ellenőriztük.

A `Null charset name` oka szerveroldali konfigurációs hiba. A GeoServer
globális „Character set" beállítása üres, ezért a capabilities-t előállító
kód `Charset.forName(null)`-t hív. Ez az érték a GeoServer saját globális
beállításából származik, nem a kérésből, így semmilyen kliensoldali fejléccel
nem kerülhető meg. (Forrás: OSGeo Discourse, „GSCloud WFS:
IllegalArgumentException: Null charset name", 2026. január. A megoldás ott
is a GeoServer admin felületén a Character set mező UTF-8-ra állítása volt.)

A GetMap ezzel szemben bináris PNG-t küld vissza, amely nem megy át a hibás
XML-előállítón — ezért működik, miközben a GetCapabilities nem.

A QGIS csak akkor tud WMS-réteget felvenni, ha előbb sikeresen lekéri a
GetCapabilities-t, mert abból olvassa ki az elérhető rétegeket. Pontosan
ezért van szükség a proxyra.

## 2. Hogyan működik

A konténerben futó nginx a QGIS és az `oeny.hu` közé ékelődik:

- A GetCapabilities kérésre egy kézzel írt, érvényes **WMS 1.1.1
  capabilities-dokumentumot** ad vissza. Ez a `hrsz:foldreszlet` réteget
  hirdeti, és a proxy saját címére mutat.
- Minden más kérést (elsősorban a GetMap-et) változtatás nélkül továbbít az
  `oeny.hu`-ra, és közben hozzáadja a `Referer` fejlécet — ugyanazt, amely
  az eredeti, működő `curl`-ben is szerepelt.

A capabilities szándékosan **WMS 1.1.1**, nem 1.3.0. Ennek oka: a
bizonyítottan működő kérés 1.1.x szemantikájú volt
(`SRS` + `BBOX=minx,miny,maxx,maxy`), az 1.3.0 viszont az EPSG:23700 (EOV)
vetületnél felcseréli a tengelyek sorrendjét. Ha 1.1.1-et hirdetünk, a QGIS
a bizonyítottan jó úton kommunikál.

```
QGIS ──GetCapabilities──> [nginx proxy] ──> statikus 1.1.1 XML
QGIS ──GetMap──────────-> [nginx proxy] ──Referer-rel──> oeny.hu GeoServer ──PNG──>
```

## 3. Fájlok

| Fájl | Szerep |
|---|---|
| `Containerfile` | nginx:alpine alap, envsubst, a fájlok bemásolása |
| `nginx-default.conf` | A GetCapabilities elfogása, a GetMap továbbítása, a Referer hozzáadása |
| `capabilities.xml.template` | A hamisított WMS 1.1.1 capabilities, `${PUBLIC_BASE}` helykitöltővel |
| `entrypoint.sh` | A sablon behelyettesítése, majd az nginx indítása |
| `README.md` | Ez a leírás |

Mind az öt fájlnak egy mappában kell lennie.

## 4. Build és futtatás (Podman)

```
podman build -t oeny-wms-proxy -f Containerfile .
podman run --rm -p 8088:8088 oeny-wms-proxy
```

A Containerfile szándékosan a teljes `docker.io/library/...` nevet
használja, mert a Podman a rövid image-neveken — főleg Windowson — hibára
fut.

A konténer a 8088-as porton figyel. Leállítás Ctrl+C-vel; a `--rm` miatt a
konténer magától eltűnik.

## 5. Konfiguráció

Egyetlen környezeti változó van: `PUBLIC_BASE`. Ennek értéke kerül a hamis
capabilities OnlineResource mezőjébe, vagyis ide fogja a QGIS küldeni a
GetMap kéréseket.

- Alapérték: `http://localhost:8088` — akkor jó, ha a QGIS ugyanazon a
  gépen fut.
- Más gép vagy VM esetén indításkor írd felül:

```
podman run --rm -p 8088:8088 -e PUBLIC_BASE=http://192.168.1.50:8088 oeny-wms-proxy
```

Rossz beállítás esetén a QGIS a GetCapabilities-t még megkapja, de a
GetMap-eket elérhetetlen címre küldi, és a réteg üres marad.

## 6. Ellenőrzés (QGIS előtt kötelező)

Mindkét ellenőrzést futtasd le, mielőtt QGIS-hez nyúlnál.

### 6.1 Megjön-e a hamis GetCapabilities

```
curl -s "http://localhost:8088/wms?SERVICE=WMS&REQUEST=GetCapabilities" | head -5
```

Elvárt eredmény: a `<WMT_MS_Capabilities version="1.1.1">` XML, amelyben az
`xlink:href` értékébe a `PUBLIC_BASE` már be van helyettesítve. Ha a
`${PUBLIC_BASE}` szöveg literálként benne marad, az envsubst nem futott le
rendesen.

### 6.2 A teljes lánc: GetMap a proxyn keresztül

```
curl -s -o teszt2.png "http://localhost:8088/wms?SERVICE=WMS&VERSION=1.1.0&REQUEST=GetMap&LAYERS=hrsz:foldreszlet&STYLES=&FORMAT=image/png&TRANSPARENT=true&SRS=EPSG:23700&WIDTH=512&HEIGHT=512&BBOX=633411.7197869457,196681.363328252,633717.1256306232,196986.7691719294"
file teszt2.png
```

Elvárt eredmény: `PNG image data`, nagyjából 25–27 KB — ugyanaz, mint az
eredeti `teszt.png`. Ha XML vagy `ServiceException` jön vissza, akkor vagy a
Referer-injektálás, vagy a proxy útvonala hibás; ilyenkor erre a kimenetre
lesz szükség a további vizsgálathoz.

Amíg a 6.2 nem ad PNG-t, ne lépj tovább QGIS-re.

## 7. QGIS-beállítás

1. Layer → Add Layer → Add WMS/WMTS Layer → New
2. Name: `OENY HRSZ` (tetszőleges)
3. URL: `http://localhost:8088/wms`
4. OK → Connect
5. Válaszd ki a `hrsz:foldreszlet` réteget → Add
6. A réteg és a projekt CRS-e egyaránt `EPSG:23700`

A QGIS a hamis capabilities miatt 1.1.1-en fog kommunikálni. A Referer
mezőt a QGIS-ben nem kell kitölteni — azt a proxy adja hozzá.

## 8. Hibakeresés

| Tünet | Ok | Teendő |
|---|---|---|
| `podman build` rövid-név hiba | Podman registry-szabály | A Containerfile már teljes nevet használ; ne írd át rövidre |
| 6.1 üres vagy `$PUBLIC_BASE` literál | Az envsubst nem futott le | Ellenőrizd az `entrypoint.sh` jogosultságát és a `gettext` csomag meglétét |
| 6.2 `ServiceException`-t ad | A Referer nem ér célba, vagy rossz az upstream útvonal | Ellenőrizd a `nginx-default.conf` `proxy_pass` és `Referer` sorát |
| 6.2 időtúllépés | Az upstream nem érhető el a konténerből | Hálózat és DNS a Podman gépen (Windowson a WSL) |
| QGIS látja a réteget, de a térkép üres | Rossz `PUBLIC_BASE` | Indítsd `-e PUBLIC_BASE=...` kapcsolóval, a tényleges elérési címmel |
| QGIS „layer not queryable" | Szándékos (`queryable="0"`) | Nem hiba, a megjelenítést nem érinti |

## 9. Korlátok és a valódi megoldás

Ez kerülőmegoldás, nem javítás. Amíg a proxy fut, működik. Ha más gépről is
el kell érni a réteget, annak a gépnek is a proxyn keresztül kell látnia a
szolgáltatást.

A valódi javítás szerveroldali, és néhány másodperc: az `oeny.hu` GeoServer
admin felületén a globális „Character Set" mezőt UTF-8-ra kell állítani
(vagy REST API-n keresztül: `PUT /geoserver/rest/settings` a
`<charset>UTF-8</charset>` értékkel). Ezután a natív WMS és WMTS
GetCapabilities is működik, és a proxy elhagyható. Ha eléred az
üzemeltetőt, ez a helyes út; a proxy csak addig indokolt, amíg a szerver
javítása meg nem történik.
