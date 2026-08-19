#!/usr/bin/env python3
"""Attribute a NextDNS query (domain + time, or IP + time) to a real user.

Chain (see README.md "Attributing NextDNS logs to users"):

    NextDNS log (device IP + timestamp)
        -> radacct detail files   (Framed-IP-Address, time-bounded)  -> Calling-Station-Id
        -> inner-identity linelog (Calling-Station-Id, time-bounded) -> fully-qualified identity

Why this exists at all: ~35% of clients send a non-routable outer EAP
identity ("anonymous"/"anonimo"), so the RADIUS *accounting* record's
User-Name is useless. The real identity only ever appears in the
inner-tunnel's post-auth linelog (mods-available/linelog_inner), keyed by
Calling-Station-Id (the AP-reported MAC) instead.

Critical correctness rules (do not "simplify" these away):

  * A session with no Acct-Stop is treated as CLOSED after 2 missed interims
    (Acct-Interim-Interval is 600s -> 1200s of silence). We never extend a
    session past its last observed record + that grace window. Otherwise a
    DHCP-reassigned IP gets attributed to whoever HAD the IP before, not
    whoever has it now.
  * Usernames are NEVER stripped of their @domain. cedrosnorte.edu.mx and
    colegios-cedros-paseo.mx are two different Workspace domains and the same
    bare uid can be two different people across them (see the FreeRADIUS
    README). The linelog always records the fully-qualified identity
    (uid@domain) exactly as resolved by the inner-tunnel; that's what this
    script returns, verbatim.

Usage:
    # Direct: I already know the IP and roughly when.
    lookup_user.py --ip 10.0.12.34 --at 2026-08-06T14:32:00

    # Indirect: I only know a domain and a time range; ask NextDNS for the
    # device IP(s) that queried it, then resolve each to a user.
    lookup_user.py --domain doubleclick.net --since 2026-08-06T14:00:00 \\
        --until 2026-08-06T15:00:00

Run this INSIDE the freeradius container (where the log volume is mounted and
the clock matches the logs):
    docker exec freeradius lookup_user.py --ip 10.0.12.34 --at 2026-08-06T14:32:00
"""
import argparse
import glob
import json
import os
import sys
from datetime import datetime, timedelta
from urllib import error, parse, request

# Must match sites-available/default's &Acct-Interim-Interval.
INTERIM_INTERVAL = 600
# "2 missed interims" -> a session goes silent for this long and we consider
# it closed, even with no Acct-Stop.
MISSED_INTERIMS_GRACE = 2 * INTERIM_INTERVAL

# How many days of detail/linelog files to load around the query date. Needs
# to cover the longest a session or a cached-TLS reauth gap can plausibly be:
# Session-Timeout is 172800s (2 days), EAP TLS cache lifetime is 48h — 3 days
# of lookback covers both with room to spare. Widen with --lookback-days if a
# lookup comes back empty and you suspect a longer gap.
DEFAULT_LOOKBACK_DAYS = 3

RADACCT_ROOT = os.environ.get("RADACCT_ROOT", "/var/log/freeradius/radacct")
LINELOG_ROOT = os.environ.get("LINELOG_ROOT", "/var/log/freeradius/inner-identity")


# --------------------------------------------------------------------------
# Time helpers
#
# Everything below assumes the script runs with the SAME local timezone as
# the FreeRADIUS container that wrote the logs (detail file headers and the
# linelog's %T are both local time, not UTC). Naive timestamps you pass in
# are interpreted the same way.
# --------------------------------------------------------------------------

def parse_user_time(s):
    """Accept a unix epoch (int) or an ISO-8601 string (naive = local time)."""
    s = s.strip()
    if s.isdigit():
        return int(s)
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s).timestamp()


def iso(ts):
    if ts is None:
        return None
    return datetime.fromtimestamp(ts).isoformat(sep=" ", timespec="seconds")


