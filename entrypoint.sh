#!/bin/sh
set -e

mkdir -p /srv/www
envsubst '${PUBLIC_BASE}' < /srv/capabilities.xml.template > /srv/www/capabilities.xml

echo "PUBLIC_BASE = ${PUBLIC_BASE}"
echo "Generalt capabilities OnlineResource ellenorzese:"
grep -o 'xlink:href="[^"]*"' /srv/www/capabilities.xml | head -1

exec nginx -g 'daemon off;'
