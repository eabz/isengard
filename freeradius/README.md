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
| `raddb/mods-available/linelog_inner` | Logs the real fully-qualified identity against the MAC on every inner Access-Accept (see "Attributing NextDNS query logs to real users" below). |
| `raddb/clients.conf` | APs + loopback/bridge test clients. AP secret comes from `.env`; test secret too. |
| `stunnel/google-ldap.conf` | TLS proxy to `ldap.google.com:636`. |
| `docker-entrypoint.sh` | Enables the LDAP + linelog modules, makes the EAP cert, starts stunnel, validates, runs. |
| `scripts/lookup_user.py` | Domain/IP + time -> real user, via NextDNS + radacct + the inner-identity linelog. |
| `scripts/rotate-logs.sh` | Deletes radacct/linelog files older than `LOG_RETENTION_DAYS`. |

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

## Attributing NextDNS query logs to real users

**The problem:** ~35% of clients send a non-routable outer EAP identity
("anonymous"/"anonimo"), so the RADIUS *accounting* record's `User-Name` is
useless — but the real identity does exist, briefly, inside the EAP-TTLS
tunnel. `mods-available/eap`'s `copy_request_to_tunnel = yes` (already the
case here) copies outer attributes like `Calling-Station-Id` into the inner
request, and `inner-tunnel`'s `post-auth` logs the real, fully-qualified
identity against that MAC via a dedicated `linelog` instance
(`mods-available/linelog_inner`), to
`/var/log/freeradius/inner-identity/inner-identity-YYYYMMDD.log`
(`<timestamp>\t<calling-station-id>\t<uid>@<domain>`, one line per
Access-Accept). That file lives under the same `freeradius-logs` Docker
volume as `radacct/`, so it persists across container restarts with no extra
mount.

**The chain `scripts/lookup_user.py` walks:**

```
NextDNS log (device IP + timestamp)
    -> radacct detail files   (Framed-IP-Address, time-bounded)  -> Calling-Station-Id
    -> inner-identity linelog (Calling-Station-Id, time-bounded) -> fully-qualified identity
```

Usage (run inside the container, where the log volume and the clock live):

```bash
# I know the device IP and roughly when.
docker exec freeradius lookup_user.py --ip 10.0.12.34 --at 2026-08-06T14:32:00

# I only know a domain and a time window — resolves via the NextDNS Logs API
# first (needs NEXTDNS_API_KEY in .env), then chases each hit through RADIUS.
docker exec freeradius lookup_user.py --domain doubleclick.net \
    --since 2026-08-06T14:00:00 --until 2026-08-06T15:00:00
```

**Correctness rules this script enforces (don't "simplify" them away if you
touch it):**

- **A session with no `Acct-Stop` is closed after 2 missed interims**
  (`Acct-Interim-Interval` is 600s below → 1200s / 20 min of silence). A
  session's covered time window never extends past its last observed record
  + that grace period. Without this, a DHCP-reassigned IP gets attributed to
  whoever had it *before*, not whoever has it now.
- **Usernames are never stripped of `@domain`.** `cedrosnorte.edu.mx` and
  `colegios-cedros-paseo.mx` are two different Workspace domains, and the
  same bare uid can be two different people across them. The linelog always
  records the identity fully-qualified (resolved from `&control:Tmp-String-0`
  in `inner-tunnel`, even for bare-username logins) — the script returns it
  verbatim, never normalized.
- Detail files are read from `radacct/<nas-ip>/detail-YYYYMMDD` across
  **however many NAS directories exist** (the script globs them; it doesn't
  assume a fixed count or fixed IPs).

### "Some devices still show as anonymous"

**In the UniFi/UDM client list, that is expected and is not a bug.** The UDM
displays the **outer** RADIUS `User-Name` — the identity the supplicant sends
*before* the TLS tunnel opens. Nothing in this repo changes that value, by
design: the whole premise here is that the outer identity is unreliable
(`anonymous`, `anonimo`, `anonymous@cedrosnorte.edu.mx` are all normal
supplicant behaviour) and that the real identity is recovered from a
side-channel — the inner-identity linelog — at *lookup* time. A client that
shows `anonymous` in the UDM UI can still be perfectly attributable.

So the question to ask is never "what does the UDM show", it is "does this
MAC resolve?". That's what `--audit` answers:

```bash
docker exec freeradius lookup_user.py --audit \
    --since 2026-08-19T06:00:00 --until 2026-08-19T09:00:00
```

It lists every device seen in accounting in that window with its resolved
identity, its outer `User-Name` side by side, and — for anything `UNRESOLVED`
— why. Only the `UNRESOLVED` rows are actual gaps.

The usual reason for a genuine `UNRESOLVED`:

- **EAP TLS session resumption skips the inner tunnel entirely.** With
  `cache { enable = yes; lifetime = 48 }` in `mods-available/eap`, a resuming
  device never re-runs `inner-tunnel`, so it writes no linelog line. Devices
  holding a cached session from before the linelog was deployed stay
  unresolvable until that session expires (≤48h) — a container rebuild
  flushes the in-memory cache and forces full auths, which fixes it faster.
- **MAC randomization changing.** iOS/Android private addresses are stable
  per-SSID, so the join holds; but a user toggling "Private Wi-Fi Address"
  off/on gets a new MAC and starts fresh.

**NextDNS API caveat:** the exact JSON field name for the client IP in the
NextDNS Logs API response hasn't been verified live in this environment.
Run once with `--dump-raw` and adjust `_IP_KEYS` in `scripts/lookup_user.py`
if it comes back empty. `--ip`/`--at` mode doesn't depend on this at all.

## Log retention

`radacct/` detail files and the inner-identity linelog are both already
date-stamped per file, so "rotation" is just deleting old files —
`scripts/rotate-logs.sh` (baked into the image at
`/usr/local/bin/rotate-logs.sh`) does that, keeping `LOG_RETENTION_DAYS`
(default 90, see `.env`) days. Schedule it from the **host's** crontab:

```
30 3 * * * docker exec freeradius rotate-logs.sh >> /var/log/freeradius-rotate.log 2>&1
```

## AP addressing: use static DHCP reservations

Each AP is its own RADIUS NAS, so accounting lands in its own
`radacct/<nas-ip>/` directory keyed by the AP's IP. If APs get **dynamic**
DHCP leases, an AP that renews to a new IP starts a fresh, empty NAS
directory and fragments that AP's accounting history across multiple
directories — `lookup_user.py` still finds everything (it globs all NAS
dirs), but it's needless fragmentation and makes manual debugging harder.
Give every AP a **static DHCP reservation**.
