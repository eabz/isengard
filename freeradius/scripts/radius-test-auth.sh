#!/bin/sh
# Test the FreeRADIUS LDAP auth path through the inner-tunnel (PAP on :18120).
# This exercises the same authorize/authenticate logic WiFi uses inside the
# EAP-TTLS tunnel, without needing an EAP supplicant. (Full WiFi = the phone.)
#
# Runs from inside the container, so the request comes from 127.0.0.1
# (client localhost, secret testing123).
#
# Usage:
#   LDAP_TEST_PASSWORD='pass' ./scripts/radius-test-auth.sh eberrueta
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

echo "=== inner-tunnel auth test: ${USER} ==="
echo "Path: docker exec -> 127.0.0.1:18120 (PAP)"

PASS_B64="$(printf '%s' "${LDAP_TEST_PASSWORD}" | base64 | tr -d '\n')"

OUT="$(docker exec \
	-e "RADIUS_USER=${USER}" \
	-e "RADIUS_PASS_B64=${PASS_B64}" \
	freeradius sh -ec '
pass=$(printf "%s" "$RADIUS_PASS_B64" | base64 -d)
user=$(printf "%s" "$RADIUS_USER" | sed "s/\"/\\\\\"/g")
pass=$(printf "%s" "$pass" | sed "s/\"/\\\\\"/g")
printf "User-Name = %s\nUser-Password = \"%s\"\n" "$user" "$pass" > /tmp/radtest.txt
echo "--- request ---"; cat /tmp/radtest.txt
echo "--- response ---"
radclient -x 127.0.0.1:18120 auth testing123 -f /tmp/radtest.txt 2>&1
rc=$?
rm -f /tmp/radtest.txt
exit $rc
' 2>&1)" || true

echo "${OUT}"

if echo "${OUT}" | grep -q 'Received Access-Accept'; then
	echo ""
	echo "OK: FreeRADIUS accepted (Google LDAP path works for ${USER})."
	exit 0
fi

if echo "${OUT}" | grep -qiE 'No reply from server|Connection refused'; then
	echo ""
	echo "ERROR: no reply on :18120. Check the container is healthy:"
	echo "  docker logs freeradius --tail 50"
	exit 1
fi

echo ""
echo "FAIL: FreeRADIUS rejected ${USER}."
echo "  Verify the LDAP side directly: ./scripts/ldap-test.sh ${USER}"
exit 1
