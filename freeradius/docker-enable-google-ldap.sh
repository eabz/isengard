#!/bin/sh
set -e

RADDB="${RADDB:-/etc/raddb}"
if [ ! -d "${RADDB}/mods-available" ] && [ -d /etc/freeradius/mods-available ]; then
	RADDB=/etc/freeradius
fi

DEFAULT="${RADDB}/sites-available/default"
EAP="${RADDB}/mods-available/eap"

ln -sf ../mods-available/ldap_google "${RADDB}/mods-enabled/ldap_google"
rm -f "${RADDB}/sites-enabled/inner-tunnel"
ln -sf ../sites-available/inner-tunnel-google "${RADDB}/sites-enabled/inner-tunnel"

if [ -f /etc/raddb/policy.d/google-ldap ] && [ -d "${RADDB}/policy.d" ] && [ "${RADDB}" != "/etc/raddb" ]; then
	cp /etc/raddb/policy.d/google-ldap "${RADDB}/policy.d/google-ldap"
fi

if ! grep -q 'google_ldap_strip_username' "${DEFAULT}"; then
	sed -i '/filter_username/a\	google_ldap_strip_username' "${DEFAULT}"
fi

if ! grep -q 'ldap_google' "${DEFAULT}"; then
	sed -i '/authorize {/,/^}/ {
		/^[[:space:]]*pap[[:space:]]*$/i\
\tif (&User-Password \&\& !control:Auth-Type) {\
\t\tupdate control {\
\t\t\t\&Auth-Type := ldap\
\t\t}\
\t}
	}' "${DEFAULT}"

	sed -i '/authenticate {/,/^}/ {
		/^[[:space:]]*eap[[:space:]]*$/i\
\tAuth-Type LDAP {\
\t\tldap_google\
\t}
	}' "${DEFAULT}"
fi

if grep -q 'default_eap_type = mschapv2' "${EAP}"; then
	sed -i 's/default_eap_type = mschapv2/default_eap_type = pap/' "${EAP}"
fi
if grep -q 'default_eap_type = md5' "${EAP}"; then
	sed -i 's/default_eap_type = md5/default_eap_type = ttls/' "${EAP}"
fi

echo "Google LDAP configuration enabled (via stunnel on 127.0.0.1:1636)."
