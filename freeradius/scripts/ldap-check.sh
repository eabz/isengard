#!/bin/sh
# Quick health check: container and Google LDAP via stunnel.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LDAP_CONF="${ROOT}/raddb/mods-available/ldap_google"

read_ldap_var() {
	grep -E "^[[:space:]]*$1[[:space:]]*=" "${LDAP_CONF}" \
		| head -1 \
		| sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/"
}

echo "=== LDAP health check ==="

if ! docker inspect -f '{{.State.Running}}' freeradius 2>/dev/null | grep -q true; then
	echo "FAIL: freeradius container is not running."
	echo "  docker logs freeradius --tail 30"
	exit 1
fi
echo "OK: freeradius container running"

BIND_DN="$(read_ldap_var identity)"
BIND_PW="$(read_ldap_var password)"
BASE_DN="$(read_ldap_var base_dn)"

OUT="$(docker exec freeradius ldapsearch -LLL -o ldif-wrap=no \
	-H ldap://127.0.0.1:1636 \
	-D "${BIND_DN}" -w "${BIND_PW}" \
	-b "${BASE_DN}" -s base '(objectClass=*)' dn 2>&1)" || true

if echo "${OUT}" | grep -qiE 'Can.t contact LDAP|Connection refused'; then
	echo "FAIL: stunnel/LDAP not reachable on 127.0.0.1:1636"
	echo "${OUT}"
	echo "  docker logs freeradius --tail 30"
	exit 1
fi

if echo "${OUT}" | grep -qiE 'ldap_bind: Success|result: 0 Success'; then
	echo "OK: Google LDAP service-account bind via stunnel"
	exit 0
fi

echo "FAIL: cannot bind to Google LDAP:"
echo "${OUT}"
exit 1
