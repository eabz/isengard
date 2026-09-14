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
| `.dockerignore` | Allows only runtime configuration and scripts into the image build; excludes secrets and certificates. |
| `docker-entrypoint.sh` | Prepares modules, certificate permissions and the TLS cache, then starts Supervisor. |
| `supervisor/radius.conf` | Starts and independently restarts stunnel and FreeRADIUS. |
| `scripts/radius-service.py` | Waits for stunnel before starting FreeRADIUS; checks local process/socket readiness. |
| `scripts/renew-eap-cert.py` | Host-side ACME issuance/renewal, certificate validation, activation and rollback. |
| `scripts/install-cert-renewal.sh`, `systemd/` | Installs a daily certificate check on the Linux Docker host. |
| `scripts/lookup_user.py` | Domain/IP + time -> real user, via NextDNS + radacct + the inner-identity linelog. |
| `scripts/rotate-logs.sh` | Deletes radacct/linelog files older than `LOG_RETENTION_DAYS`. |

LDAP credentials and RADIUS shared secrets live in `.env` (gitignored) and
are read by the config via `$ENV{…}`. Private keys stay in `raddb/certs/`;
ACME account state and saved DNS credentials stay in `acme/`. Neither directory
enters the build context. Certificates are mounted into the running container.
Rebuild to apply `.dockerignore`; it cannot remove secrets from older images.

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

Use a **public Let's Encrypt cert** issued via **Cloudflare DNS-01** to avoid
distributing a private CA (no need to expose the server to the internet).
Run from this directory on the Linux Docker host, after deploying the updated
container. The host needs Python 3.8+, Docker Compose, OpenSSL 1.1.1 or 3 and
an up-to-date system CA trust store. Export a Cloudflare token limited to DNS
editing for the required zone as `CF_Token`, then run:

```bash
sudo --preserve-env=CF_Token ./scripts/issue-eap-cert.sh radius.cedrosnorte.edu.mx
```

Use the hostname configured in `.env` as `RADIUS_HOSTNAME`. Issuance validates
and activates the certificate automatically; no separate container restart
is needed. For initial provisioning before the container exists, append
`--install-only`, then start the container. acme.sh saves the DNS credentials
under `acme/` for subsequent renewal. Keep that directory private and backed up.

Devices must still validate the server hostname and a trusted CA; a public
certificate does not configure WiFi profiles automatically. **Cloudflare
Origin CA certificates are unsuitable** for clients using their system trust
store. Cloudflare is only the DNS provider for this ACME challenge.

### Automatic renewal on the Linux host

Once issuance has succeeded and `acme/` contains the existing account and
certificate state, install the timer from this directory:

```bash
sudo ./scripts/install-cert-renewal.sh radius.cedrosnorte.edu.mx
sudo systemctl start isengard-eap-renew.service
systemctl list-timers isengard-eap-renew.timer
sudo journalctl -u isengard-eap-renew.service -n 50 --no-pager
```

It checks daily between 03:20 and 03:40 in the host timezone, and catches up
after downtime. acme.sh renews only when due. The timer uses the saved DNS
credentials in `acme/`; the systemd unit contains no Cloudflare token. If the
repository moves, rerun the installer to update its path. Manual renewal uses
the same workflow: `sudo python3 scripts/renew-eap-cert.py <radius-hostname>`.

The ACME container writes into a temporary staging directory. Before activation,
the host verifies the hostname, expiration, public trust chain, server purpose
and matching private key. If files changed, the script backs up the previous
bundle, preserves ownership and permissions, replaces the live files, runs
`freeradius -C`, and restarts **only FreeRADIUS** through Supervisor. This briefly
interrupts RADIUS requests; stunnel keeps running and the TLS cache persists.
Failed validation leaves the live bundle untouched; failed activation restores
the previous files and attempts to restart with them. A private backup remains
in `acme/previous-eap/`. An unchanged certificate causes no restart.

Failures are visible in the service exit status and journal. Connect that
service status to your server monitoring if you need push/email alerts;
installing the timer alone does not deliver notifications.

### Google LDAP client certificate

`raddb/certs/google/ldap-client.crt` is a separate certificate issued by Google,
not by Let's Encrypt. Each daily job checks whether it expires within 30 days.
If so, it logs `ACTION REQUIRED` and fails the service after finishing the EAP
renewal work, making the warning visible to monitoring.

