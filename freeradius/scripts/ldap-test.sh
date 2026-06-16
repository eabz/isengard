#!/bin/sh
# Google Secure LDAP health + user check, mirroring exactly what FreeRADIUS does:
#   1. service-account bind (is stunnel/LDAP reachable?)
#   2. search the username across BOTH domains and list EVERY distinct account.
#      A bare username can be TWO DIFFERENT PEOPLE: uid=<user> in cedrosnorte AND
#      mail=<user>@colegios-cedros-paseo.mx in colegios. This step shows the
#      collision instead of stopping at the first hit.
#   3. bind with the given password against EACH account (DN bind for cedros,
#      email bind for colegios) so you can see WHICH person the password unlocks.
#
# Usage:
#   ./scripts/ldap-test.sh rgarcia                          # search both domains
#   ./scripts/ldap-test.sh rgarcia@colegios-cedros-paseo.mx # target one domain
#   ./scripts/ldap-test.sh rgarcia@cedrosnorte.edu.mx       # target the other
#   LDAP_TEST_PASSWORD='pass' ./scripts/ldap-test.sh rgarcia
set -e

RAW="$(echo "${1:?usage: $0 <username|username@domain>}" | tr '[:upper:]' '[:lower:]')"
# Optional @domain lets you target one specific account when the username
# collides across domains.
case "${RAW}" in
	*@*) USER="${RAW%@*}"; WANT_DOMAIN="${RAW#*@}" ;;
	*)   USER="${RAW}";    WANT_DOMAIN="" ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LDAP_CONF="${ROOT}/raddb/mods-available/ldap_google"
TAB="$(printf '\t')"

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

echo "=== Google LDAP test: ${RAW} ==="
echo "base_dn: ${BASE_DN}"
[ -n "${WANT_DOMAIN}" ] && echo "domain : ${WANT_DOMAIN} (targeted)"
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

# Which filters to try, based on whether a domain was requested. With no domain
# we deliberately try ALL of them (no early break) so a collision is visible.
case "${WANT_DOMAIN}" in
	"")
		set -- "(uid=${USER})" \
			"(mail=${USER}@cedrosnorte.edu.mx)" \
			"(mail=${USER}@colegios-cedros-paseo.mx)" ;;
	cedrosnorte.edu.mx)
		set -- "(uid=${USER})" "(mail=${USER}@cedrosnorte.edu.mx)" ;;
	colegios-cedros-paseo.mx)
		set -- "(mail=${USER}@colegios-cedros-paseo.mx)" ;;
	*)
		set -- "(mail=${USER}@${WANT_DOMAIN})" ;;
esac

echo "--- 2. find the user across domains (every distinct account) ---"
CAND="$(mktemp)"        # one record per DISTINCT account: DN \t MAIL \t FILTER
trap 'rm -f "${CAND}"' EXIT

for FILTER in "$@"; do
	printf '  %-46s ' "${FILTER}"
	R="$(ldap -D "${BIND_DN}" -w "${BIND_PW}" -b "${BASE_DN}" "${FILTER}" dn uid mail 2>&1)" || true
	if echo "${R}" | grep -q '^dn:'; then
		EDN="$(echo "${R}" | awk '/^dn: /{sub(/^dn: /,"");print;exit}')"
		EMAIL="$(echo "${R}" | awk '/^mail: /{sub(/^mail: /,"");print;exit}')"
		if grep -qF "${EDN}${TAB}" "${CAND}" 2>/dev/null; then
			echo "MATCH (same account as above)"
		else
			echo "MATCH"
			printf '%s\t%s\t%s\n' "${EDN}" "${EMAIL}" "${FILTER}" >> "${CAND}"
		fi
	else
		echo "no match"
	fi
done

N="$(wc -l < "${CAND}" | tr -d ' ')"
if [ "${N}" = "0" ]; then
	echo ""
	echo "FAIL: ${USER} is not visible to the LDAP client by uid OR mail."
	echo "  -> Access-permissions issue in Google Admin > Apps > LDAP > your client"
	echo "     > Access permissions. Permissions are PER-OU: the OU this user sits"
	echo "     in needs 'Read user information' + 'Verify user credentials', even"
	echo "     though the colegios domain lives under cedrosnorte."
	exit 1
