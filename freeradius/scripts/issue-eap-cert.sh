#!/bin/sh
# Initial DNS-01 issuance; validation and activation share the renewal pipeline.
# Use --install-only before the FreeRADIUS container is deployed.
# Usage: CF_Token=... ./scripts/issue-eap-cert.sh radius.example.org
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "${ROOT}/scripts/renew-eap-cert.py" --issue "$@"