Generate a replacement certificate and key in Google Admin → Apps → LDAP →
your client → Authentication, following [Google's certificate management
instructions](https://knowledge.workspace.google.com/admin/apps/manage-ldap-clients?hl=en).
Replace both local files, then reload them by restarting only stunnel:

```bash
docker exec freeradius supervisorctl -c /etc/supervisor/radius.conf restart stunnel
```

Check a real LDAP search/bind afterward with `scripts/ldap-test.sh`. Google
client certificate replacement remains an administrator action in this setup.

### Device settings (EAP-TTLS + PAP)

| Platform | Config |
|----------|--------|
| Android 11+ | EAP=TTLS, Phase2=PAP, **CA=Use system certificates**, **Domain=`radius.cedrosnorte.edu.mx`**, identity=username |
| Windows | EAP=TTLS, Phase2=PAP — validates the public CA automatically |
| iOS/macOS | One-time "Trust" prompt (or push a configuration profile for zero-tap) |

## Long time between reauthentications

- `default` post-auth sets `Session-Timeout = 172800` (48h) and
  `Termination-Action = RADIUS-Request`, asking the AP to reauthenticate.
  Whether this is seamless also depends on the AP and supplicant.
- EAP **TLS session cache** (`mods-available/eap`, 48h) lets compatible devices
  resume an authenticated session without another full handshake or LDAP bind.
  FreeRADIUS 3.2.10 disables OpenSSL's internal cache, so `enable = yes` and
  `max_entries` alone do not provide session storage. We use `persist_dir` at
  `/var/lib/freeradius/tlscache` and a stable cache `name` instead.
- The dedicated `freeradius-tls-cache` volume survives container recreation.
  The entrypoint creates its directory with mode `0700`, assigns it to the
  FreeRADIUS user, and sets a restrictive umask. Treat this volume as secret:
  it contains TLS session keys, not just diagnostic logs.
- Cache files older than 48 hours are removed at startup and by the daily
  `rotate-logs.sh` job below, independently of accounting-log retention.
  Keep both cleanup thresholds aligned with `cache.lifetime` when changing it.

Apply changes to the cache setup with `docker compose up -d --build freeradius`;
`restart` alone does not install the updated entrypoint or add the new volume.
This briefly interrupts RADIUS service. Existing devices need one successful
full authentication before they have a session to resume.

To verify resumption, use a supplicant configured for TTLS/PAP that supports
fast reauthentication. After a successful login, reconnect while retaining
the client's TLS session. In a controlled FreeRADIUS debug trace, expect
`EAP-Session-Resumed := 1` and no inner-tunnel LDAP bind on the resumed login.
Repeat after a container restart to check persistence. The startup message
`Using cached TLS configuration from previous invocation` only refers to
reusing the parsed configuration; it does **not** prove session resumption.
PAP requests from `radius-test-auth.sh` do not exercise the TLS cache.

Resumption skips the password/account check in Google. Suspending an account
there does not immediately invalidate its cached TLS session or an existing
WiFi connection. To invalidate all cached sessions, change the cache `name`
(for example, increment `v1` to `v2`) and restart FreeRADIUS; active WiFi
connections must also be disconnected on the AP if immediate revocation is
required.

## Testing

### Process health and recovery

```bash
docker compose ps
docker exec freeradius supervisorctl -c /etc/supervisor/radius.conf status
docker exec freeradius python3 /usr/local/bin/radius-service.py health
docker compose logs --tail 100 freeradius
```

Supervisor automatically restarts either process if it exits, including failed
startup attempts. If stunnel exits, FreeRADIUS stays running while stunnel is
restarted. A manual recovery uses `supervisorctl ... restart stunnel` as above.
Recreate the container with `docker compose up -d --build freeradius` to install
this supervision; restarting the old image does not add it.

The Docker healthcheck runs every 30 seconds and checks both process states,
stunnel's listener at `127.0.0.1:1636`, and RADIUS UDP ports 1812/1813. It reads
local socket tables, so it does not create extra TLS connections to Google.
It does not prove Google is reachable or detect every hung process. Docker's
`unhealthy` status is diagnostic; **Supervisor**, not the healthcheck, performs
process recovery. Docker's restart policy handles a container exit.

`TIMEOUTconnect` messages from stunnel indicate an unsuccessful connection to
Google while stunnel was running; they do not establish that the local process
died. If they persist with healthy local processes, investigate outbound TCP
636, DNS and upstream availability. TLS EOF/close messages alone do not establish
that a user authentication failed; correlate them with a real LDAP/RADIUS test.

### Offline regression tests

```bash
python3 -B -m unittest discover -s tests -v
```

These use OpenSSL for certificate checks and simulate Docker/ACME operations
to test activation and rollback. Install `supervisor` in the test interpreter
to also run the integration test that kills a fixture process and verifies
independent restart and graceful shutdown. It uses no Google credentials.

### LDAP authentication

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
  unresolvable until they perform a full authentication. A container rebuild
  now preserves the disk cache; change its `name` and restart to invalidate
  existing sessions when a full authentication is needed.
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

The same job removes `.asn1` and `.vps` TLS cache files older than 48 hours.
`LOG_RETENTION_DAYS` applies only to the accounting and identity logs.

## AP addressing: use static DHCP reservations

Each AP is its own RADIUS NAS, so accounting lands in its own
`radacct/<nas-ip>/` directory keyed by the AP's IP. If APs get **dynamic**
DHCP leases, an AP that renews to a new IP starts a fresh, empty NAS
directory and fragments that AP's accounting history across multiple
directories — `lookup_user.py` still finds everything (it globs all NAS
dirs), but it's needless fragmentation and makes manual debugging harder.
Give every AP a **static DHCP reservation**.
