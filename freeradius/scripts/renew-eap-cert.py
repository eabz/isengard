#!/usr/bin/env python3
"""Host-side ACME renewal with staging, certificate checks and rollback.

The ACME container never mounts the live certificate directory or Docker socket.
Run daily as root via the supplied systemd timer. No third-party Python modules.
"""
import argparse
import fcntl
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CERT_FILES = ('server.key', 'server.pem', 'ca.pem')
SUPERVISOR = ['supervisorctl', '-c', '/etc/supervisor/radius.conf']


def interrupted(signum, frame):
    # Let finally/rollback run when systemd stops or times out the job.
    raise RuntimeError('Certificate job interrupted; cleaning up')


def run(args, *, allowed=(0,), timeout=120):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True, timeout=timeout)
    if result.returncode not in allowed:
        detail = (result.stdout + result.stderr)[-6000:]
        for name in ('CF_Token', 'CF_Key'):
            if os.environ.get(name):
                detail = detail.replace(os.environ[name], '[REDACTED]')
        raise RuntimeError(f'{args[0]} failed (exit {result.returncode}):\n{detail}')
    return result


def compose(*args, **kwargs):
    return run(['docker', 'compose', '--project-directory', ROOT,
                '-f', ROOT / 'docker-compose.yml', *args], **kwargs)


def acme(stage, state, *args, allowed=(0,)):
    cidfile = stage / 'acme-container.cid'
    cidfile.unlink(missing_ok=True)
    command = ['docker', 'run', '--rm', '--cidfile', cidfile,
               '-v', f'{state}:/acme.sh', '-v', f'{stage}:/out']
    for name in ('CF_Token', 'CF_Account_ID', 'CF_Zone_ID'):
        if os.environ.get(name):
            command.extend(['-e', name])  # Docker inherits it; no token in argv.
    command.extend([os.environ.get('ACME_IMAGE', 'neilpang/acme.sh'), *args])
    try:
        return run(command, allowed=allowed, timeout=900)
    finally:
        # Killing a timed-out Docker CLI does not stop its container. Remove
        # only the container launched here before releasing the renewal lock.
        if cidfile.exists():
            cid = cidfile.read_text().strip()
            if re.fullmatch(r'[0-9a-f]{64}', cid):
                run(['docker', 'rm', '-f', cid], allowed=(0, 1), timeout=30)


def validate(stage, domain):
    for name in CERT_FILES:
        if not (stage / name).is_file() or not (stage / name).stat().st_size:
            raise RuntimeError(f'ACME did not produce {name}')
    certificate = stage / 'server.pem'
    run(['openssl', 'x509', '-in', certificate, '-noout', '-checkend', '86400'])
    cert_public = run(['openssl', 'x509', '-in', certificate, '-noout', '-pubkey']).stdout
    key_public = run(['openssl', 'pkey', '-in', stage / 'server.key', '-pubout']).stdout
    if cert_public != key_public:
        raise RuntimeError('Certificate and private key do not match')
    # Verify the leaf and the actual chain presented by RADIUS against the
    # host trust store, including dates, serverAuth and hostname.
    leaf = stage / 'leaf.pem'
    run(['openssl', 'x509', '-in', certificate, '-out', leaf])
    run(['openssl', 'verify', '-purpose', 'sslserver', '-verify_hostname', domain,
         '-untrusted', certificate, leaf])
    run(['openssl', 'x509', '-in', stage / 'ca.pem', '-noout'])


