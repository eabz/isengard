#!/bin/sh
# Test whether a Google LDAP user exists (run from freeradius/ on the host).
# Usage: ./scripts/ldap-test-user.sh erbutcher
set -e

USER="${1:?usage: $0 <username>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LDAP_CONF="${ROOT}/raddb/mods-available/ldap_google"

read_ldap_var() {
	grep -E "^[[:space:]]*$1[[:space:]]*=" "${LDAP_CONF}" \
		| head -1 \
		| sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/"
}

ldap_search() {
	docker exec freeradius ldapsearch -LLL \
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

EXACT_FILTER="(|(uid=${USER})(mail=${USER}@cedrosnorte.edu.mx)(mail=${USER}@colegios-cedros-paseo.mx))"
WILDCARD_FILTER="(|(uid=*${USER}*)(mail=*${USER}*))"

echo "=== Google LDAP test for: ${USER} ==="
echo "base_dn: ${BASE_DN}"
echo ""

echo "--- Exact match (same filter as FreeRADIUS) ---"
echo "filter: ${EXACT_FILTER}"
RESULT="$(ldap_search "${EXACT_FILTER}" uid mail dn 2>&1)" || true
echo "${RESULT}"
echo ""

if echo "${RESULT}" | grep -q '^dn:'; then
	echo "OK: user found."
	exit 0
fi

if echo "${RESULT}" | grep -qi 'ldap_bind: Invalid credentials'; then
	echo "ERROR: LDAP service account bind failed. Check identity/password in ldap_google." >&2
	exit 1
fi

echo "NOT FOUND with exact filter."
echo "If you only see 'ldap_bind: Success', the service account works but this user"
echo "is not visible in LDAP (wrong username, OU without LDAP access, or suspended)."
echo ""

echo "--- Wildcard search (uid or mail contains '${USER}') ---"
echo "filter: ${WILDCARD_FILTER}"
WRESULT="$(ldap_search "${WILDCARD_FILTER}" uid mail dn 2>&1)" || true
echo "${WRESULT}"
echo ""

if echo "${WRESULT}" | grep -q '^dn:'; then
	echo "HINT: a similar account exists — check uid/mail above and use that username on WiFi."
	exit 0
fi

echo "No LDAP entry contains '${USER}'."
echo ""
echo "Check in Google Admin:"
echo "  1. User exists and is not suspended"
echo "  2. Apps > LDAP > your client > Access permissions:"
echo "     OU must have 'Read user information' AND 'Verify user credentials'"
echo "  3. User's real login (Admin > Users > user > Email / Username)"
exit 1
