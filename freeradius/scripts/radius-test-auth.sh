#!/bin/sh
# Test FreeRADIUS inner-tunnel LDAP auth (same path as WiFi EAP-TTLS+PAP).
# Usage: LDAP_TEST_PASSWORD='pass' ./scripts/radius-test-auth.sh eberrueta
set -e

USER="$(echo "${1:?usage: $0 <username>}" | tr '[:upper:]' '[:lower:]')"

if [ -z "${LDAP_TEST_PASSWORD:-}" ]; then
	printf "Password for %s: " "${USER}"
	stty -echo 2>/dev/null || true
	read -r LDAP_TEST_PASSWORD
	stty echo 2>/dev/null || true
	echo ""
fi

if ! docker inspect -f '{{.State.Running}}' freeradius 2>/dev/null | grep -q true; then
	echo "ERROR: freeradius container is not running." >&2
	exit 1
fi

echo "=== FreeRADIUS inner-tunnel auth test: ${USER} ==="
OUT="$(docker exec -i freeradius radclient -x 127.0.0.1:18120 auth testing123 2>&1 <<EOF
User-Name = ${USER}
User-Password = ${LDAP_TEST_PASSWORD}
EOF
)" || true

echo "${OUT}"

if echo "${OUT}" | grep -q 'Access-Accept'; then
	echo ""
	echo "OK: FreeRADIUS accepted (WiFi LDAP path works)."
	exit 0
fi

echo ""
echo "FAIL: FreeRADIUS rejected. Check LDAP-UserDn and password above."
exit 1
