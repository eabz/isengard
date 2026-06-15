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

if ! docker exec freeradius test -x /usr/bin/radclient 2>/dev/null \
	&& ! docker exec freeradius test -x /usr/local/bin/radclient 2>/dev/null; then
	echo "ERROR: radclient not found in container." >&2
	exit 1
fi

echo "=== FreeRADIUS inner-tunnel auth test: ${USER} ==="

# Write attribute file inside container (handles special chars in passwords).
OUT="$(docker exec \
	-e "RADIUS_USER=${USER}" \
	-e "RADIUS_PASS=${LDAP_TEST_PASSWORD}" \
	freeradius sh -ec '
p="${RADIUS_PASS//\"/\\\"}"
printf "User-Name = %s\nUser-Password = \"%s\"\n" "$RADIUS_USER" "$p" > /tmp/radtest.txt
radclient -x 127.0.0.1:18120 auth testing123 -f /tmp/radtest.txt 2>&1
rm -f /tmp/radtest.txt
')" || true

echo "${OUT}"

if echo "${OUT}" | grep -q 'Access-Accept'; then
	echo ""
	echo "OK: FreeRADIUS accepted (WiFi LDAP path works)."
	exit 0
fi

if echo "${OUT}" | grep -qiE 'Error parsing|No reply|Connection refused|timed out'; then
	echo ""
	echo "ERROR: radclient could not talk to inner-tunnel on 127.0.0.1:18120"
	echo "  docker logs freeradius --tail 30"
	exit 1
fi

echo ""
echo "FAIL: FreeRADIUS rejected."
echo "Look for: LDAP-UserDn, ldap: ERROR, Access-Reject"
echo ""
echo "Tip: use env var to avoid shell escaping issues:"
echo "  LDAP_TEST_PASSWORD='your-password' ./scripts/radius-test-auth.sh ${USER}"
exit 1
