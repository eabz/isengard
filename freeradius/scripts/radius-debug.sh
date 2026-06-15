#!/bin/sh
# Run FreeRADIUS in full debug (-X) in a throwaway container and fire one
# inner-tunnel PAP request, so you can see EXACTLY why a user is accepted or
# rejected (the LDAP search, the bind identity, the bind result, Auth-Type).
#
# It runs alongside the live `freeradius` container without port conflicts
# (the inner tunnel + stunnel listen on 127.0.0.1 inside each container).
#
# Usage:
#   LDAP_TEST_PASSWORD='pass' ./scripts/radius-debug.sh erbutcher
set -e

USER="$(echo "${1:?usage: $0 <username>}" | tr '[:upper:]' '[:lower:]')"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${LDAP_TEST_PASSWORD:-}" ]; then
	printf "Password for %s: " "${USER}"
	stty -echo 2>/dev/null || true
	read -r LDAP_TEST_PASSWORD
	stty echo 2>/dev/null || true
	echo ""
fi
PASS_B64="$(printf '%s' "${LDAP_TEST_PASSWORD}" | base64 | tr -d '\n')"

docker compose -f "${ROOT}/docker-compose.yml" run --rm -T \
	-e DBG_USER="${USER}" \
	-e DBG_PASS_B64="${PASS_B64}" \
	--entrypoint /bin/sh freeradius -ec '
RADDB=/etc/freeradius
ln -sf ../mods-available/ldap_google "${RADDB}/mods-enabled/ldap_google" 2>/dev/null || true

stunnel4 /etc/stunnel/google-ldap.conf &
sleep 2

pass=$(printf "%s" "$DBG_PASS_B64" | base64 -d)
printf "User-Name = %s\nUser-Password = \"%s\"\n" "$DBG_USER" "$pass" > /tmp/t

freeradius -X > /tmp/fr.log 2>&1 &
FR=$!
i=0
while [ $i -lt 40 ]; do
	grep -q "Ready to process requests" /tmp/fr.log 2>/dev/null && break
	sleep 0.5; i=$((i+1))
done

radclient -x 127.0.0.1:18120 auth testing123 -f /tmp/t > /tmp/rc.log 2>&1 || true
sleep 1

echo "==================== radclient ===================="
cat /tmp/rc.log
echo ""
echo "============ FreeRADIUS -X (request trace) ============"
# Everything from the last request arrival to the end of the log.
awk "/Received Access-Request/{c++} c{print}" /tmp/fr.log | tail -n 200

kill "$FR" 2>/dev/null || true
'
