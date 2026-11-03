"""common/tls.py: TLS verification decided per host, against OCP_CA_FILE then certifi (local server only)."""

import http.server
import os
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "helpers"))

from tui.common import tls  # noqa: E402


class _Server:
    """HTTPS on 127.0.0.1 with a fresh self-signed certificate (SAN localhost + 127.0.0.1)."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.cert, key = d / "cert.pem", d / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj",
                        "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                        "-keyout", str(key), "-out", str(self.cert)], check=True, capture_output=True)

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = b'{"ok": true}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        class Quiet(http.server.ThreadingHTTPServer):
            def handle_error(self, request, client_address):
                pass                      # the probe hangs up right after the handshake

        self.httpd = Quiet(("127.0.0.1", 0), H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(self.cert, key)
        self.httpd.socket = ctx.wrap_socket(self.httpd.socket, server_side=True)
        self.url = f"https://localhost:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()


class VerifyFor(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = _Server()

    @classmethod
    def tearDownClass(cls):
        cls.srv.close()

    def setUp(self):
        tls._memo.clear()
        tls._noted.clear()
        tls.NOTICES.clear()
        self.echo = tls.ECHO
        tls.ECHO = False

    def tearDown(self):
        tls.ECHO = self.echo

    def test_self_signed_is_not_verified_and_says_so_once(self):
        with patch.dict(os.environ, {"OCP_CA_FILE": ""}):
            self.assertIs(tls.verify_for(self.srv.url, "test API"), False)
            self.assertIs(tls.verify_for(self.srv.url + "/other/path"), False)      # memoized per host:port
        notes = tls.drain()
        self.assertEqual(len(notes), 1)
        self.assertIn("test API: TLS certificate not verified", notes[0])
        self.assertIn("OCP_CA_FILE", notes[0])
        self.assertEqual(tls.NOTICES, [])

    def test_ocp_ca_file_turns_verification_on(self):
        with patch.dict(os.environ, {"OCP_CA_FILE": str(self.srv.cert)}):
            self.assertEqual(tls.verify_for(self.srv.url), str(self.srv.cert))
        self.assertEqual(tls.drain(), [])

    def test_http_and_empty_urls_are_not_https(self):
        self.assertIs(tls.verify_for("http://localhost:1"), False)
        self.assertIs(tls.verify_for(""), False)
        self.assertEqual(tls.drain(), [])

    def test_request_json_takes_a_ca_bundle_path(self):
        import softwarehub_service_instance_helpers as h
        self.assertEqual(h.request_json(self.srv.url + "/x", verify=str(self.srv.cert)), {"ok": True})
        with self.assertRaises(RuntimeError):                    # the default trust store rejects it
            h.request_json(self.srv.url + "/x", verify=True)
        self.assertEqual(h.request_json(self.srv.url + "/x", verify=False), {"ok": True})

    def test_kube_verifies_an_insecure_kubeconfig_when_a_ca_vouches(self):
        from kubernetes import client

        from tui.common.kube import Kube
        before = client.Configuration.get_default_copy()
        try:
            with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
                f.write(f"""apiVersion: v1
kind: Config
clusters: [{{name: c, cluster: {{server: "{self.srv.url}", insecure-skip-tls-verify: true}}}}]
users: [{{name: u, user: {{token: t}}}}]
contexts: [{{name: x, context: {{cluster: c, user: u}}}}]
current-context: x
""")
            with patch.dict(os.environ, {"OCP_CA_FILE": str(self.srv.cert)}):
                kube = Kube(kubeconfig=f.name)
            self.assertTrue(kube.verified)
            self.assertEqual(kube.api.configuration.ssl_ca_cert, str(self.srv.cert))
            tls._memo.clear()
            with patch.dict(os.environ, {"OCP_CA_FILE": ""}):
                kube = Kube(kubeconfig=f.name)
            self.assertFalse(kube.verified)                     # self-signed, no CA: unverified as before
            self.assertTrue(any("Kubernetes API" in n for n in tls.drain()))
        finally:
            client.Configuration.set_default(before)
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
