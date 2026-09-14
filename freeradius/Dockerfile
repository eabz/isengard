FROM freeradius/freeradius-server:latest

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		stunnel4 supervisor ca-certificates openssl ldap-utils freeradius-utils python3 \
	&& rm -rf /var/lib/apt/lists/*

COPY raddb/ /etc/raddb/
COPY stunnel/ /etc/stunnel/
COPY supervisor/radius.conf /etc/supervisor/radius.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY scripts/lookup_user.py scripts/rotate-logs.sh scripts/radius-service.py /usr/local/bin/

RUN chmod +x /docker-entrypoint.sh /usr/local/bin/lookup_user.py /usr/local/bin/rotate-logs.sh

EXPOSE 1812/udp 1813/udp

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["-f"]
