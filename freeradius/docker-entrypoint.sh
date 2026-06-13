#!/bin/sh
set -e

# Official image may use /etc/freeradius or /etc/raddb depending on version.
if [ -d /etc/freeradius/mods-available ]; then
	RADDB=/etc/freeradius
elif [ -d /etc/raddb/mods-available ]; then
	RADDB=/etc/raddb
else
	echo "ERROR: Could not find FreeRADIUS config directory." >&2
	exit 1
fi

export RADDB

if [ "${GOOGLE_LDAP_ENABLED:-0}" != "1" ]; then
	exec freeradius "$@"
fi

CRT="${RADDB}/certs/google/ldap-client.crt"
KEY="${RADDB}/certs/google/ldap-client.key"

if [ ! -f "${CRT}" ] || [ ! -f "${KEY}" ]; then
	echo "ERROR: Google LDAP is enabled but certificate files are missing." >&2
	echo "  Place ldap-client.crt and ldap-client.key in raddb/certs/google/" >&2
	echo "  Or set GOOGLE_LDAP_ENABLED=0 in .env to start without LDAP." >&2
	exit 1
fi

if grep -q 'REPLACE_WITH_GOOGLE_LDAP_USERNAME' "${RADDB}/mods-available/ldap_google"; then
	echo "ERROR: Edit raddb/mods-available/ldap_google with your Google LDAP credentials." >&2
	exit 1
fi

/docker-enable-google-ldap.sh

echo "Starting stunnel TLS proxy to ldap.google.com..."
stunnel4 /etc/stunnel/google-ldap.conf &
sleep 1

if ! ss -ltn 2>/dev/null | grep -q ':1636'; then
	if ! netstat -ltn 2>/dev/null | grep -q ':1636'; then
		echo "ERROR: stunnel failed to listen on 127.0.0.1:1636." >&2
		exit 1
	fi
fi

exec freeradius "$@"
