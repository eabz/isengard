#!/bin/sh
# Generate a SELF-SIGNED EAP server certificate into raddb/certs/eap/.
#
# This is the fallback the container also creates automatically. Devices will
# either prompt to trust it or need the ca.pem installed. For a no-prompt
# experience use a public cert instead: scripts/issue-eap-cert.sh
#
# Usage:
#   ./scripts/gen-eap-cert.sh [radius-hostname]
set -e

CN="${1:-radius.cedrosnorte.edu.mx}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EAPDIR="${ROOT}/raddb/certs/eap"

mkdir -p "${EAPDIR}"

EXT="$(mktemp)"
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "${CN}" > "${EXT}"

echo "Generating self-signed EAP cert for CN=${CN} in ${EAPDIR}"

openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout "${EAPDIR}/ca.key" -out "${EAPDIR}/ca.pem" \
	-days 3650 -subj "/CN=Isengard RADIUS CA"

openssl req -newkey rsa:2048 -nodes \
	-keyout "${EAPDIR}/server.key" -out "${EAPDIR}/server.csr" \
	-subj "/CN=${CN}"

openssl x509 -req -in "${EAPDIR}/server.csr" \
	-CA "${EAPDIR}/ca.pem" -CAkey "${EAPDIR}/ca.key" -CAcreateserial \
	-out "${EAPDIR}/server.pem" -days 3650 -extfile "${EXT}"

rm -f "${EAPDIR}/server.csr" "${EXT}"
chmod 600 "${EAPDIR}/server.key" "${EAPDIR}/ca.key" 2>/dev/null || true

echo "Done. Restart FreeRADIUS: docker compose restart freeradius"
