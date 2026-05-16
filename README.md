# OENY HRSZ WMS proxy — leírás

Lokális reverse proxy konténer, amivel az `oeny.hu` HRSZ WMS rétege
(`hrsz:foldreszlet`) használhatóvá válik QGIS-ben, annak ellenére, hogy a
szerver GetCapabilities szolgáltatása hibás.

## 1. Miért kell ez

Az `oeny.hu` GeoServer WMS-e három állapotot mutat:

- A **GetMap** működik. Bizonyított: a böngészőből másolt `curl` egy
  érvényes 26 KB-os PNG-t adott vissza (`SERVICE=WMS&REQUEST=GetMap`).
- A **WMS GetCapabilities** nem működik. `java.lang.IllegalArgumentException:
  Null charset name` hibát dob.
- A **GeoWebCache WMTS GetCapabilities** sem működik (külön teszttel
  ellenőrizve).

A `Null charset name` oka **szerveroldali konfigurációs hiba**: a GeoServer
globális „Character set" beállítása üres, ezért a capabilities-transformer
`Charset.forName(null)`-t hív. Ez a GeoServer saját globális beállításából
jön, nem a kérésből — semmilyen kliensoldali fejléccel nem kerülhető meg.
Referencia: OSGeo Discourse, „GSCloud WFS: IllegalArgumentException: Null
charset name" (2026-01), a megoldás a GeoServer admin felületén a Character
set mező UTF-8-ra állítása.

A GetMap viszont bináris PNG-t ad vissza, nem megy át a hibás XML
capabilities-transformeren — ezért működik, miközben a GetCapabilities nem.

A QGIS standard „Add WMS Layer" folyamata kötelezően egy működő
GetCapabilities-re épül a rétegek felsorolásához. Ezért kell a proxy.

## 2. Hogyan működik

Egy nginx konténer ül a QGIS és az `oeny.hu` közé:

- `REQUEST=GetCapabilities` kérésre egy **kézzel írt, érvényes WMS 1.1.1
  capabilities XML-t** ad vissza, ami a `hrsz:foldreszlet` réteget hirdeti,
  és a saját proxy-URL-re mutat.
- Minden más kérést (GetMap) **továbbít** az `oeny.hu`-ra, és közben
  beinjektálja a `Referer` fejlécet, ami az eredeti működő `curl`-ben is
  szerepelt.

A capabilities szándékosan **WMS 1.1.1**, nem 1.3.0. Indok: a bizonyítottan
működő kérés 1.1.x szemantikájú volt (`SRS` + `BBOX=minx,miny,maxx,maxy`),
és az 1.3.0 az EPSG:23700 (EOV) vetületnél tengelysorrend-hibát hozna be.
Az 1.1.1 hirdetésével a QGIS a bizonyítottan jó útvonalon kommunikál.

```
QGIS ──GetCapabilities──> [nginx proxy] ──> statikus 1.1.1 XML
QGIS ──GetMap──────────-> [nginx proxy] ──Referer-rel──> oeny.hu GeoServer ──PNG──>
```

## 3. Fájlok

| Fájl | Szerep |
|---|---|
| `Containerfile` | nginx:alpine alap + envsubst, a fájlok bemásolása |
| `nginx-default.conf` | GetCapabilities elfogás + GetMap proxy + Referer-injektálás |
| `capabilities.xml.template` | Hamisított WMS 1.1.1 capabilities, `${PUBLIC_BASE}` helykitöltővel |
| `entrypoint.sh` | A sablon behelyettesítése, majd nginx indítás |
| `README.md` | Ez a leírás |

Mind az öt fájl egy mappában legyen.

## 4. Build és futtatás (Podman)

```
podman build -t oeny-wms-proxy -f Containerfile .
podman run --rm -p 8088:8088 oeny-wms-proxy
```

A `docker.io/library/...` teljes image-nevet a Containerfile szándékosan
kiírja: a Podman a rövid neveken (főleg Windowson) hibázni szokott.

A konténer a 8088-as porton figyel. Leállítás: Ctrl+C (a `--rm` miatt
takarít maga után).

## 5. Konfiguráció

Egyetlen környezeti változó van: `PUBLIC_BASE`. Ez kerül a hamis
capabilities OnlineResource mezőjébe, tehát ide fogja a QGIS küldeni a
GetMap kéréseket.