def norm_mac(s):
    """Compare MACs by their hex digits alone.

    The Calling-Station-Id the linelog sees comes from the Access-Request; the
    one radacct sees comes from the Accounting-Request. Same AP, but vendors
    are not always consistent about separator or case BETWEEN packet types --
    "AA-BB-CC-DD-EE-FF", "aa:bb:cc:dd:ee:ff" and "aabbccddeeff" all denote the
    same device. A plain lowercase comparison silently misses those, and a
    silent miss here looks exactly like "this device is anonymous", which is
    the bug this whole script exists to eliminate. Strip to hex digits instead.
    """
    if not s:
        return ""
    return "".join(c for c in s.lower() if c in "0123456789abcdef")


def date_range(ts, lookback_days):
    """Date strings (YYYYMMDD) from ts-lookback_days through ts+1 day.

    The +1 day covers a session/log line written just after local midnight
    for an event that happened just before it (detail files roll at
    midnight; a session can straddle two dated files).
    """
    base = datetime.fromtimestamp(ts).date()
    days = [base - timedelta(days=i) for i in range(lookback_days, 0, -1)]
    days.append(base)
    days.append(base + timedelta(days=1))
    return [d.strftime("%Y%m%d") for d in days]


# --------------------------------------------------------------------------
# radacct detail file parsing
# --------------------------------------------------------------------------

def _parse_detail_file(path):
    """Yield one dict per accounting record block in a detail-YYYYMMDD file."""
    try:
        f = open(path, "r", errors="replace")
    except OSError:
        return
    with f:
        block = []
        for line in f:
            if line.strip() == "":
                if block:
                    yield _block_to_dict(block)
                    block = []
                continue
            block.append(line)
        if block:
            yield _block_to_dict(block)


def _block_to_dict(lines):
    rec = {"_header": lines[0].strip()}
    for line in lines[1:]:
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip().lstrip("&")
        v = v.strip()
        if v.startswith('"') and v.endswith('"') and len(v) >= 2:
            v = v[1:-1]
        rec[k] = v
    return rec


def _record_epoch(rec):
    """FreeRADIUS appends a 'Timestamp = <epoch>' line to every detail
    record; prefer that. Fall back to the ctime header line (e.g.
    'Wed Jun 26 20:53:47 2019') if it's ever missing."""
    if "Timestamp" in rec:
        try:
            return int(rec["Timestamp"])
        except ValueError:
            pass
    hdr = rec.get("_header")
    if hdr:
        try:
            return datetime.strptime(hdr, "%a %b %d %H:%M:%S %Y").timestamp()
        except ValueError:
            pass
    return None


def iter_nas_dirs(radacct_root):
    for d in sorted(glob.glob(os.path.join(radacct_root, "*"))):
        if os.path.isdir(d):
            yield d


def load_records(nas_dir, dates):
    records = []
    for d in dates:
        path = os.path.join(nas_dir, f"detail-{d}")
        for rec in _parse_detail_file(path):
            ts = _record_epoch(rec)
            if ts is None:
                continue
            rec["_ts"] = ts
            records.append(rec)
    return records


def interim_gap_stats(records):
    """Observed spacing between consecutive accounting records of one session.

    This exists to catch a silent, badly-misleading failure: if the real
    interim interval is LARGER than what --interim-interval says, every long
    session gets chopped into fragments at the grace boundary and the device
    looks like it is reconnecting constantly. That is indistinguishable from
    genuine WiFi instability unless you compare the two numbers.
    """
    by_id = {}
    for rec in records:
        sid = rec.get("Acct-Session-Id")
        if sid:
            by_id.setdefault(sid, []).append(rec["_ts"])
    gaps = []
    for tss in by_id.values():
        tss.sort()
        gaps.extend(int(b - a) for a, b in zip(tss, tss[1:]))
    return sorted(gaps)