fi

echo ""
echo "Found ${N} distinct account(s) for '${USER}':"
i=0
while IFS="${TAB}" read -r EDN EMAIL FILTER; do
	i=$((i+1))
	echo "  [${i}] DN:   ${EDN}"
	echo "      mail: ${EMAIL}"
	echo "      OU:   $(echo "${EDN}" | sed 's/^uid=[^,]*,//')"
	echo "      via:  ${FILTER}"
done < "${CAND}"

if [ "${N}" -gt 1 ]; then
	echo ""
	echo "!! COLLISION: '${USER}' maps to ${N} DIFFERENT people across the two"
	echo "!! domains. With username-only login, the inner-tunnel searches uid"
	echo "!! (cedrosnorte) FIRST, so the cedrosnorte account always wins and the"
	echo "!! colegios account can never authenticate. To let the colegios user in,"
	echo "!! they must log in as '${USER}@colegios-cedros-paseo.mx' AND the"
	echo "!! inner-tunnel must route that domain straight to the email bind."
fi
echo ""

if [ -n "${LDAP_TEST_PASSWORD:-}" ]; then
	PASS="${LDAP_TEST_PASSWORD}"
else
	printf "Password to test against the account(s) above: "
	stty -echo 2>/dev/null || true
	read -r PASS
	stty echo 2>/dev/null || true
	echo ""
fi

echo "--- 3. bind as each account (which one does this password unlock?) ---"
ANY_OK=""
i=0
while IFS="${TAB}" read -r EDN EMAIL FILTER; do
	i=$((i+1))
	# Mirror production: colegios binds as the email, cedrosnorte binds as the DN.
	case "${EMAIL}" in
		*@colegios-cedros-paseo.mx) ORDER="${EMAIL} ${EDN}" ;;
		*)                          ORDER="${EDN} ${EMAIL}" ;;
	esac
	echo "  [${i}] ${EDN}"
	for BID in ${ORDER}; do
		[ -n "${BID}" ] || continue
		printf '      bind as %s ... ' "${BID}"
		B="$(bind_test "${BID}" "${PASS}")" || true
		if echo "${B}" | grep -qiE "Invalid credentials|ldap_bind"; then
			INFO="$(echo "${B}" | sed -n 's/.*additional info: //p' | head -1)"
			echo "FAIL${INFO:+ ($INFO)}"
		else
			echo "OK  <= password belongs to THIS account"
			ANY_OK="${BID}"
			break
		fi
	done
done < "${CAND}"

if [ -n "${ANY_OK}" ]; then
	echo ""
	echo "OK: password accepted, binding as: ${ANY_OK}"
	if [ "${N}" -gt 1 ]; then
		case "${ANY_OK}" in
			*@colegios-cedros-paseo.mx)
				echo "    This is the COLEGIOS account. It will only authenticate over WiFi if"
				echo "    the user logs in as '${USER}@colegios-cedros-paseo.mx' and the"
				echo "    inner-tunnel routes that domain to the email bind (see issue notes)." ;;
			*)
				echo "    This is the CEDROSNORTE account (the one bare-username login resolves to)." ;;
		esac
	fi
	exit 0
fi

echo ""
echo "FAIL: the password did not bind for ANY of the ${N} account(s) above."
echo ""
echo "If search (Read) worked but every bind says Invalid credentials, the LDAP"
echo "client's 'Verify user credentials' permission probably does not cover the"
echo "user's OU. In Google Admin > Apps > LDAP > your client > Access permissions:"
echo "  - Read user information   : already covers this OU (search worked)"
echo "  - Verify user credentials : set to 'Entire domain' OR add the user's OU"
echo ""
echo "Otherwise the password is wrong for the account you intended — re-run with the"
echo "domain to be sure which person you are testing, e.g.:"
echo "  ./scripts/ldap-test.sh ${USER}@colegios-cedros-paseo.mx"
exit 1