- Alap: `http://localhost:8088` — ha a QGIS ugyanazon a gépen fut.
- Más gép/VM esetén indításkor írd felül:

```
podman run --rm -p 8088:8088 -e PUBLIC_BASE=http://192.168.1.50:8088 oeny-wms-proxy
```

Ha rosszul állítod be, a QGIS a GetCapabilities-t még megkapja, de a
GetMap-eket egy elérhetetlen címre küldi, és üres marad a réteg.

## 6. Ellenőrzés (QGIS előtt kötelező)

### 6.1 A hamis GetCapabilities megjön-e

```
curl -s "http://localhost:8088/wms?SERVICE=WMS&REQUEST=GetCapabilities" | head -5
```

Várt: `<WMT_MS_Capabilities version="1.1.1">` XML, az `xlink:href`-ben a
`PUBLIC_BASE` már behelyettesítve. Ha `${PUBLIC_BASE}` literál marad benne,
az envsubst nem futott le rendesen.

### 6.2 A teljes lánc (GetMap a proxyn át)

```
curl -s -o teszt2.png "http://localhost:8088/wms?SERVICE=WMS&VERSION=1.1.0&REQUEST=GetMap&LAYERS=hrsz:foldreszlet&STYLES=&FORMAT=image/png&TRANSPARENT=true&SRS=EPSG:23700&WIDTH=512&HEIGHT=512&BBOX=633411.7197869457,196681.363328252,633717.1256306232,196986.7691719294"
file teszt2.png
```

Várt: `PNG image data`, kb. 25–27 KB — ugyanaz, mint az eredeti `teszt.png`.
Ha XML vagy `ServiceException` jön, akkor a Referer-injektálás vagy a proxy
útvonal a hibás; ez a kimenet kell a további diagnózishoz.

Ne lépj QGIS-re, amíg a 6.2 nem ad PNG-t.

## 7. QGIS beállítás

1. Layer → Add Layer → Add WMS/WMTS Layer → New
2. Name: `OENY HRSZ` (tetszőleges)
3. URL: `http://localhost:8088/wms`
4. OK → Connect
5. Válaszd ki a `hrsz:foldreszlet` réteget → Add
6. Réteg CRS és projekt CRS: `EPSG:23700`

A QGIS a hamis capabilities miatt 1.1.1-et fog beszélni. Referer mezőt a
QGIS-ben **nem** kell kitölteni — azt a proxy injektálja.

## 8. Hibakeresés

| Tünet | Ok | Teendő |
|---|---|---|
| `podman build` rövid-név hiba | Podman registry-policy | A Containerfile már teljes nevet használ; ne írd át rövidre |
| 6.1 üres / `$PUBLIC_BASE` literál | envsubst nem futott | `entrypoint.sh` jogosultság, `gettext` csomag megléte |
| 6.2 `ServiceException` jön | Referer nem ér célba vagy rossz upstream útvonal | `nginx-default.conf` `proxy_pass` és `Referer` sor ellenőrzése |
| 6.2 timeout | upstream nem elérhető a konténerből | Hálózat/DNS a Podman gépen (Windows: WSL) |
| QGIS réteget lát, de üres térkép | rossz `PUBLIC_BASE` | `-e PUBLIC_BASE=...` a tényleges elérési címre |
| QGIS „layer not queryable" | szándékos (`queryable="0"`) | nem hiba, a megjelenítést nem érinti |

## 9. Korlátok és a valódi megoldás

Ez egy **kerülőmegoldás**, nem javítás. Amíg fut a proxy, működik; ha más
gépről kell elérni, az a gép is a proxyn át lássa.

A valódi javítás szerveroldali és triviális: az `oeny.hu` GeoServer admin
felületén a globális „Character Set" mezőt `UTF-8`-ra állítani (vagy REST
API-n `PUT /geoserver/rest/settings` a `<charset>UTF-8</charset>` értékkel).
Ez után a natív WMS és WMTS GetCapabilities is működik, és a proxy
elhagyható. Ha van elérésed az üzemeltetőhöz, ez a helyes út — a proxy csak
addig kell, amíg ez nem történik meg.