def build_sessions(records, grace=None):
    """Group accounting records by Acct-Session-Id and reconstruct the
    covered [start, end] interval for each, applying the "closed after 2
    missed interims" rule. Returns a list of session dicts."""
    if grace is None:
        grace = MISSED_INTERIMS_GRACE
    by_id = {}
    for rec in records:
        sid = rec.get("Acct-Session-Id")
        if not sid:
            continue
        by_id.setdefault(sid, []).append(rec)

    sessions = []
    for sid, recs in by_id.items():
        recs.sort(key=lambda r: r["_ts"])
        cur = None
        for rec in recs:
            ts = rec["_ts"]
            status = rec.get("Acct-Status-Type", "")
            if cur is None:
                cur = _new_session(sid, rec, ts)
            else:
                gap = ts - cur["last_seen"]
                if gap > grace and cur["end"] is None:
                    # Silence exceeded 2 missed interims: force-close here,
                    # do NOT extend coverage up to this later record.
                    cur["end"] = cur["last_seen"] + grace
                    cur["closed_reason"] = "timeout"
                    sessions.append(cur)
                    # Same Acct-Session-Id reappearing after a >20min silent
                    # gap is anomalous (session ids are meant to be unique
                    # per session) — treat it as a new, separate interval
                    # under the same id rather than silently merging.
                    cur = _new_session(sid, rec, ts)
                    cur["note"] = "reopened after a timeout gap under the same Acct-Session-Id"
                cur["framed_ip"] = rec.get("Framed-IP-Address", cur["framed_ip"])
                cur["calling_station_id"] = rec.get("Calling-Station-Id", cur["calling_station_id"])
                cur["last_seen"] = ts
            if status == "Stop":
                cur["end"] = ts
                cur["closed_reason"] = "stop"
                sessions.append(cur)
                cur = None
        if cur is not None:
            # No Acct-Stop in the loaded window: close it 2 missed interims
            # after the last thing we actually heard from it.
            cur["end"] = cur["last_seen"] + grace
            cur["closed_reason"] = "no-stop-seen (closed after missed-interim grace)"
            sessions.append(cur)
    return sessions


def _new_session(sid, rec, ts):
    return {
        "session_id": sid,
        "start": ts,
        "last_seen": ts,
        "end": None,
        "framed_ip": rec.get("Framed-IP-Address"),
        "calling_station_id": rec.get("Calling-Station-Id"),
        "closed_reason": None,
    }


def find_sessions_for_ip(ip, ts, radacct_root, lookback_days, grace=None):
    dates = date_range(ts, lookback_days)
    matches = []
    for nas_dir in iter_nas_dirs(radacct_root):
        records = load_records(nas_dir, dates)
        if not records:
            continue
        for s in build_sessions(records, grace):
            if s["framed_ip"] == ip and s["start"] <= ts <= s["end"]:
                s["nas"] = os.path.basename(nas_dir)
                matches.append(s)
    return matches


# --------------------------------------------------------------------------
# inner-identity linelog parsing
# --------------------------------------------------------------------------

# FreeRADIUS's %T expansion has varied across versions (ISO "T" separator,
# dash-joined, space-joined, with or without microseconds). Pinning a single
# format here caused a silent total failure once already: every line failed to
# parse, find_identity skipped all of them, and the audit reported "no line for
# this MAC" for EVERY device while the file plainly held thousands of lines.
# Accept every plausible spelling instead, and count what still won't parse.
_LINELOG_TS_FORMATS = (
    "%Y-%m-%dT%H:%M:%S.%f",
    "%Y-%m-%d-%H:%M:%S.%f",
    "%Y-%m-%d %H:%M:%S.%f",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d-%H:%M:%S",
    "%Y-%m-%d %H:%M:%S",
)


def parse_linelog_timestamp(ts_str):
    ts_str = ts_str.strip()
    for fmt in _LINELOG_TS_FORMATS:
        try:
            return datetime.strptime(ts_str, fmt).timestamp()
        except ValueError:
            continue
    raise ValueError(f"unrecognised linelog timestamp: {ts_str!r}")


