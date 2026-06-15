#!/bin/sh
# Test Google LDAP password for a user (same check FreeRADIUS does after search).
# Usage: ./scripts/ldap-test-bind.sh erbutcher
set -e

USER="$(echo "${1:?usage: $0 <username>}" | tr '[:upper:]' '[:lower:]')"
read -r -s -p "Google password for ${USER}: " PASS
echo ""

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LDAP_CONF="${ROOT}/raddb/mods-available/ldap_google"

read_ldap_var() {
	grep -E "^[[:space:]]*$1[[:space:]]*=" "${LDAP_CONF}" \
		| head -1 \
		| sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/"
}

ldap_cmd() {
	docker exec -i freeradius ldapsearch -LLL \
		-H ldap://127.0.0.1:1636 \
		"$@"
}

BASE_DN="$(read_ldap_var base_dn)"
BIND_DN="$(read_ldap_var identity)"
BIND_PW="$(read_ldap_var password)"

RADIUS_FILTER="(|(uid=${USER})(mail=${USER}@cedrosnorte.edu.mx)(mail=${USER}@colegios-cedros-paseo.mx)(mail=${USER}@babycedros.edu.mx)(mail=${USER}@piccolobambino.edu.mx)(mail=${USER}@cedrosnortekindergarten.edu.mx))"

echo "=== LDAP bind test: ${USER} ==="
echo ""

echo "--- Step 1: search (FreeRADIUS filter) ---"
SEARCH="$(ldap_cmd -D "${BIND_DN}" -w "${BIND_PW}" -b "${BASE_DN}" "${RADIUS_FILTER}" dn uid mail 2>&1)" || true
echo "${SEARCH}"

ENTRY_DN="$(echo "${SEARCH}" | awk '/^dn: / { sub(/^dn: /,""); print; exit }')"
USER_MAIL="$(echo "${SEARCH}" | awk '/^mail: / { sub(/^mail: /,""); print; exit }')"

if [ -z "${ENTRY_DN}" ]; then
	echo ""
	echo "FAIL: user not found with FreeRADIUS LDAP filter."
	echo "Run: ./scripts/ldap-test-user.sh ${USER}"
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
		OUT="$(docker exec freeradius ldapwhoami -H ldap://127.0.0.1:1636 \
			-D "${BIND_AS}" -w "${PASS}" 2>&1)" || true
		echo "${OUT}"
		if echo "${OUT}" | grep -qiE 'dn:|Success'; then
			return 0
		fi
		return 1
	}

	for BIND_AS in "${USER_MAIL}" "${ENTRY_DN}"; do
		[ -z "${BIND_AS}" ] && continue
		if try_bind "${BIND_AS}"; then
		echo ""
		echo "OK: password accepted for ${USER} (bind as ${BIND_AS})"
		echo "If WiFi still fails, the problem is EAP/TLS on the phone, not LDAP."
		exit 0
		fi
	done

echo ""
echo "FAIL: password rejected by Google LDAP."
echo ""
echo "Check in Google Admin > Apps > LDAP > Access permissions:"
echo "  OU for this user (e.g. Servicios) needs 'Verify user credentials'."
echo "  'Read user information' alone is not enough for WiFi login."
exit 1
