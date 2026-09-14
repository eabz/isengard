#!/bin/sh
# Install on the Linux Docker HOST, once. ACME credentials stay in acme/.
set -eu
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN="${1:?usage: sudo $0 <radius-hostname>}"
if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: run this installer as root on the Linux Docker host." >&2
	exit 1
fi
command -v systemctl >/dev/null
command -v docker >/dev/null
command -v openssl >/dev/null
python3 - "${ROOT}" "${DOMAIN}" <<'PY'
from pathlib import Path
import re
import sys
root, domain = sys.argv[1:]
domain = domain.lower()
if len(domain) > 253 or '.' not in domain or any(
    not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in domain.split('.')
):
    raise SystemExit('ERROR: expected a DNS hostname')
if any(c in root for c in '\n\r"\\'):
    raise SystemExit('ERROR: repository path contains characters unsupported by this installer')
Path('/etc/isengard-eap-renew.env').write_text(
    f'ISENGARD_RADIUS_DIR="{root}"\nRADIUS_HOSTNAME="{domain.lower()}"\n')
PY
install -m 644 "${ROOT}/systemd/isengard-eap-renew.service" /etc/systemd/system/
install -m 644 "${ROOT}/systemd/isengard-eap-renew.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now isengard-eap-renew.timer
echo "Installed daily renewal check. Run once now with:"
echo "  systemctl start isengard-eap-renew.service"
echo "Inspect results with: journalctl -u isengard-eap-renew.service"
