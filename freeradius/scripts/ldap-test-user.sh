#!/bin/sh
# Test Google LDAP visibility (run from freeradius/ on the host).
#
#   ./scripts/ldap-test-user.sh erbutcher
#   ./scripts/ldap-test-user.sh --mail erbutcher@colegios-cedros-paseo.mx
#   ./scripts/ldap-test-user.sh --domains
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LDAP_CONF="${ROOT}/raddb/mods-available/ldap_google"

read_ldap_var() {
	grep -E "^[[:space:]]*$1[[:space:]]*=" "${LDAP_CONF}" \
		| head -1 \
		| sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/"
}

ldap_search() {
	docker exec freeradius ldapsearch -LLL -o ldif-wrap=no \
		-H ldap://127.0.0.1:1636 \
		-D "${BIND_DN}" \
		-w "${BIND_PW}" \
		-b "${BASE_DN}" \
		"$@"
}

BASE_DN="$(read_ldap_var base_dn)"
BIND_DN="$(read_ldap_var identity)"
BIND_PW="$(read_ldap_var password)"

if [ -z "${BASE_DN}" ] || [ -z "${BIND_DN}" ] || [ -z "${BIND_PW}" ]; then
	echo "ERROR: Could not read base_dn, identity, or password from ${LDAP_CONF}" >&2
	exit 1
fi

if echo "${BIND_DN}" | grep -q 'REPLACE_WITH'; then
	echo "ERROR: Edit raddb/mods-available/ldap_google with your Google LDAP credentials." >&2
	exit 1
fi

print_result() {
	RESULT="$1"
	echo "${RESULT}"
	if echo "${RESULT}" | grep -q '^dn:'; then
		return 0
	fi
	return 1
}

count_domains() {
	echo "=== Mail domains visible in LDAP ==="
	echo "base_dn: ${BASE_DN}"
	echo ""
	RESULT="$(ldap_search '(objectClass=posixAccount)' mail 2>&1)" || true
	echo "${RESULT}" | grep '^mail:' | sed 's/^mail:[[:space:]]*//' \
		| awk -F@ '{print "@" $2}' | sort | uniq -c | sort -rn
	echo ""
	COLEGIOS="$(echo "${RESULT}" | grep -c '@colegios-cedros-paseo.mx' || true)"
	echo "Users with @colegios-cedros-paseo.mx in LDAP: ${COLEGIOS}"
	if [ "${COLEGIOS}" = "0" ]; then
		echo ""
		echo "No colegios users in LDAP — add 'Read user information' +"
		echo "'Verify user credentials' on their OU in Admin > Apps > LDAP."
	fi
}

list_users() {
	echo "=== LDAP users visible to this client (first 25) ==="
	echo "base_dn: ${BASE_DN}"
	echo ""
	RESULT="$(ldap_search '(objectClass=posixAccount)' uid mail dn 2>&1)" || true
	echo "${RESULT}" | head -100
	echo ""
	COUNT="$(echo "${RESULT}" | grep -c '^dn:' || true)"
	echo "Total entries: ${COUNT}"
	if [ "${COUNT}" = "0" ]; then
		echo ""
		echo "No users visible — LDAP client likely has no OU with 'Read user information'."
	fi
}

test_mail() {
	MAIL="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
	echo "=== Google LDAP test for mail: ${MAIL} ==="
	echo "base_dn: ${BASE_DN}"
	echo ""
	echo "--- (mail=${MAIL}) ---"
	print_result "$(ldap_search "(mail=${MAIL})" uid mail dn 2>&1)" && exit 0
	echo "NOT FOUND"
	exit 1
}

test_user() {
	USER="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
	echo "=== Google LDAP test for: ${USER} ==="
	echo "base_dn: ${BASE_DN}"
	echo ""

	echo "--- (uid=${USER}) ---"
	if print_result "$(ldap_search "(uid=${USER})" uid mail dn 2>&1)"; then exit 0; fi
	echo "NOT FOUND"
	echo ""

	echo "--- (mail=${USER}@cedrosnorte.edu.mx) ---"
	if print_result "$(ldap_search "(mail=${USER}@cedrosnorte.edu.mx)" uid mail dn 2>&1)"; then exit 0; fi
	echo "NOT FOUND"
	echo ""

	echo "--- (mail=${USER}@colegios-cedros-paseo.mx) ---"
	if print_result "$(ldap_search "(mail=${USER}@colegios-cedros-paseo.mx)" uid mail dn 2>&1)"; then exit 0; fi
	echo "NOT FOUND"
	echo ""

	echo "User '${USER}' not visible in LDAP with uid or mail on either domain."
	echo ""
	echo "Next steps:"
	echo "  1. Test a cedrosnorte user who CAN connect:"
	echo "       ./scripts/ldap-test-user.sh <usuario-cedrosnorte>"
	echo "  2. List all users this LDAP client can see:"
	echo "       ./scripts/ldap-test-user.sh --list"
	echo "  3. If --list shows cedrosnorte but not colegios users, the LDAP client"
	echo "     is missing 'Read user information' on the colegios OU."
	echo "  4. In Admin, confirm PRIMARY email (LDAP mail = primary, not aliases)."
	exit 1
}

case "${1:-}" in
	--list|-l)
		list_users
		;;
	--domains|-d)
		count_domains
		;;
	--mail|-m)
		[ -n "${2:-}" ] || { echo "usage: $0 --mail user@domain.com" >&2; exit 1; }
		test_mail "$2"
		;;
	--help|-h)
		echo "usage: $0 <username>"
		echo "       $0 --mail user@domain.com"
		echo "       $0 --list"
		echo "       $0 --domains"
		;;
	'')
		echo "usage: $0 <username>" >&2
		exit 1
		;;
	*)
		test_user "$1"
		;;
esac
