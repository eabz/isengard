#!/bin/sh
set -e
# TLS cache policy files must be private to the FreeRADIUS process.
umask 077

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

# Test-only clients (clients.conf: localhost + docker_bridge). Never used by
# real APs; default keeps scripts/radius-test-auth.sh etc. working out of the box.
: "${RADIUS_TEST_SECRET:=testing123}"
export RADIUS_TEST_SECRET

# --- Enable the Google LDAP module -----------------------------------------
ln -sf ../mods-available/ldap_google "${RADDB}/mods-enabled/ldap_google"

# --- Enable the inner-identity linelog module -------------------------------
ln -sf ../mods-available/linelog_inner "${RADDB}/mods-enabled/linelog_inner"
mkdir -p /var/log/freeradius/inner-identity

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
	chown -R "${FR_USER}":"${FR_USER}" /var/log/freeradius/inner-identity 2>/dev/null || true
fi
chmod 750 "${EAPDIR}" 2>/dev/null || true
chmod 640 "${EAPDIR}/server.key" 2>/dev/null || true
chmod 644 "${EAPDIR}/server.pem" "${EAPDIR}/ca.pem" 2>/dev/null || true
rm -f "${EAPDIR}/ca.key" 2>/dev/null || true

# --- Persistent EAP TLS session cache --------------------------------------
# The disk cache contains TLS session secrets. Keep it outside raddb and the
# log volume, and fail startup if its ownership/permissions cannot be set.
TLS_CACHE_DIR=/var/lib/freeradius/tlscache
mkdir -p "${TLS_CACHE_DIR}"
if [ -n "${FR_USER}" ]; then
	chown -R "${FR_USER}":"${FR_USER}" "${TLS_CACHE_DIR}"
fi
chmod 700 "${TLS_CACHE_DIR}"
# Also remove stale sessions at startup; rotate-logs.sh handles daily cleanup.
# 2880 minutes = the 48-hour lifetime in mods-available/eap.
find "${TLS_CACHE_DIR}" -type f \( -name '*.asn1' -o -name '*.vps' \) -mmin +2880 -delete

# --- Google Secure LDAP client certificate --------------------------------
CRT="${RADDB}/certs/google/ldap-client.crt"
KEY="${RADDB}/certs/google/ldap-client.key"

if [ ! -f "${CRT}" ] || [ ! -f "${KEY}" ]; then
	echo "ERROR: Google LDAP client certs missing." >&2
	echo "  Place ldap-client.crt and ldap-client.key in raddb/certs/google/" >&2
	exit 1
fi

# --- Supervise both foreground processes ----------------------------------
# Supervisor stays PID 1, reaps children, forwards shutdown signals and
# restarts stunnel independently. radius-service.py waits for its listener
# before validating/starting FreeRADIUS. Keep arguments as data, not shell code.
mkdir -p /run/freeradius-supervisor
chmod 700 /run/freeradius-supervisor
python3 - "$@" <<'PY'
import json
import sys
from pathlib import Path
Path('/run/freeradius-supervisor/radius-args.json').write_text(json.dumps(sys.argv[1:]))
PY
exec supervisord -c /etc/supervisor/radius.conf
