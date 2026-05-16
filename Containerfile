FROM docker.io/library/nginx:1.27-alpine

RUN apk add --no-cache gettext

COPY nginx-default.conf            /etc/nginx/conf.d/default.conf
COPY capabilities.xml.template     /srv/capabilities.xml.template
COPY entrypoint.sh                 /entrypoint.sh
RUN chmod +x /entrypoint.sh

# A capabilities OnlineResource-ben szereplo nyilvanos URL.
# Ha a QGIS nem ugyanazon a gepen fut, allitsd at: -e PUBLIC_BASE=http://<host-ip>:8088
ENV PUBLIC_BASE=http://localhost:8088

EXPOSE 8088
ENTRYPOINT ["/entrypoint.sh"]
