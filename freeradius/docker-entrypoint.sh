#!/bin/sh
set -e

RADDB=/etc/raddb

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
exec freeradius "$@"
