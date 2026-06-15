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
MATCHED_FILTER=""
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
		MATCHED_FILTER="${FILTER}"
		break
	fi
	echo "(not found)"
done

if [ -z "${ENTRY_DN}" ]; then
	echo ""
	echo "FAIL: user not found with any FreeRADIUS LDAP filter."
	exit 1
fi

# Same mail address FreeRADIUS sets in inner-tunnel after ldap_find_*.
case "${MATCHED_FILTER}" in
	*colegios-cedros-paseo.mx*)
		RADIUS_BIND_ID="${USER}@colegios-cedros-paseo.mx"
		;;
	*cedrosnorte.edu.mx*)
		RADIUS_BIND_ID="${USER}@cedrosnorte.edu.mx"
		;;
	*)
		RADIUS_BIND_ID="${USER_MAIL}"
		;;
esac

echo ""
echo "Found DN:   ${ENTRY_DN}"
echo "mail:       ${USER_MAIL}"
echo "FreeRADIUS binds as: ${RADIUS_BIND_ID}"
echo ""

echo "--- Step 2: bind as user (password check) ---"
echo "Trying bind as: ${RADIUS_BIND_ID}"

BIND_OUT="$(ldap_cmd -D "${RADIUS_BIND_ID}" -w "${PASS}" -b "${BASE_DN}" -s base '(objectClass=*)' dn 2>&1)" || BIND_RC=$?
BIND_RC="${BIND_RC:-0}"

if [ "${BIND_RC}" -eq 0 ] && ! echo "${BIND_OUT}" | grep -qiE 'Invalid credentials|ldap_bind:.*(49|50)|AcceptSecurityContext'; then
	echo "${BIND_OUT}"
	echo ""
	echo "OK: password accepted for ${USER}"
	echo "(Successful bind returns the domain entry: dn: ${BASE_DN})"
	exit 0
fi

echo "${BIND_OUT}"
echo ""
echo "FAIL: Google LDAP rejected the password for ${RADIUS_BIND_ID}."
echo ""
echo "This is the same identity FreeRADIUS uses. If this fails, WiFi will fail too."
echo ""
echo "Check:"
echo "  1. Sign in at https://mail.google.com as ${RADIUS_BIND_ID}"
echo "  2. Admin > LDAP > OU permissions: Read + Verify user credentials"
echo "  3. After admin password reset, user must log in to Gmail once first"
echo "  4. Avoid special shell chars when typing; try:"
echo "       LDAP_TEST_PASSWORD='yourpass' ./scripts/ldap-test-bind.sh ${USER}"
exit 1
