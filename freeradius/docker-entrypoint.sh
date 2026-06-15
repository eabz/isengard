#!/bin/sh
set -e

# Resolve the active config dir (official image uses /etc/freeradius; /etc/raddb
# is usually a symlink to it).
if [ -d /etc/freeradius/mods-available ]; then
	RADDB=/etc/freeradius
elif [ -d /etc/raddb/mods-available ]; then
	RADDB=/etc/raddb
else
	echo "ERROR: could not find the FreeRADIUS config directory." >&2
	exit 1
fi
export RADDB

# --- Secrets from .env (referenced as $ENV{...} in the config) -------------
if [ -z "${GOOGLE_LDAP_IDENTITY:-}" ] || [ -z "${GOOGLE_LDAP_PASSWORD:-}" ]; then
	echo "ERROR: set GOOGLE_LDAP_IDENTITY and GOOGLE_LDAP_PASSWORD in .env." >&2
	exit 1
fi

# Default the AP secret so an empty value can't break config parsing.
: "${RADIUS_CLIENT_SECRET:=CHANGE_ME}"
export RADIUS_CLIENT_SECRET
if [ "${RADIUS_CLIENT_SECRET}" = "CHANGE_ME" ]; then
	echo "WARNING: RADIUS_CLIENT_SECRET not set in .env (using CHANGE_ME); APs will not authenticate." >&2
fi

# --- Enable the Google LDAP module -----------------------------------------
ln -sf ../mods-available/ldap_google "${RADDB}/mods-enabled/ldap_google"

# --- EAP server certificate -------------------------------------------------
# Use a real cert in certs/eap/ (see scripts/issue-eap-cert.sh). If none exists,
# generate a self-signed one so the server still starts (phones will prompt /
# need the CA until you install a public cert).
EAPDIR="${RADDB}/certs/eap"
mkdir -p "${EAPDIR}"
CN="${RADIUS_HOSTNAME:-radius.cedrosnorte.edu.mx}"

if [ ! -s "${EAPDIR}/server.pem" ] || [ ! -s "${EAPDIR}/server.key" ] || [ ! -s "${EAPDIR}/ca.pem" ]; then
	echo "EAP cert missing — generating a self-signed cert for CN=${CN}."
	EXT="$(mktemp)"
	printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "${CN}" > "${EXT}"

	openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout "${EAPDIR}/ca.key" -out "${EAPDIR}/ca.pem" \
		-days 3650 -subj "/CN=Isengard RADIUS CA" >/dev/null 2>&1

	openssl req -newkey rsa:2048 -nodes \
		-keyout "${EAPDIR}/server.key" -out "${EAPDIR}/server.csr" \
		-subj "/CN=${CN}" >/dev/null 2>&1

	openssl x509 -req -in "${EAPDIR}/server.csr" \
		-CA "${EAPDIR}/ca.pem" -CAkey "${EAPDIR}/ca.key" -CAcreateserial \
		-out "${EAPDIR}/server.pem" -days 3650 -extfile "${EXT}" >/dev/null 2>&1

	rm -f "${EAPDIR}/server.csr" "${EXT}"
fi

# FreeRADIUS drops to an unprivileged user before loading the cert, so the key
# must be readable by it. A Let's Encrypt key installed by acme.sh is root:600,
# which otherwise fails with "Permission denied".
FR_USER=""
for u in freerad freeradius radiusd; do
	if id "${u}" >/dev/null 2>&1; then FR_USER="${u}"; break; fi
done
if [ -n "${FR_USER}" ]; then
	chown -R "${FR_USER}":"${FR_USER}" "${EAPDIR}" 2>/dev/null || true
fi
chmod 750 "${EAPDIR}" 2>/dev/null || true
chmod 640 "${EAPDIR}/server.key" 2>/dev/null || true
chmod 644 "${EAPDIR}/server.pem" "${EAPDIR}/ca.pem" 2>/dev/null || true
rm -f "${EAPDIR}/ca.key" 2>/dev/null || true

# --- Google Secure LDAP over stunnel ---------------------------------------
CRT="${RADDB}/certs/google/ldap-client.crt"
KEY="${RADDB}/certs/google/ldap-client.key"

if [ ! -f "${CRT}" ] || [ ! -f "${KEY}" ]; then
	echo "ERROR: Google LDAP client certs missing." >&2
	echo "  Place ldap-client.crt and ldap-client.key in raddb/certs/google/" >&2
	exit 1
fi

echo "Starting stunnel TLS proxy to ldap.google.com..."
stunnel4 /etc/stunnel/google-ldap.conf &
STUNNEL_PID=$!
sleep 2
if ! kill -0 "${STUNNEL_PID}" 2>/dev/null; then
	echo "ERROR: stunnel exited unexpectedly." >&2
	exit 1
fi
echo "stunnel running (pid ${STUNNEL_PID}) on 127.0.0.1:1636"

# --- Validate config, then run ---------------------------------------------
echo "Validating FreeRADIUS configuration..."
if ! freeradius -XC; then
	echo "ERROR: FreeRADIUS configuration check failed (see above)." >&2
	exit 1
fi

echo "Configuration OK — starting FreeRADIUS."
exec freeradius "$@"
