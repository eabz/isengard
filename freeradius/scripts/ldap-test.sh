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
# Service-account credentials now live in .env (the config reads them via $ENV{...}),
# so pull them from the running container's environment.
BIND_DN="$(docker exec freeradius printenv GOOGLE_LDAP_IDENTITY 2>/dev/null || true)"
BIND_PW="$(docker exec freeradius printenv GOOGLE_LDAP_PASSWORD 2>/dev/null || true)"

if [ -z "${BIND_DN}" ] || [ -z "${BIND_PW}" ]; then
	echo "ERROR: GOOGLE_LDAP_IDENTITY / GOOGLE_LDAP_PASSWORD are not set in the container." >&2
	echo "  Put them in .env, then: docker compose up -d" >&2
	exit 1
fi

ldap() {
	docker exec -i freeradius ldapsearch -LLL -o ldif-wrap=no -H ldap://127.0.0.1:1636 "$@"
}

# Pure bind check (no search permissions involved): prints "ldap_bind: ..." on
# failure, something else on success.
bind_test() {
	docker exec -i freeradius ldapwhoami -H ldap://127.0.0.1:1636 -D "$1" -w "$2" 2>&1
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

echo "--- 3. bind as user (password check: DN, then email) ---"
BIND_OK=""
for BID in "${ENTRY_DN}" "${USER_MAIL}"; do
	[ -n "${BID}" ] || continue
	printf '  bind as %s ... ' "${BID}"
	B="$(bind_test "${BID}" "${PASS}")" || true
	if echo "${B}" | grep -qiE "Invalid credentials|ldap_bind"; then
		INFO="$(echo "${B}" | sed -n 's/.*additional info: //p' | head -1)"
		echo "FAIL${INFO:+ ($INFO)}"
	else
		echo "OK"
		BIND_OK="${BID}"
		break
	fi
done

if [ -n "${BIND_OK}" ]; then
	echo ""
	echo "OK: password accepted, binding as: ${BIND_OK}"
	echo "    FreeRADIUS should bind this user in that form."
	exit 0
fi

OU_PATH="$(echo "${ENTRY_DN}" | sed 's/^uid=[^,]*,//')"
echo ""
echo "FAIL: both DN and email bind returned Invalid credentials for ${USER}."
echo ""
echo "Search (Read) works on this OU but credential verification does not —"
echo "almost always the LDAP client's 'Verify user credentials' permission does"
echo "NOT cover this user's OU:"
echo "    ${OU_PATH}"
echo ""
echo "In Google Admin > Apps > LDAP > your client > Access permissions:"
echo "  - Read user information   : already covers this OU (search worked)"
echo "  - Verify user credentials : set to 'Entire domain' OR add ou=Servicios"
echo ""
echo "Then confirm the password by signing in at https://mail.google.com as"
echo "${USER_MAIL} (after any admin reset, log into Gmail once first)."
exit 1
