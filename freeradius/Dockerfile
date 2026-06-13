FROM freeradius/freeradius-server:latest

RUN apt-get update \
	&& apt-get install -y --no-install-recommends stunnel4 ca-certificates openssl \
	&& rm -rf /var/lib/apt/lists/*

COPY raddb/ /etc/raddb/
COPY stunnel/ /etc/stunnel/
COPY docker-enable-google-ldap.sh /docker-enable-google-ldap.sh
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /docker-enable-google-ldap.sh /docker-entrypoint.sh

EXPOSE 1812/udp 1813/udp

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["-f"]
