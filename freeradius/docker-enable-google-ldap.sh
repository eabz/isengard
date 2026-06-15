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
\t\t\t\&Stripped-User-Name := \"%{tolower:%{1}}\"\\
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

# Patch EAP on every start (idempotent):
#   outer default = ttls
#   inner ttls default = gtc (plain password via User-Password → Google LDAP)
#   remove mschap/mschapv2 inner negotiation
awk '
	BEGIN { in_eap=0; in_ttls=0; outer_done=0; skip=0 }
	/^[[:space:]]*eap[[:space:]]*\{/ { in_eap=1 }
	in_eap && /^[[:space:]]*default_eap_type/ && !outer_done {
		sub(/default_eap_type = .*/, "default_eap_type = ttls")
		outer_done=1
		in_eap=0
	}
	/^[[:space:]]*ttls[[:space:]]*\{/ { in_ttls=1 }
	in_ttls && /^[[:space:]]*default_eap_type/ {
		sub(/default_eap_type = .*/, "default_eap_type = gtc")
		in_ttls=0
	}
	/^[[:space:]]*mschapv2[[:space:]]*\{/ { skip=1; next }
	/^[[:space:]]*mschap[[:space:]]*\{/ { skip=1; next }
	skip && /^[[:space:]]*\}[[:space:]]*$/ { skip=0; next }
	skip { next }
	{ print }
' "${EAP}" > "${EAP}.google-ldap.tmp"
mv "${EAP}.google-ldap.tmp" "${EAP}"
grep -q "${EAP_MARKER}" "${EAP}" || printf '\n# %s\n' "${EAP_MARKER}" >> "${EAP}"

echo "Google LDAP configuration enabled (via stunnel on 127.0.0.1:1636)."