def find_identity(calling_station_id, ref_ts, linelog_root, lookback_days):
    """Latest linelog entry for this MAC at or before ref_ts (small forward
    slack for clock skew between the Access-Accept and the Acct-Start).
    Deliberately does NOT restrict to a tight window before ref_ts: the EAP
    TLS session cache (48h) means a device can go a long time between full
    inner-tunnel authentications, so the matching linelog line can be well
    before the session it's being matched against."""
    dates = date_range(ref_ts, lookback_days)
    want_mac = norm_mac(calling_station_id)
    slack = 60
    best = None
    if not want_mac:
        return None
    for d in dates:
        path = os.path.join(linelog_root, f"inner-identity-{d}.log")
        try:
            f = open(path, "r", errors="replace")
        except OSError:
            continue
        with f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) != 3:
                    continue
                ts_str, csid, identity = parts
                if norm_mac(csid) != want_mac:
                    continue
                try:
                    ts_val = parse_linelog_timestamp(ts_str)
                except ValueError:
                    continue
                if ts_val <= ref_ts + slack and (best is None or ts_val > best[0]):
                    best = (ts_val, identity)
    return best


# --------------------------------------------------------------------------
# NextDNS Logs API (domain + range -> device IP + timestamp events)
#
# NOTE ON RELIABILITY: this hits the NextDNS Logs API and picks the client-IP
# field out of the response. The exact JSON field name has not been verified
# against a live response in this environment — run once with --dump-raw and
# adjust _extract_ip()'s candidate key list below if it comes back empty.
# --------------------------------------------------------------------------

_IP_KEYS = [
    ("device", "ip"),
    ("client_ip",),
    ("clientIp",),
    ("device_ip",),
    ("deviceIp",),
    ("remote_ip",),
]


def _dig(d, path):
    cur = d
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def _extract_ip(item):
    for path in _IP_KEYS:
        v = _dig(item, path)
        if v:
            return v
    return None


def nextdns_query_events(domain, since_ts, until_ts, dump_raw=False):
    api_key = os.environ.get("NEXTDNS_API_KEY")
    profile = os.environ.get("NEXTDNS_PROFILE_ID", "d3a5e7")
    if not api_key:
        sys.exit("ERROR: set NEXTDNS_API_KEY (see .env.example) to use --domain lookups.")

    params = {
        "domain": domain,
        "from": datetime.utcfromtimestamp(since_ts).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "to": datetime.utcfromtimestamp(until_ts).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "limit": 1000,
    }
    url = f"https://api.nextdns.io/profiles/{profile}/logs?" + parse.urlencode(params)
    req = request.Request(url, headers={"X-Api-Key": api_key})
    try:
        with request.urlopen(req, timeout=20) as resp:
            body = resp.read()
    except error.HTTPError as e:
        sys.exit(f"ERROR: NextDNS API request failed: {e.code} {e.reason}\n{e.read().decode(errors='replace')}")
    except error.URLError as e:
        sys.exit(f"ERROR: could not reach the NextDNS API: {e.reason}")

    data = json.loads(body)
    if dump_raw:
        print(json.dumps(data, indent=2)[:4000], file=sys.stderr)

    rows = data.get("data", data if isinstance(data, list) else [])
    events = []
    for item in rows:
        ip = _extract_ip(item)
        ts_raw = item.get("timestamp")
        if not ip or not ts_raw:
            continue
        try:
            ts_str = ts_raw[:-1] + "+00:00" if ts_raw.endswith("Z") else ts_raw
            ts_val = datetime.fromisoformat(ts_str).timestamp()
        except ValueError:
            continue
        events.append({"ip": ip, "ts": ts_val})

    if not events:
        print(
            "NOTE: no matching NextDNS rows, or the response JSON shape didn't match "
            "what this script expects. Re-run with --dump-raw to inspect the real "
            "response and fix _IP_KEYS in scripts/lookup_user.py if needed.",
            file=sys.stderr,
        )
    return events


# --------------------------------------------------------------------------
# Resolution
# --------------------------------------------------------------------------