def atomic_write(path, content, metadata=None):
    fd, temporary = tempfile.mkstemp(prefix='.cert-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
            if metadata is not None:
                os.fchown(output.fileno(), metadata.st_uid, metadata.st_gid)
            mode = stat.S_IMODE(metadata.st_mode) if metadata else (0o640 if path.suffix == '.key' else 0o644)
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def wait_healthy():
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        result = compose('exec', '-T', 'freeradius', 'python3',
                         '/usr/local/bin/radius-service.py', 'health', allowed=(0, 1), timeout=10)
        if result.returncode == 0:
            return
        time.sleep(2)
    raise RuntimeError('FreeRADIUS did not become healthy within 60 seconds after certificate activation')


def publish(stage, live, state, install_only=False):
    updated = {name: (stage / name).read_bytes() for name in CERT_FILES}
    previous = {name: ((live / name).read_bytes(), (live / name).stat())
                if (live / name).exists() else None for name in CERT_FILES}
    if all(previous[name] and previous[name][0] == updated[name] for name in CERT_FILES):
        print('Certificate unchanged; FreeRADIUS was not restarted.')
        return False
    if not install_only:
        compose('exec', '-T', 'freeradius', *SUPERVISOR, 'status', 'freeradius')
    # Keep a private on-disk backup as well as the in-memory rollback snapshot.
    backup = state / 'previous-eap'
    backup.mkdir(mode=0o700, exist_ok=True)
    backup.chmod(0o700)
    for name, item in previous.items():
        if item:
            atomic_write(backup / name, item[0])
        else:
            (backup / name).unlink(missing_ok=True)
    restarted = False
    try:
        for name in CERT_FILES:
            atomic_write(live / name, updated[name], previous[name][1] if previous[name] else None)
        if not install_only:
            # Check the new bundle/config while the current daemon continues
            # with its loaded certificate. Restart only RADIUS; stunnel and
            # the persistent TLS cache remain available.
            compose('exec', '-T', 'freeradius', 'freeradius', '-C')
            restarted = True
            compose('exec', '-T', 'freeradius', *SUPERVISOR, 'restart', 'freeradius')
            wait_healthy()
    except BaseException:
        for name, item in previous.items():
            if item:
                atomic_write(live / name, item[0], item[1])
            else:
                (live / name).unlink(missing_ok=True)
        if restarted:
            compose('exec', '-T', 'freeradius', *SUPERVISOR, 'restart', 'freeradius')
            wait_healthy()
        print(f'Certificate activation failed; previous files restored. Backup: {backup}', file=sys.stderr)
        raise
    print('Certificate installed.' if install_only else 'Certificate validated and activated; FreeRADIUS is healthy.')
    return True


def check_google_certificate():
    certificate = ROOT / 'raddb/certs/google/ldap-client.crt'
    result = run(['openssl', 'x509', '-in', certificate, '-noout', '-checkend', str(30 * 86400)], allowed=(0, 1))
    if result.returncode:
        print('ACTION REQUIRED: Google LDAP client certificate is missing, invalid, or expires within 30 days. '
              'Generate its replacement in Google Admin > Apps > LDAP > Authentication.', file=sys.stderr)
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('domain', help='EAP server hostname, matching RADIUS_HOSTNAME')
    parser.add_argument('--issue', action='store_true', help='initial DNS-01 issuance (requires CF_Token)')
    parser.add_argument('--install-only', action='store_true', help='bootstrap before the container exists; do not activate')
    args = parser.parse_args()
    domain = args.domain.lower()
    labels = domain.split('.')
    if len(domain) > 253 or len(labels) < 2 or any(
        not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in labels
    ):
        parser.error('domain must be a DNS hostname')
    if args.issue and not os.environ.get('CF_Token'):
        parser.error('initial issuance requires CF_Token in the environment')
    os.umask(0o077)
    state = ROOT / 'acme'
    live = ROOT / 'raddb/certs/eap'
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    state.chmod(0o700)
    live.mkdir(parents=True, exist_ok=True)
    with (state / '.renew.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Another certificate job is already running; skipping.')
            return
        google_ok = True if args.issue else check_google_certificate()
        with tempfile.TemporaryDirectory(prefix='eap-stage-', dir=state) as temporary:
            stage = Path(temporary)
            if args.issue:
                acme(stage, state, '--issue', '--dns', 'dns_cf', '-d', domain,
                     '--server', 'letsencrypt', '--keylength', '2048',
                     '--dnssleep', str(int(os.environ.get('ACME_DNSSLEEP', '30'))), allowed=(0, 2))
            else:
                acme(stage, state, '--renew', '-d', domain, '--server', 'letsencrypt', allowed=(0, 2))
            # Export even when not due: retry installation after a previous
            # renewal succeeded but activation failed. /out is always staging.
            acme(stage, state, '--install-cert', '-d', domain,
                 '--key-file', '/out/server.key', '--fullchain-file', '/out/server.pem',
                 '--ca-file', '/out/ca.pem', '--reloadcmd', '')
            validate(stage, domain)
            publish(stage, live, state, args.install_only)
        if not google_ok:
            raise RuntimeError('EAP certificate job completed; Google LDAP certificate needs attention')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
