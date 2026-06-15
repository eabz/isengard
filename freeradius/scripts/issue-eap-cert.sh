#!/bin/sh
# Issue a publicly-trusted EAP server certificate with Let's Encrypt via
# Cloudflare DNS-01 (no need to expose the RADIUS server to the internet).
#
# Phones then validate the WiFi server cert with NO manual CA install:
#   Android: CA certificate = "Use system certificates", Domain = <hostname>
#
# Prereqs:
#   - The RADIUS hostname (e.g. radius.cedrosnorte.edu.mx) is a DNS record in a
#     zone managed by Cloudflare.
#   - A Cloudflare API token with "DNS:Edit" on that zone.
#
# Usage:
#   CF_Token='cloudflare-api-token' ./scripts/issue-eap-cert.sh radius.cedrosnorte.edu.mx
#
# We pass --dnssleep so acme.sh skips its DoH self-check (which fails with
# "error code: 7 / No DOH" when the container can't reach public DoH resolvers)
# and instead waits a fixed time before Let's Encrypt validates the TXT record.
# Override the wait with ACME_DNSSLEEP (seconds) if Cloudflare propagation is slow.
set -e

DOMAIN="${1:?usage: CF_Token=... $0 <radius-hostname>}"
: "${CF_Token:?set CF_Token to a Cloudflare API token with DNS:Edit}"
ACME_DNSSLEEP="${ACME_DNSSLEEP:-30}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACME_STATE="${ROOT}/acme"
EAP_OUT="${ROOT}/raddb/certs/eap"

mkdir -p "${ACME_STATE}" "${EAP_OUT}"

echo "=== Issuing Let's Encrypt cert for ${DOMAIN} (Cloudflare DNS-01) ==="

docker run --rm \
	-e CF_Token="${CF_Token}" \
	-v "${ACME_STATE}:/acme.sh" \
	neilpang/acme.sh --issue --dns dns_cf -d "${DOMAIN}" --server letsencrypt --keylength 2048 \
		--dnssleep "${ACME_DNSSLEEP}"

echo "=== Installing cert into raddb/certs/eap/ ==="

docker run --rm \
	-v "${ACME_STATE}:/acme.sh" \
	-v "${EAP_OUT}:/out" \
	neilpang/acme.sh --install-cert -d "${DOMAIN}" \
		--key-file       /out/server.key \
		--fullchain-file /out/server.pem \
		--ca-file        /out/ca.pem

echo ""
echo "Done. Now restart FreeRADIUS to load the new cert:"
echo "  docker compose restart freeradius"
echo ""
echo "On devices (EAP-TTLS + PAP):"
echo "  Android  : CA = 'Use system certificates', Domain = ${DOMAIN}, identity = username"
echo "  Windows  : validates automatically against the public CA"
echo "  iOS/macOS: one-time Trust prompt (or push a profile)"
echo ""
echo "Renewals: re-run this script (or schedule acme.sh) before the 90-day expiry,"
echo "then 'docker compose restart freeradius'."