def resolve(ip, ts, radacct_root, linelog_root, lookback_days, grace=None):
    sessions = find_sessions_for_ip(ip, ts, radacct_root, lookback_days, grace)
    result = {"ip": ip, "timestamp": iso(ts)}

    if not sessions:
        result.update(user=None, reason="no accounting session covers this IP at this time")
        return result

    if len(sessions) > 1:
        result["warning"] = (
            f"{len(sessions)} overlapping sessions matched this IP/time — "
            "reporting the first; treat this lookup as unreliable"
        )

    s = sessions[0]
    result.update(
        calling_station_id=s["calling_station_id"],
        session_id=s["session_id"],
        session_start=iso(s["start"]),
        session_end=iso(s["end"]),
        session_closed_reason=s["closed_reason"],
        nas=s["nas"],
    )

    if not s["calling_station_id"]:
        result.update(user=None, reason="session has no Calling-Station-Id recorded")
        return result

    found = find_identity(s["calling_station_id"], s["start"], linelog_root, lookback_days)
    if not found:
        result.update(
            user=None,
            reason=(
                "no inner-identity linelog entry for this MAC at/before session start "
                "(device may have used a cached TLS session older than --lookback-days, "
                "or never completed a full inner-tunnel authentication)"
            ),
        )
        return result

    _, identity = found
    result["user"] = identity
    return result


def date_span(since_ts, until_ts, lookback_days):
    """Every YYYYMMDD from since-lookback through until+1 day."""
    start = datetime.fromtimestamp(since_ts).date() - timedelta(days=lookback_days)
    end = datetime.fromtimestamp(until_ts).date() + timedelta(days=1)
    out, d = [], start
    while d <= end:
        out.append(d.strftime("%Y%m%d"))
        d += timedelta(days=1)
    return out


def data_health(radacct_root, linelog_root, dates):
    """Is the source data even there?

    Without this, "UNRESOLVED" is ambiguous in the worst way: a linelog that
    was never written at all looks EXACTLY like a linelog that simply has no
    line for this MAC. The first is a broken deployment you must fix; the
    second is normal and self-heals as devices do full authentications. Always
    check the totals below before believing any per-device "why".
    """
    nas = []
    for nas_dir in iter_nas_dirs(radacct_root):
        n = sum(1 for d in dates if os.path.exists(os.path.join(nas_dir, f"detail-{d}")))
        nas.append((os.path.basename(nas_dir), n))

    files, lines, macs = [], 0, set()
    bad_ts, sample = 0, None
    for d in dates:
        path = os.path.join(linelog_root, f"inner-identity-{d}.log")
        if not os.path.exists(path):
            continue
        files.append(os.path.basename(path))
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) == 3:
                        lines += 1
                        macs.add(norm_mac(parts[1]))
                        if sample is None:
                            sample = line.rstrip("\n")
                        try:
                            parse_linelog_timestamp(parts[0])
                        except ValueError:
                            bad_ts += 1
        except OSError:
            pass

    return {
        "radacct_root": radacct_root,
        "nas_dirs": nas,
        "linelog_root": linelog_root,
        "linelog_files": files,
        "linelog_lines": lines,
        "linelog_macs": len(macs),
        "linelog_bad_timestamps": bad_ts,
        "linelog_sample": sample,
    }


