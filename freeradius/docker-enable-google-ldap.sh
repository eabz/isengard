#!/bin/sh
set -e

RADDB=/etc/raddb
DEFAULT="${RADDB}/sites-available/default"
EAP="${RADDB}/mods-available/eap"

ln -sf ../mods-available/ldap_google "${RADDB}/mods-enabled/ldap_google"
rm -f "${RADDB}/sites-enabled/inner-tunnel"
ln -sf ../sites-available/inner-tunnel-google "${RADDB}/sites-enabled/inner-tunnel"

if ! grep -q 'ldap_google' "${DEFAULT}"; then
	# PAP auth via Google LDAP in the default virtual server.
	sed -i '/^[[:space:]]*pap[[:space:]]*$/i\
\tif (&User-Password \&\& !control:Auth-Type) {\
\t\tupdate control {\
\t\t\t\&Auth-Type := ldap\
\t\t}\
\t}' "${DEFAULT}"

	sed -i '/^[[:space:]]*eap[[:space:]]*$/i\
\tAuth-Type LDAP {\
\t\tldap_google\
\t}' "${DEFAULT}"
fi

# EAP-TTLS with PAP inner tunnel (required for Google LDAP + WiFi).
sed -i 's/default_eap_type = mschapv2/default_eap_type = pap/' "${EAP}"
sed -i 's/default_eap_type = md5/default_eap_type = ttls/' "${EAP}"
