#!/bin/sh
set -e

RADDB="${RADDB:-/etc/raddb}"
if [ ! -d "${RADDB}/mods-available" ] && [ -d /etc/freeradius/mods-available ]; then
	RADDB=/etc/freeradius
fi

DEFAULT="${RADDB}/sites-available/default"
EAP="${RADDB}/mods-available/eap"

STRIP_MARKER="Google LDAP: strip @domain from username"
EAP_MARKER="Google LDAP EAP patched"

ln -sf ../mods-available/ldap_google "${RADDB}/mods-enabled/ldap_google"
rm -f "${RADDB}/sites-enabled/inner-tunnel"
ln -sf ../sites-available/inner-tunnel-google "${RADDB}/sites-enabled/inner-tunnel"

if ! grep -q "${STRIP_MARKER}" "${DEFAULT}"; then
	sed -i "/^[[:space:]]*suffix[[:space:]]*\$/i\\
\t# ${STRIP_MARKER}\\
\tif (\&User-Name =~ \\/^([^@]+)@\\/) {\\
\t\tupdate request {\\
\t\t\t\&Stripped-User-Name := \"%{1}\"\\
\t\t}\\
\t}\\
" "${DEFAULT}"
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
\t}\
\tAuth-Type PAP {\
\t\tldap_google\
\t}
	}' "${DEFAULT}"
fi

if ! grep -q "${EAP_MARKER}" "${EAP}"; then
	# TTLS inner tunnel must use PAP for Google LDAP (MS-CHAP will always fail).
	sed -i 's/default_eap_type = mschapv2/default_eap_type = pap/g' "${EAP}"
	sed -i 's/default_eap_type = md5/default_eap_type = ttls/g' "${EAP}"

	# Stop offering MS-CHAP inside the TTLS tunnel.
	sed -i '/^[[:space:]]*mschapv2[[:space:]]*{/,/^[[:space:]]*}[[:space:]]*$/d' "${EAP}"
	sed -i '/^[[:space:]]*mschap[[:space:]]*{/,/^[[:space:]]*}[[:space:]]*$/d' "${EAP}"

	printf '\n# %s\n' "${EAP_MARKER}" >> "${EAP}"
fi

echo "Google LDAP configuration enabled (via stunnel on 127.0.0.1:1636)."