def audit(since_ts, until_ts, radacct_root, linelog_root, lookback_days, grace=None):
    """List every device seen in accounting during [since, until] and whether
    its MAC resolves to a real identity.

    This is the diagnostic for "some devices still show as anonymous". The
    outer accounting User-Name is EXPECTED to be anonymous for many clients --
    that is the whole premise -- so what actually matters is whether the MAC
    joins to a linelog identity. Anything listed UNRESOLVED here is a device
    whose traffic genuinely cannot be attributed yet, and the outer User-Name
    seen in accounting is reported alongside so you can tell the two apart.
    """
    if grace is None:
        grace = MISSED_INTERIMS_GRACE
    dates = date_span(since_ts, until_ts, lookback_days)
    devices = {}
    all_records = []

    for nas_dir in iter_nas_dirs(radacct_root):
        records = load_records(nas_dir, dates)
        if not records:
            continue
        # Outer User-Name per session, straight off the accounting records --
        # this is the value that reads "anonymous"/"anonimo".
        outer = {}
        for rec in records:
            sid = rec.get("Acct-Session-Id")
            if sid and rec.get("User-Name"):
                outer.setdefault(sid, rec["User-Name"])

        all_records.extend(records)
        for sess in build_sessions(records, grace):
            # Keep only sessions overlapping the requested window.
            if sess["end"] < since_ts or sess["start"] > until_ts:
                continue
            mac = sess["calling_station_id"]
            key = norm_mac(mac) or f"<no-csid:{sess['session_id']}>"
            d = devices.setdefault(key, {
                "calling_station_id": mac,
                "sessions": 0,
                "ips": set(),
                "outer_names": set(),
                "first": sess["start"],
                "last": sess["end"],
                "nas": set(),
            })
            d["sessions"] += 1
            if sess["framed_ip"]:
                d["ips"].add(sess["framed_ip"])
            if outer.get(sess["session_id"]):
                d["outer_names"].add(outer[sess["session_id"]])
            d["first"] = min(d["first"], sess["start"])
            d["last"] = max(d["last"], sess["end"])
            d["nas"].add(os.path.basename(nas_dir))

    rows = []
    for key, d in devices.items():
        identity = None
        reason = None
        if not d["calling_station_id"]:
            reason = "accounting record carries no Calling-Station-Id (nothing to join on)"
        else:
            found = find_identity(d["calling_station_id"], d["first"], linelog_root, lookback_days)
            if found:
                identity = found[1]
            else:
                reason = (
                    "no inner-identity line for this MAC within --lookback-days "
                    "(EAP TLS session resumption skips the inner tunnel, so a device "
                    "that last authenticated in full before the linelog existed -- or "
                    "longer ago than the lookback -- writes no line)"
                )
        rows.append({
            "calling_station_id": d["calling_station_id"],
            "user": identity,
            "reason": reason,
            "sessions": d["sessions"],
            "ips": sorted(d["ips"]),
            "outer_user_names": sorted(d["outer_names"]),
            "first_seen": iso(d["first"]),
            "last_seen": iso(d["last"]),
            "nas": sorted(d["nas"]),
        })
    rows.sort(key=lambda r: (r["user"] is not None, r["calling_station_id"] or ""))
    health = data_health(radacct_root, linelog_root, dates)
    gaps = interim_gap_stats(all_records)
    health["observed_gaps"] = len(gaps)
    health["median_gap"] = gaps[len(gaps) // 2] if gaps else None
    health["grace"] = grace
    return rows, health


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    mode = ap.add_argument_group("lookup mode (pick one)")
    mode.add_argument("--ip", help="Framed-IP-Address to look up")
    mode.add_argument("--at", help="timestamp for --ip (epoch or ISO-8601, local time)")
    mode.add_argument("--domain", help="domain to look up via the NextDNS Logs API")
    mode.add_argument("--since", help="range start for --domain (epoch or ISO-8601)")
    mode.add_argument("--until", help="range end for --domain (epoch or ISO-8601)")
    mode.add_argument(
        "--audit", action="store_true",
        help="list every device seen in accounting between --since and --until and "
             "whether its MAC resolves to a real identity (diagnostic for "
             "'devices still showing as anonymous')",
    )

    ap.add_argument("--radacct-root", default=RADACCT_ROOT)
    ap.add_argument("--linelog-root", default=LINELOG_ROOT)
    ap.add_argument("--lookback-days", type=int, default=DEFAULT_LOOKBACK_DAYS)
    ap.add_argument(
        "--interim-interval", type=int, default=INTERIM_INTERVAL,
        help="ACTUAL Acct-Interim-Interval your APs are sending, in seconds "
             "(default %(default)s). A session is closed after 2 of these are "
             "missed. Set this to the real value -- if it is too low, long "
             "sessions get chopped into fragments and devices look like they "
             "are reconnecting constantly when they are not.",
    )
    ap.add_argument("--dump-raw", action="store_true", help="dump the raw NextDNS API response to stderr")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a text table")
    args = ap.parse_args()
    grace = 2 * args.interim_interval

    if args.audit:
        if not (args.since and args.until):
            ap.error("--audit requires --since and --until")
        rows, health = audit(
            parse_user_time(args.since), parse_user_time(args.until),
            args.radacct_root, args.linelog_root, args.lookback_days, grace,
        )
        if args.json:
            print(json.dumps({"health": health, "devices": rows}, indent=2))
        else:
            print("=" * 60)
            print("SOURCE DATA (check this before trusting any 'why' below)")
            print("=" * 60)
            print(f"radacct root      {health['radacct_root']}")
            if health["nas_dirs"]:
                for name, n in health["nas_dirs"]:
                    print(f"  NAS {name:<18} {n} detail file(s) in range")
            else:
                print("  (NO NAS DIRECTORIES -- no accounting is reaching this server)")
            print(f"linelog root      {health['linelog_root']}")
            if health["linelog_files"]:
                print(f"  {len(health['linelog_files'])} file(s), "
                      f"{health['linelog_lines']} line(s), "
                      f"{health['linelog_macs']} distinct MAC(s)")
                if health.get("linelog_bad_timestamps"):
                    print(f"  !! {health['linelog_bad_timestamps']} line(s) have a timestamp")
                    print("  !! this script cannot parse -- those lines are DISCARDED and")
                    print("  !! every device they cover will read UNRESOLVED. Fix the")
                    print("  !! format before believing any reason below.")
                if health.get("linelog_sample"):
                    print(f"  sample: {health['linelog_sample']}")
            else:
                print("  (NO LINELOG FILES -- nothing has ever been written.)")
                print("  Every device below will read UNRESOLVED for that reason")
                print("  alone. Fix the linelog first; per-device reasons are")
                print("  meaningless until this line shows files.")
            if health.get("median_gap") is not None:
                mg, gr = health["median_gap"], health["grace"]
                print(f"observed interim  median gap {mg}s between records "
                      f"(grace {gr}s)")
                if mg > gr:
                    print("  !! MEDIAN GAP EXCEEDS THE GRACE WINDOW. Sessions below are")
                    print("  !! being split artificially -- 'sessions' counts are inflated")
                    print(f"  !! and mean nothing. Re-run with --interim-interval {mg}")
            print()
            unresolved = [r for r in rows if not r["user"]]
            print(f"{len(rows)} device(s) seen; {len(unresolved)} UNRESOLVED\n")
            for r in rows:
                print("-" * 60)
                print(f"{'mac':22} {r['calling_station_id']}")
                print(f"{'user':22} {r['user'] or 'UNRESOLVED'}")
                if r["reason"]:
                    print(f"{'why':22} {r['reason']}")
                print(f"{'outer User-Name':22} {', '.join(r['outer_user_names']) or '(none)'}")
                print(f"{'ips':22} {', '.join(r['ips']) or '(none)'}")
                print(f"{'sessions':22} {r['sessions']}")
                print(f"{'first/last seen':22} {r['first_seen']} .. {r['last_seen']}")
                print(f"{'nas':22} {', '.join(r['nas'])}")
        return

    if args.domain:
        if not (args.since and args.until):
            ap.error("--domain requires --since and --until")
        since_ts = parse_user_time(args.since)
        until_ts = parse_user_time(args.until)
        events = nextdns_query_events(args.domain, since_ts, until_ts, dump_raw=args.dump_raw)
        results = []
        for ev in events:
            r = resolve(ev["ip"], ev["ts"], args.radacct_root, args.linelog_root,
                        args.lookback_days, grace)
            r["domain"] = args.domain
            r["nextdns_timestamp"] = iso(ev["ts"])
            results.append(r)
    elif args.ip and args.at:
        ts = parse_user_time(args.at)
        results = [resolve(args.ip, ts, args.radacct_root, args.linelog_root,
                           args.lookback_days, grace)]
    else:
        ap.error("provide --domain with --since/--until, --ip with --at, or --audit with --since/--until")
        return

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        for r in results:
            print("-" * 60)
            for k in (
                "domain", "nextdns_timestamp", "ip", "timestamp", "user", "reason", "warning",
                "calling_station_id", "session_id", "session_start", "session_end",
                "session_closed_reason", "nas",
            ):
                if r.get(k) is not None:
                    print(f"{k:22} {r[k]}")


if __name__ == "__main__":
    main()
