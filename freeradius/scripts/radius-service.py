#!/usr/bin/env python3
"""Start RADIUS after stunnel is listening, or report container readiness.

Read Linux socket tables instead of opening LDAP connections for health checks.
A failed connection to Google is not evidence that the local stunnel died.
Supervisor handles process exits; Docker's healthcheck only reports readiness.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

SUPERVISOR_CONFIG = '/etc/supervisor/radius.conf'
ARGS_FILE = Path('/run/freeradius-supervisor/radius-args.json')


def has_socket(table, port, state, address=None):
    try:
        lines = Path('/proc/net/' + table).read_text().splitlines()[1:]
    except OSError:
        return False
    for line in lines:
        fields = line.split()
        ip, bound_port = fields[1].split(':')
        if int(bound_port, 16) == port and fields[3] == state:
            if address is None or ip == address:
                return True
    return False


def stunnel_ready():
    return has_socket('tcp', 1636, '0A', '0100007F')


def health():
    result = subprocess.run(
        ['supervisorctl', '-c', SUPERVISOR_CONFIG, 'status', 'stunnel', 'freeradius'],
        capture_output=True, text=True, timeout=5,
    )
    states = {row[0]: row[1] for line in result.stdout.splitlines()
              if len(row := line.split()) >= 2}
    if result.returncode or any(states.get(name) != 'RUNNING' for name in ('stunnel', 'freeradius')):
        raise RuntimeError('stunnel or FreeRADIUS is not RUNNING; inspect supervisorctl status')
    if not stunnel_ready():
        raise RuntimeError('stunnel is not listening on 127.0.0.1:1636')
    if not all(has_socket('udp', port, '07') for port in (1812, 1813)):
        raise RuntimeError('FreeRADIUS authentication/accounting sockets are not ready')
    print('stunnel and FreeRADIUS are running and listening')


def start():
    deadline = time.monotonic() + 30
    while not stunnel_ready():
        if time.monotonic() >= deadline:
            raise RuntimeError('stunnel did not start listening within 30 seconds')
        time.sleep(0.5)
    print('Validating FreeRADIUS configuration...', flush=True)
    subprocess.run(['freeradius', '-C'], check=True, timeout=60)
    print('Configuration OK — starting FreeRADIUS.', flush=True)
    args = json.loads(ARGS_FILE.read_text())
    os.execvp('freeradius', ['freeradius', '-f', *args])


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['start']:
            start()
        elif sys.argv[1:] == ['health']:
            health()
        else:
            raise RuntimeError('usage: radius-service.py start|health')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
