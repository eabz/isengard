# FreeRADIUS — WPA2/WPA3 Enterprise with Google Workspace Secure LDAP

WiFi authentication for **cedrosnorte.edu.mx** and **colegios-cedros-paseo.mx**
using **EAP-TTLS + PAP** against Google Secure LDAP. Users log in with their
**username only** (e.g. `jpsanchez`) — no domain.

## How it works

```
phone ──EAP-TTLS──> AP ──RADIUS──> FreeRADIUS (default site, outer)
                                        │  EAP/TLS tunnel
                                        ▼
                                   inner-tunnel  ──search + bind──> Google LDAP
                                        ▲                              (via stunnel
                                        └── PAP username/password ─────  127.0.0.1:1636)
```

Both domains live in **one** Google directory tree, but Google indexes them
differently:

- **cedrosnorte.edu.mx** (primary): found by `(uid=…)`, authenticated with a **DN bind**.
- **colegios-cedros-paseo.mx** (secondary): **not** indexed by `uid`; found by
  `(mail=…@colegios-cedros-paseo.mx)` and authenticated with an **email bind**
  (Google rejects the DN bind for secondary-domain users → error 49).

The inner-tunnel tries uid first, then the colegios mail lookup, and sets the
right bind identity. Authentication is "bind as user" (Google never returns the
password hash) — which is why the inner method must be **PAP**.

## Files

| File | Purpose |
|------|---------|
| `raddb/mods-available/ldap_google` | Two LDAP instances: `ldap_google` (uid) + `ldap_colegios` (mail). Credentials come from `.env`. |
| `raddb/sites-available/default` | Outer server (APs talk here). EAP only. Sets long `Session-Timeout`. |
| `raddb/sites-available/inner-tunnel` | Inner tunnel: normalize uid, uid→mail lookup, LDAP bind. |
| `raddb/mods-available/eap` | EAP-TTLS + PAP, TLS session cache, points at `certs/eap/`. |
| `raddb/clients.conf` | APs + loopback test clients. AP secret comes from `.env`. |
| `stunnel/google-ldap.conf` | TLS proxy to `ldap.google.com:636`. |
| `docker-entrypoint.sh` | Enables the LDAP module, makes the EAP cert, starts stunnel, validates, runs. |

All secrets live in `.env` (gitignored) and are read by the config via
`$ENV{…}`, so `git pull` never conflicts on credentials.

## Setup

1. **Env / secrets** — copy `.env.example` to `.env` and set:
   - `HOST_BIND_IP`, `RADIUS_HOSTNAME`
   - `RADIUS_CLIENT_SECRET` — the shared secret your APs use
   - `GOOGLE_LDAP_IDENTITY` / `GOOGLE_LDAP_PASSWORD` — Google Admin → Apps →
     LDAP → client → access credentials
2. **Google client cert** — put `ldap-client.crt` + `ldap-client.key` in
   `raddb/certs/google/`.
3. **base_dn** — stays in `raddb/mods-available/ldap_google`
   (`dc=cedrosnorte,dc=edu,dc=mx`); no need to change it.
4. **Run**:
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
