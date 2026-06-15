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

# Base64 avoids shell escaping issues for special characters in passwords.
PASS_B64="$(printf '%s' "${LDAP_TEST_PASSWORD}" | base64 | tr -d '\n')"

OUT="$(docker exec \
	-e "RADIUS_USER=${USER}" \
	-e "RADIUS_PASS_B64=${PASS_B64}" \
	freeradius sh -ec '
pass=$(printf "%s" "$RADIUS_PASS_B64" | base64 -d)
user=$(printf "%s" "$RADIUS_USER" | sed "s/\"/\\\\\"/g")
pass=$(printf "%s" "$pass" | sed "s/\"/\\\\\"/g")
printf "User-Name = %s\nUser-Password = \"%s\"\n" "$user" "$pass" > /tmp/radtest.txt
radclient -x 127.0.0.1:18120 auth testing123 -f /tmp/radtest.txt 2>&1
rm -f /tmp/radtest.txt
')" || true

echo "${OUT}"

if echo "${OUT}" | grep -q 'Access-Accept'; then
	echo ""
	echo "OK: FreeRADIUS accepted (WiFi LDAP path works)."
	exit 0
fi

if echo "${OUT}" | grep -qiE 'Error parsing|No reply|Connection refused|timed out|Bad substitution'; then
	echo ""
	echo "ERROR: could not run radclient against inner-tunnel (127.0.0.1:18120)."
	echo "  docker logs freeradius --tail 30"
	exit 1
fi

echo ""
echo "FAIL: FreeRADIUS rejected."
echo "Look for: LDAP-UserDn, ldap: ERROR, Access-Reject"
echo ""
echo "Tip:"
echo "  LDAP_TEST_PASSWORD='your-password' ./scripts/radius-test-auth.sh ${USER}"
exit 1
