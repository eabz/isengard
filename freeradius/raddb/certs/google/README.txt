Google Secure LDAP client certificates
========================================

Download from Google Admin:
  Directory > Apps > LDAP > your client > Download certificate

Rename and place the files here:
  ldap-client.crt   (client certificate)
  ldap-client.key   (private key)

Restrict permissions on the host:
  chmod 600 ldap-client.key

Then rebuild/restart FreeRADIUS:
  docker compose up -d --build
