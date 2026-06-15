#!/bin/sh
# Test whether a Google LDAP user exists (run from freeradius/ on the host).
# Usage: ./scripts/ldap-test-user.sh erbutcher
set -e

USER="${1:?usage: $0 <username>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LDAP_CONF="${ROOT}/raddb/mods-available/ldap_google"

read_ldap_var() {
	grep -E "^[[:space:]]*$1[[:space:]]*=" "${LDAP_CONF}" \
		| head -1 \
		| sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/"
}

BASE_DN="$(read_ldap_var base_dn)"
BIND_DN="$(read_ldap_var identity)"
BIND_PW="$(read_ldap_var password)"

if [ -z "${BASE_DN}" ] || [ -z "${BIND_DN}" ] || [ -z "${BIND_PW}" ]; then
	echo "ERROR: Could not read base_dn, identity, or password from ${LDAP_CONF}" >&2
	exit 1
fi

if echo "${BIND_DN}" | grep -q 'REPLACE_WITH'; then
	echo "ERROR: Edit raddb/mods-available/ldap_google with your Google LDAP credentials." >&2
	exit 1
fi

FILTER="(|(uid=${USER})(mail=${USER}@cedrosnorte.edu.mx)(mail=${USER}@colegios-cedros-paseo.mx))"

echo "Searching ${BASE_DN} for ${USER} ..."
docker exec freeradius ldapsearch -LLL \
	-H ldap://127.0.0.1:1636 \
	-D "${BIND_DN}" \
	-w "${BIND_PW}" \
	-b "${BASE_DN}" \
	"${FILTER}" \
	uid mail dn
