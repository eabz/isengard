"""Real Supervisor with harmless fixture processes; no Google or RADIUS ports.

Optional: install supervisor in a test venv to run this integration test.
"""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(importlib.util.find_spec('supervisor'), 'Supervisor is not installed in this test interpreter')
class SupervisionTests(unittest.TestCase):
    def test_restart_failed_stunnel_without_restarting_radius_and_clean_shutdown(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child = root / 'child.py'
            child.write_text('''import os, signal, sys, time
from pathlib import Path
root, name = Path(sys.argv[1]), sys.argv[2]
attempts = root / (name + '.attempts')
attempt = int(attempts.read_text()) + 1 if attempts.exists() else 1
attempts.write_text(str(attempt))
if name == 'stunnel' and attempt <= 2:
    raise SystemExit(1)
def stop(*args):
    (root / (name + '.stopped')).write_text(str(os.getpid()))
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
(root / (name + '.ready')).write_text(str(os.getpid()))
while True:
    time.sleep(0.1)
''')
            config = (ROOT / 'supervisor/radius.conf').read_text()
            config = config.replace('user=root\n', '')
            config = config.replace('/run/freeradius-supervisor', str(root))
            config = config.replace('/usr/bin/stunnel4 /etc/stunnel/google-ldap.conf',
                                    f'{sys.executable} {child} {root} stunnel')
            config = config.replace('/usr/bin/python3 /usr/local/bin/radius-service.py start',
                                    f'{sys.executable} {child} {root} freeradius')
            path = root / 'supervisor.conf'
            path.write_text(config)

            def pid(name):
                result = subprocess.run([sys.executable, '-m', 'supervisor.supervisorctl',
                                         '-c', str(path), 'pid', name], capture_output=True, text=True, timeout=3)
                return int(result.stdout.strip()) if result.returncode == 0 and result.stdout.strip().isdigit() else 0

            def wait(predicate):
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    time.sleep(0.1)
                self.fail('Supervisor did not reach the expected state')

            def ready(name):
                marker = root / (name + '.ready')
                return marker.exists() and marker.read_text().strip() == str(pid(name))

            with (root / 'supervisor.log').open('w') as output:
                server = subprocess.Popen([sys.executable, '-m', 'supervisor.supervisord', '-c', str(path)],
                                          stdout=output, stderr=subprocess.STDOUT)
            try:
                attempts = root / 'stunnel.attempts'
                wait(lambda: attempts.exists() and int(attempts.read_text() or '0') >= 3 and ready('stunnel'))
                wait(lambda: ready('freeradius'))
                radius_pid = pid('freeradius')
                self.assertGreater(radius_pid, 0)
                stunnel_pid = pid('stunnel')
                os.kill(stunnel_pid, signal.SIGKILL)
                wait(lambda: pid('stunnel') not in (0, stunnel_pid) and ready('stunnel'))
                self.assertEqual(pid('freeradius'), radius_pid)
                self.assertEqual(int((root / 'freeradius.attempts').read_text()), 1)
                server.terminate()
                server.wait(timeout=15)
                self.assertTrue((root / 'stunnel.stopped').exists())
                self.assertTrue((root / 'freeradius.stopped').exists())
            finally:
                if server.poll() is None:
                    server.terminate()
                    server.wait(timeout=15)


if __name__ == '__main__':
    unittest.main()
