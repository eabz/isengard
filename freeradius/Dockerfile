FROM freeradius/freeradius-server:latest

COPY raddb/ /etc/raddb/
COPY docker-enable-google-ldap.sh /docker-enable-google-ldap.sh
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /docker-enable-google-ldap.sh /docker-entrypoint.sh

EXPOSE 1812/udp 1813/udp

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["-f"]
