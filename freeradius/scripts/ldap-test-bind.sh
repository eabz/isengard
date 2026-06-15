#!/bin/sh
# Test Google LDAP password for a user (same check FreeRADIUS does after search).
# Usage: ./scripts/ldap-test-bind.sh erbutcher
set -e

USER="$(echo "${1:?usage: $0 <username>}" | tr '[:upper:]' '[:lower:]')"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! docker inspect -f '{{.State.Running}}' freeradius 2>/dev/null | grep -q true; then
	echo "ERROR: freeradius container is not running. Try: docker compose up -d" >&2
	exit 1
fi

"${ROOT}/scripts/ldap-check.sh" || exit 1
echo ""

if [ -n "${LDAP_TEST_PASSWORD:-}" ]; then
	PASS="${LDAP_TEST_PASSWORD}"
else
	printf "Google password for %s: " "${USER}"
	stty -echo 2>/dev/null || true
	read -r PASS
	stty echo 2>/dev/null || true
	echo ""
fi

LDAP_CONF="${ROOT}/raddb/mods-available/ldap_google"

read_ldap_var() {
	grep -E "^[[:space:]]*$1[[:space:]]*=" "${LDAP_CONF}" \
		| head -1 \
		| sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/"
}

ldap_cmd() {
	docker exec -i freeradius ldapsearch -LLL -o ldif-wrap=no \
		-H ldap://127.0.0.1:1636 \
		"$@"
}

BASE_DN="$(read_ldap_var base_dn)"
BIND_DN="$(read_ldap_var identity)"
BIND_PW="$(read_ldap_var password)"

FILTERS="
(mail=${USER}@cedrosnorte.edu.mx)
(mail=${USER}@colegios-cedros-paseo.mx)
(uid=${USER})
"

echo "=== LDAP bind test: ${USER} ==="
echo ""

echo "--- Step 1: search (FreeRADIUS filters, one by one) ---"
ENTRY_DN=""
USER_MAIL=""
for FILTER in ${FILTERS}; do
	echo "filter: ${FILTER}"
	SEARCH="$(ldap_cmd -D "${BIND_DN}" -w "${BIND_PW}" -b "${BASE_DN}" "${FILTER}" dn uid mail 2>&1)" || true
	if echo "${SEARCH}" | grep -qiE 'Can.t contact LDAP|Connection refused|restarting'; then
		echo "${SEARCH}"
		echo ""
		echo "ERROR: cannot reach stunnel/LDAP."
		exit 1
	fi
	if echo "${SEARCH}" | grep -q '^dn:'; then
		echo "${SEARCH}"
		ENTRY_DN="$(echo "${SEARCH}" | awk '/^dn: / { sub(/^dn: /,""); print; exit }')"
		USER_MAIL="$(echo "${SEARCH}" | awk '/^mail: / { sub(/^mail: /,""); print; exit }')"
		break
	fi
	echo "(not found)"
done

if [ -z "${ENTRY_DN}" ]; then
	echo ""
	echo "FAIL: user not found with any FreeRADIUS LDAP filter."
	exit 1
fi

echo ""
echo "Found DN: ${ENTRY_DN}"
echo "mail:     ${USER_MAIL}"
echo ""

echo "--- Step 2: bind as user (password check) ---"
try_bind() {
	BIND_AS="$1"
	echo "Trying bind as: ${BIND_AS}"
	OUT="$(ldap_cmd -D "${BIND_AS}" -w "${PASS}" -b "${BASE_DN}" -s base '(objectClass=*)' dn 2>&1)" || true
	echo "${OUT}"
	if echo "${OUT}" | grep -qiE 'ldap_bind: Success|result: 0 Success'; then
		return 0
	fi
	return 1
}

# Same order as FreeRADIUS inner-tunnel (mail address, not DN).
for BIND_AS in "${USER_MAIL}"; do
	[ -z "${BIND_AS}" ] && continue
	if try_bind "${BIND_AS}"; then
		echo ""
		echo "OK: password accepted for ${USER}"
		exit 0
	fi
done

echo ""
echo "FAIL: Google LDAP rejected the password for ${USER_MAIL}."
echo ""
echo "Check:"
echo "  1. Sign in at https://mail.google.com with the same password"
echo "  2. Admin > LDAP > Access permissions on user's OU:"
echo "     'Verify user credentials' (not just Read)"
echo "  3. If password was just changed, wait 10 minutes and retry"
exit 1
