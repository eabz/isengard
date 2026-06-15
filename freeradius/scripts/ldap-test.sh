#!/bin/sh
# Google Secure LDAP health + user check, mirroring exactly what FreeRADIUS does:
#   1. service-account bind (is stunnel/LDAP reachable?)
#   2. search (uid=<user>)  -> show DN, mail, OU
#   3. bind as that user's DN with the password (the real auth check)
#
# Usage:
#   ./scripts/ldap-test.sh erbutcher
#   LDAP_TEST_PASSWORD='pass' ./scripts/ldap-test.sh erbutcher
set -e

USER="$(echo "${1:?usage: $0 <username>}" | tr '[:upper:]' '[:lower:]')"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LDAP_CONF="${ROOT}/raddb/mods-available/ldap_google"

if ! docker inspect -f '{{.State.Running}}' freeradius 2>/dev/null | grep -q true; then
	echo "ERROR: freeradius container is not running (docker compose up -d)." >&2
	exit 1
fi

read_var() {
	grep -E "^[[:space:]]*$1[[:space:]]*=" "${LDAP_CONF}" | head -1 \
		| sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/"
}

BASE_DN="$(read_var base_dn)"
BIND_DN="$(read_var identity)"
BIND_PW="$(read_var password)"

ldap() {
	docker exec -i freeradius ldapsearch -LLL -o ldif-wrap=no -H ldap://127.0.0.1:1636 "$@"
}

echo "=== Google LDAP test: ${USER} ==="
echo "base_dn: ${BASE_DN}"
echo ""

echo "--- 1. service-account bind ---"
SA="$(ldap -D "${BIND_DN}" -w "${BIND_PW}" -b "${BASE_DN}" -s base '(objectClass=*)' dn 2>&1)" || true
if echo "${SA}" | grep -qiE "Can.t contact LDAP|Connection refused"; then
	echo "${SA}"
	echo "FAIL: stunnel/LDAP not reachable on 127.0.0.1:1636."
	exit 1
fi
echo "OK: service account can bind."
echo ""

echo "--- 2. find the user (uid, then mail on each domain) ---"
ENTRY_DN=""
USER_MAIL=""
MATCHED=""
for FILTER in \
	"(uid=${USER})" \
	"(mail=${USER}@cedrosnorte.edu.mx)" \
	"(mail=${USER}@colegios-cedros-paseo.mx)"
do
	printf '  %-46s ' "${FILTER}"
	R="$(ldap -D "${BIND_DN}" -w "${BIND_PW}" -b "${BASE_DN}" "${FILTER}" dn uid mail 2>&1)" || true
	if echo "${R}" | grep -q '^dn:'; then
		echo "MATCH"
		ENTRY_DN="$(echo "${R}" | awk '/^dn: /{sub(/^dn: /,"");print;exit}')"
		USER_MAIL="$(echo "${R}" | awk '/^mail: /{sub(/^mail: /,"");print;exit}')"
		MATCHED="${FILTER}"
		break
	fi
	echo "no match"
done

if [ -z "${ENTRY_DN}" ]; then
	echo ""
	echo "FAIL: ${USER} is not visible to the LDAP client by uid OR mail."
	echo "  -> Access-permissions issue in Google Admin > Apps > LDAP > your client"
	echo "     > Access permissions. Permissions are PER-OU: the OU this user sits"
	echo "     in needs 'Read user information' + 'Verify user credentials', even"
	echo "     though the colegios domain lives under cedrosnorte."
	exit 1
fi

echo ""
echo "matched: ${MATCHED}"
echo "DN:      ${ENTRY_DN}"
echo "mail:    ${USER_MAIL}"
echo "OU:      $(echo "${ENTRY_DN}" | sed 's/^uid=[^,]*,//')"

case "${MATCHED}" in
	"(uid="*) ;;
	*)
		echo ""
		echo "NOTE: matched by MAIL, not uid. FreeRADIUS currently searches by uid,"
		echo "      so it needs the colegios mail lookup added to authenticate this user."
		;;
esac
echo ""

if [ -n "${LDAP_TEST_PASSWORD:-}" ]; then
	PASS="${LDAP_TEST_PASSWORD}"
else
	printf "Password for %s: " "${USER}"
	stty -echo 2>/dev/null || true
	read -r PASS
	stty echo 2>/dev/null || true
	echo ""
fi

echo "--- 3. bind as user (the real password check) ---"
echo "Binding as: ${ENTRY_DN}"
BIND="$(ldap -D "${ENTRY_DN}" -w "${PASS}" -b "${BASE_DN}" -s base '(objectClass=*)' dn 2>&1)" || true

if ! echo "${BIND}" | grep -qiE "Invalid credentials|ldap_bind|error"; then
	echo "OK: password accepted — WiFi will work for ${USER}."
	exit 0
fi

echo "${BIND}"
echo ""
echo "FAIL: Google rejected the password for this user."
echo "  - Confirm the user can sign in at https://mail.google.com"
echo "  - After an admin password reset, the user must log into Gmail once"
echo "  - 2-Step Verification can block LDAP bind for some accounts"
exit 1
