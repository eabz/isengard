# FreeRADIUS — WPA2/WPA3 Enterprise with Google Workspace Secure LDAP

WiFi authentication for **cedrosnorte.edu.mx** and **colegios-cedros-paseo.mx**
using **EAP-TTLS + PAP** against Google Secure LDAP. Users log in with their
**username only** (e.g. `jpsanchez`) — no domain.

## How it works

```
phone ──EAP-TTLS──> AP ──RADIUS──> FreeRADIUS (default site, outer)
                                        │  EAP/TLS tunnel
                                        ▼
                                   inner-tunnel  ──uid search + bind──> Google LDAP
                                        ▲                                   (via stunnel
                                        └── PAP username/password ──────────  127.0.0.1:1636)
```

Both domains live in **one** Google directory tree, so a single `(uid=…)` search
finds users from either domain. Authentication is "bind as user" (Google never
returns the password hash) — which is why the inner method must be **PAP**.

## Files

| File | Purpose |
|------|---------|
| `raddb/mods-available/ldap_google` | One LDAP module: uid search + bind-as-user. Put credentials here. |
| `raddb/sites-available/default` | Outer server (APs talk here). EAP only. Sets long `Session-Timeout`. |
| `raddb/sites-available/inner-tunnel` | Inner tunnel: normalize uid, LDAP auth. |
| `raddb/mods-available/eap` | EAP-TTLS + PAP, TLS session cache, points at `certs/eap/`. |
| `raddb/clients.conf` | APs + loopback test clients. |
| `stunnel/google-ldap.conf` | TLS proxy to `ldap.google.com:636`. |
| `docker-entrypoint.sh` | Enables ldap_google, makes the EAP cert, starts stunnel, validates, runs. |

## Setup

1. **Google LDAP credentials** — edit `raddb/mods-available/ldap_google`:
   `identity`, `password` (Google Admin → Apps → LDAP → client → access
   credentials). Keep `base_dn = dc=cedrosnorte,dc=edu,dc=mx`.
2. **Google client cert** — put `ldap-client.crt` + `ldap-client.key` in
   `raddb/certs/google/`.
3. **Env** — copy `.env.example` to `.env`, set `HOST_BIND_IP` and
   `RADIUS_HOSTNAME`.
4. **AP secret** — set the same secret in `raddb/clients.conf` (`local_lan`) and
   on your access points.
5. **Run**:
   ```bash
   docker compose up -d --build
   docker logs freeradius --tail 30      # expect "Configuration OK"
   ```

## Certificate (so devices don't need a manual CA install)

The EAP server cert lives in `raddb/certs/eap/`. On first start a **self-signed**
cert is generated automatically (devices will prompt or need the CA).

For a **no-prompt** experience, use a **public Let's Encrypt cert** issued via
**Cloudflare DNS-01** (no need to expose the server to the internet):

```bash
CF_Token='cloudflare-token-with-DNS-edit' \
  ./scripts/issue-eap-cert.sh radius.cedrosnorte.edu.mx
docker compose restart freeradius
```

Why public: the root CA is already in every device's trust store. Note that
**Cloudflare Origin CA certs do NOT work** (devices don't trust them) — only a
publicly-trusted cert (Let's Encrypt) does. Cloudflare is used here just as the
DNS provider for the ACME challenge.

### Device settings (EAP-TTLS + PAP)

| Platform | Config |
|----------|--------|
| Android 11+ | EAP=TTLS, Phase2=PAP, **CA=Use system certificates**, **Domain=`radius.cedrosnorte.edu.mx`**, identity=username |
| Windows | EAP=TTLS, Phase2=PAP — validates the public CA automatically |
| iOS/macOS | One-time "Trust" prompt (or push a configuration profile for zero-tap) |

## Long time between reauthentications

- `default` post-auth sets `Session-Timeout = 86400` (24h) and
  `Termination-Action = RADIUS-Request` (reauth happens in place, no drop).
  Raise the number for longer.
- EAP **TLS session cache** (`mods-available/eap`, 24h) lets devices reconnect
  without a full handshake or another LDAP hit.

## Testing

```bash
# LDAP side (finds user, checks password) — best for diagnosing one user:
LDAP_TEST_PASSWORD='pass' ./scripts/ldap-test.sh erbutcher

# Full FreeRADIUS LDAP path through the inner tunnel:
LDAP_TEST_PASSWORD='pass' ./scripts/radius-test-auth.sh erbutcher
```

If `ldap-test.sh` fails at step 2 (search), the LDAP client lacks **Read user
information** on that user's OU. If it fails at step 3 (bind), it's the password
/ account (Gmail first-login, 2-Step Verification).

## IoT devices

Most IoT gear can't do WPA2 Enterprise. Put them on a **separate WPA2-Personal
SSID on an isolated VLAN**, or use **MAC auth (MAB)** on that VLAN — don't weaken
this Enterprise SSID.
