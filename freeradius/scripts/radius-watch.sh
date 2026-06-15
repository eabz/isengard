#!/bin/sh
# Watch the LIVE RADIUS server in full debug (-X) while real access points /
# phones connect, so you can see the EAP-TTLS handshake, the certificate
# exchange, and the inner-tunnel auth.
#
# It stops the background container, runs one in debug on the real ports, and
# restores the background container when you press Ctrl-C.
#
# Usage:  ./scripts/radius-watch.sh    (then connect a phone; Ctrl-C when done)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

echo "Stopping the background freeradius container..."
docker compose stop freeradius >/dev/null 2>&1 || true

restore() {
	echo ""
	echo "Restoring the background freeradius container..."
	docker compose up -d freeradius >/dev/null 2>&1 || true
}
trap restore EXIT INT TERM

echo "Running 'freeradius -X' on the real ports — connect a device now."
echo "Press Ctrl-C to stop and put the normal container back."
echo "----------------------------------------------------------------"
docker compose run --rm --service-ports freeradius -X
