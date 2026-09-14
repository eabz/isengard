"""Offline operations tests. Real OpenSSL; Docker/Google/ACME are mocked."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


renew = load('renew', 'renew-eap-cert.py')
service = load('service', 'radius-service.py')


class CertificateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.fixture = Path(cls.directory.name)
        cls.stage = cls.fixture / 'stage'
        cls.stage.mkdir()
        ca = cls.fixture / 'ca.pem'
        ca_key = cls.fixture / 'ca.key'
        key = cls.stage / 'server.key'
        csr = cls.fixture / 'server.csr'
        leaf = cls.fixture / 'leaf.pem'
        ext = cls.fixture / 'extensions'
        ext.write_text('basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n'
                       'subjectAltName=DNS:radius.test.invalid\n')
        commands = [
            ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=Test CA',
             '-days', '60', '-keyout', str(ca_key), '-out', str(ca)],
            ['openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=radius.test.invalid',
             '-keyout', str(key), '-out', str(csr)],
            ['openssl', 'x509', '-req', '-in', str(csr), '-CA', str(ca), '-CAkey', str(ca_key),
             '-CAcreateserial', '-days', '4', '-extfile', str(ext), '-out', str(leaf)],
        ]
        for command in commands:
            subprocess.run(command, check=True, capture_output=True)
        (cls.stage / 'server.pem').write_bytes(leaf.read_bytes() + ca.read_bytes())
        shutil.copyfile(ca, cls.stage / 'ca.pem')

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def validate(self, stage, domain='radius.test.invalid'):
        with patch.dict(os.environ, {'SSL_CERT_FILE': str(self.fixture / 'ca.pem')}):
            renew.validate(stage, domain)

    def test_valid_certificate_bundle(self):
        self.validate(self.stage)

    def test_wrong_hostname_is_rejected(self):
        with self.assertRaises(RuntimeError):
            self.validate(self.stage, 'another.test.invalid')

    def test_untrusted_chain_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            empty_trust = Path(temporary) / 'empty-ca.pem'
            empty_trust.write_text('')
            with patch.dict(os.environ, {'SSL_CERT_FILE': str(empty_trust), 'SSL_CERT_DIR': temporary}):
                with self.assertRaises(RuntimeError):
                    renew.validate(self.stage, 'radius.test.invalid')

    def test_wrong_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary)
            for name in renew.CERT_FILES:
                shutil.copyfile(self.stage / name, stage / name)
            shutil.copyfile(self.fixture / 'ca.key', stage / 'server.key')
            with self.assertRaisesRegex(RuntimeError, 'do not match'):
                self.validate(stage)

    def test_near_expiry_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary)
            for name in renew.CERT_FILES:
                shutil.copyfile(self.stage / name, stage / name)
            subprocess.run(['openssl', 'x509', '-req', '-in', str(self.fixture / 'server.csr'),
                            '-CA', str(self.fixture / 'ca.pem'), '-CAkey', str(self.fixture / 'ca.key'),
                            '-CAserial', str(self.fixture / 'ca.srl'), '-days', '0',
                            '-extfile', str(self.fixture / 'extensions'), '-out', str(stage / 'server.pem')],
                           check=True, capture_output=True)
            with self.assertRaises(RuntimeError):
                self.validate(stage)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.live = self.root / 'live'
        self.stage = self.root / 'stage'
        self.state = self.root / 'acme'
        for path in (self.live, self.stage, self.state):
            path.mkdir()
        for name in renew.CERT_FILES:
            (self.live / name).write_bytes(('old-' + name).encode())
            (self.stage / name).write_bytes(('new-' + name).encode())
            (self.live / name).chmod(0o640)
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def assert_old_files(self):
        for name in renew.CERT_FILES:
            self.assertEqual((self.live / name).read_bytes(), ('old-' + name).encode())

    def test_no_change_does_not_restart(self):
        for name in renew.CERT_FILES:
            shutil.copyfile(self.live / name, self.stage / name)
        with patch.object(renew, 'compose') as compose:
            self.assertFalse(renew.publish(self.stage, self.live, self.state))
        compose.assert_not_called()

    def test_validated_update_restarts_only_radius_and_preserves_permissions(self):
        with patch.object(renew, 'compose') as compose, patch.object(renew, 'wait_healthy') as healthy:
            self.assertTrue(renew.publish(self.stage, self.live, self.state))
        calls = [call.args for call in compose.call_args_list]
        self.assertEqual(calls[1], ('exec', '-T', 'freeradius', 'freeradius', '-C'))
        self.assertEqual(calls[2][-2:], ('restart', 'freeradius'))
        healthy.assert_called_once()
        for name in renew.CERT_FILES:
            self.assertEqual((self.live / name).read_bytes(), ('new-' + name).encode())
            self.assertEqual((self.live / name).stat().st_mode & 0o777, 0o640)
            self.assertEqual((self.state / 'previous-eap' / name).read_bytes(), ('old-' + name).encode())

    def test_failed_config_check_rolls_back_without_restart(self):
        with patch.object(renew, 'compose', side_effect=[None, RuntimeError('invalid config')]) as compose:
            with self.assertRaisesRegex(RuntimeError, 'invalid config'):
                renew.publish(self.stage, self.live, self.state)
        self.assertEqual(compose.call_count, 2)
        self.assert_old_files()

    def test_failed_activation_restores_and_restarts_old_certificate(self):
        with patch.object(renew, 'compose') as compose:
            with patch.object(renew, 'wait_healthy', side_effect=[RuntimeError('not ready'), None]):
                with self.assertRaisesRegex(RuntimeError, 'not ready'):
                    renew.publish(self.stage, self.live, self.state)
        restarts = [call for call in compose.call_args_list if call.args[-2:] == ('restart', 'freeradius')]
        self.assertEqual(len(restarts), 2)
        self.assert_old_files()

    def test_acme_timeout_removes_only_its_own_container(self):
        cid = 'a' * 64

        def fake_run(command, **kwargs):
            if command[:2] == ['docker', 'run']:
                self.assertNotIn(str(self.live), ' '.join(map(str, command)))
                (self.stage / 'acme-container.cid').write_text(cid)
                raise subprocess.TimeoutExpired(command, 900)
            return subprocess.CompletedProcess(command, 0)

        with patch.object(renew, 'run', side_effect=fake_run) as command:
            with self.assertRaises(subprocess.TimeoutExpired):
                renew.acme(self.stage, self.state, '--renew', '-d', 'radius.test.invalid')
        self.assertEqual(command.call_args_list[-1].args[0], ['docker', 'rm', '-f', cid])

    def test_skipped_renewal_still_retries_export_and_activation(self):
        def fake_acme(stage, state, *args, **kwargs):
            if args[0] == '--renew':
                return subprocess.CompletedProcess(args, 2)
            for name in renew.CERT_FILES:
                (stage / name).write_bytes(b'fixture')
            return subprocess.CompletedProcess(args, 0)

        with patch.object(renew, 'ROOT', self.root), patch.object(renew, 'acme', side_effect=fake_acme) as acme:
            with patch.object(renew, 'check_google_certificate', return_value=True), patch.object(renew, 'validate'):
                with patch.object(renew, 'publish') as publish, patch('sys.argv', ['renew', 'radius.test.invalid']):
                    old_umask = os.umask(0o077)
                    try:
                        renew.main()
                    finally:
                        os.umask(old_umask)
        self.assertEqual(acme.call_count, 2)
        publish.assert_called_once()


class HealthTests(unittest.TestCase):
    def test_socket_must_be_listening_on_loopback(self):
        header = 'header\n'
        with patch.object(Path, 'read_text', return_value=header + '0: 0100007F:0664 00000000:0000 0A 0\n'):
            self.assertTrue(service.stunnel_ready())
        with patch.object(Path, 'read_text', return_value=header + '0: 0100007F:0664 00000000:0000 01 0\n'):
            self.assertFalse(service.stunnel_ready())
        with patch.object(Path, 'read_text', return_value=header + '0: 00000000:0664 00000000:0000 0A 0\n'):
            self.assertFalse(service.stunnel_ready())

    def test_running_process_without_radius_socket_is_unhealthy(self):
        status = subprocess.CompletedProcess([], 0, 'stunnel RUNNING pid 10\nfreeradius RUNNING pid 20\n')
        with patch.object(service.subprocess, 'run', return_value=status), patch.object(service, 'stunnel_ready', return_value=True):
            with patch.object(service, 'has_socket', return_value=False):
                with self.assertRaisesRegex(RuntimeError, 'sockets are not ready'):
                    service.health()

    def test_stopped_stunnel_is_unhealthy(self):
        status = subprocess.CompletedProcess([], 3, 'stunnel EXITED\nfreeradius RUNNING pid 20\n')
        with patch.object(service.subprocess, 'run', return_value=status):
            with self.assertRaisesRegex(RuntimeError, 'not RUNNING'):
                service.health()


if __name__ == '__main__':
    unittest.main()
