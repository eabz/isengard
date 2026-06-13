FROM freeradius/freeradius-server:latest

COPY raddb/ /etc/raddb/
COPY docker-enable-google-ldap.sh /docker-enable-google-ldap.sh

RUN chmod +x /docker-enable-google-ldap.sh && /docker-enable-google-ldap.sh

EXPOSE 1812/udp 1813/udp

CMD ["-f"]
