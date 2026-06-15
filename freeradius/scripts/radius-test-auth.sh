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

RADCLIENT="$(docker exec freeradius sh -c 'command -v radclient' 2>/dev/null || true)"
if [ -z "${RADCLIENT}" ]; then
	echo "ERROR: radclient not in container. Rebuild: docker compose up -d --build" >&2
	exit 1
fi

echo "=== FreeRADIUS inner-tunnel auth test: ${USER} ==="
echo "radclient: ${RADCLIENT}"

PASS_B64="$(printf '%s' "${LDAP_TEST_PASSWORD}" | base64 | tr -d '\n')"

OUT="$(docker exec \
	-e "RADIUS_USER=${USER}" \
	-e "RADIUS_PASS_B64=${PASS_B64}" \
	freeradius sh -ec "
pass=\$(printf '%s' \"\$RADIUS_PASS_B64\" | base64 -d)
user=\$(printf '%s' \"\$RADIUS_USER\" | sed 's/\"/\\\\\"/g')
pass=\$(printf '%s' \"\$pass\" | sed 's/\"/\\\\\"/g')
printf 'User-Name = %s\nUser-Password = \"%s\"\n' \"\$user\" \"\$pass\" > /tmp/radtest.txt
echo '--- radclient request ---'
cat /tmp/radtest.txt
echo '--- radclient response ---'
radclient -x 127.0.0.1:18120 auth testing123 -f /tmp/radtest.txt 2>&1
RC=\$?
rm -f /tmp/radtest.txt
exit \$RC
" 2>&1)" || RC=$?

RC="${RC:-0}"
echo "${OUT}"

if [ -z "${OUT}" ]; then
	echo ""
	echo "ERROR: empty output from radclient (exit ${RC})."
	echo "  docker compose up -d --build"
	echo "  docker logs freeradius --tail 50"
	exit 1
fi

if echo "${OUT}" | grep -q 'Access-Accept'; then
	echo ""
	echo "OK: FreeRADIUS accepted (WiFi LDAP path works)."
	exit 0
fi

if echo "${OUT}" | grep -qiE 'No reply from server|Connection refused|timed out'; then
	echo ""
	echo "ERROR: no RADIUS reply on 127.0.0.1:18120 (check clients.conf localhost + secret testing123)."
	exit 1
fi

if [ "${RC}" = 137 ] || echo "${OUT}" | grep -qiE 'OCI runtime|container.*restarting|connection reset'; then
	echo ""
	echo "ERROR: container crashed or restarted during test (exit ${RC})."
	echo "  docker logs freeradius --tail 80"
	echo "  If logs show many stunnel connections then 'exited with code 1', LDAP pools were too large."
	exit 1
fi

echo ""
echo "FAIL: FreeRADIUS rejected (exit ${RC})."
echo "Check output above for LDAP-UserDn / ldap: lines."
exit 1
