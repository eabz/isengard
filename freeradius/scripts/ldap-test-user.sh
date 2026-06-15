#!/bin/sh
# Test whether a Google LDAP user exists (run from freeradius/ on the host).
# Usage: ./scripts/ldap-test-user.sh jpsanchez
set -e

USER="${1:?usage: $0 <username>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LDAP_CONF="${ROOT}/raddb/mods-available/ldap_google"

read_ldap_var() {
	grep -E "^[[:space:]]*$2" "${LDAP_CONF}" \
		| head -1 \
		| sed -E "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/"
}

BASE_DN="$(read_ldap_var base_dn)"
BIND_DN="$(read_ldap_var identity)"
BIND_PW="$(read_ldap_var password)"

FILTER="(|(uid=${USER})(mail=${USER}@cedrosnorte.edu.mx)(mail=${USER}@colegios-cedros-paseo.mx))"

echo "Searching ${BASE_DN} for ${USER} ..."
docker exec freeradius ldapsearch -LLL \
	-H ldap://127.0.0.1:1636 \
	-D "${BIND_DN}" \
	-w "${BIND_PW}" \
	-b "${BASE_DN}" \
	"${FILTER}" \
	uid mail dn
