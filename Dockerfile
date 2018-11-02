FROM jgoerzen/debian-base-apache:stretch

COPY preinit/ /usr/local/preinit/
COPY conf-available/ /etc/apache2/conf-available/
COPY sites-available/ /etc/apache2/sites-available/
COPY cron.daily/ /etc/cron.daily/

RUN set -ex; \
    a2enmod proxy proxy_http proxy_wstunnel headers rewrite; \
    a2enconf docker-ssl docker-log; \
    mkdir /var/www/webproxy-root; \
    a2ensite solana-json-rpc-https-proxy; \
    touch /etc/apache2/local-certbot-domainlist.txt; \
    apache2ctl configtest; \
    /usr/local/bin/docker-wipelogs; \
    echo Ok

CMD ["/usr/local/bin/boot-debian-base"]
