#!/bin/sh
set -e

RADDB=/etc/raddb

ln -sf ../mods-available/ldap_google "${RADDB}/mods-enabled/ldap_google"
rm -f "${RADDB}/sites-enabled/inner-tunnel"
ln -sf ../sites-available/inner-tunnel-google "${RADDB}/sites-enabled/inner-tunnel"

python3 <<'PY'
from pathlib import Path

default = Path("/etc/raddb/sites-available/default")
text = default.read_text()

ldap_authorize = """
\tif (&User-Password && !control:Auth-Type) {
\t\tupdate control {
\t\t\t&Auth-Type := ldap
\t\t}
\t}
"""

ldap_authenticate = """
\tAuth-Type LDAP {
\t\tldap_google
\t}
"""

if "ldap_google" not in text:
    text = text.replace("\n\tpap\n", f"\n{ldap_authorize}\n\tpap\n", 1)
    text = text.replace("\n\teap\n", f"{ldap_authenticate}\n\teap\n", 1)
    default.write_text(text)

eap = Path("/etc/raddb/mods-available/eap")
eap_text = eap.read_text()
eap_text = eap_text.replace("default_eap_type = mschapv2", "default_eap_type = pap")
eap_text = eap_text.replace("default_eap_type = md5", "default_eap_type = ttls")
eap.write_text(eap_text)
PY
