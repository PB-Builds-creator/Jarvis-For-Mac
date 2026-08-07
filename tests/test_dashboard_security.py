from __future__ import annotations

import http.client
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch
from urllib.parse import urlencode

from jarvis.dashboard import Handler


class DashboardSecurityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.token = "t" * 64
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server.jarvis_token = self.token  # type: ignore[attr-defined]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = int(self.server.server_address[1])

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(
        self,
        method: str,
        path: str,
        *,
        body: str = "",
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def test_unauthenticated_and_dns_rebinding_requests_are_rejected(self) -> None:
        status, headers, _ = self.request("GET", "/")
        self.assertEqual(status, 401)
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertIn("no-store", headers["Cache-Control"])
        self.assertIn("default-src 'none'", headers["Content-Security-Policy"])

        status, _, _ = self.request("GET", "/", headers={"Host": "evil.example"})
        self.assertEqual(status, 421)

        status, _, _ = self.request("GET", "/?token=wrong")
        self.assertEqual(status, 401)

        status, _, _ = self.request("GET", f"/read?token={self.token}")
        self.assertEqual(status, 401)

    @patch("jarvis.dashboard.home", return_value="private home")
    def test_one_time_bootstrap_becomes_an_http_only_strict_session(self, _home) -> None:
        status, headers, _ = self.request("GET", f"/?token={self.token}")
        self.assertEqual(status, 303)
        self.assertEqual(headers["Location"], "/")
        self.assertIn("HttpOnly", headers["Set-Cookie"])
        self.assertIn("SameSite=Strict", headers["Set-Cookie"])

        cookie = headers["Set-Cookie"].split(";", 1)[0]
        status, _, body = self.request("GET", "/", headers={"Cookie": cookie})
        self.assertEqual(status, 200)
        self.assertIn(b"private home", body)

    @patch("jarvis.dashboard.add_memory")
    def test_cookie_mutations_require_same_origin_and_get_cannot_mutate(self, add_memory) -> None:
        cookie = f"jarvis_session={self.token}"
        body = urlencode({"category": "test", "title": "Private", "body": "value"})
        headers = {
            "Cookie": cookie,
            "Content-Type": "application/x-www-form-urlencoded",
        }
        status, _, _ = self.request("POST", "/memory", body=body, headers=headers)
        self.assertEqual(status, 403)
        add_memory.assert_not_called()

        headers["Origin"] = f"http://127.0.0.1:{self.port}"
        status, response_headers, _ = self.request(
            "POST", "/memory", body=body, headers=headers
        )
        self.assertEqual(status, 303)
        self.assertEqual(response_headers["Location"], "/")
        add_memory.assert_called_once_with("test", "Private", "value")

        status, _, _ = self.request("GET", "/run?id=1", headers={"Cookie": cookie})
        self.assertEqual(status, 404)

    @patch("jarvis.dashboard.add_memory")
    def test_forged_referer_and_oversized_body_are_rejected(self, add_memory) -> None:
        cookie = f"jarvis_session={self.token}"
        body = urlencode({"category": "test", "title": "Private", "body": "value"})
        forged_headers = {
            "Cookie": cookie,
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": f"http://127.0.0.1:{self.port}.evil.example/",
        }
        status, _, _ = self.request("POST", "/memory", body=body, headers=forged_headers)
        self.assertEqual(status, 403)

        large_headers = {
            "X-Jarvis-Token": self.token,
            "Content-Type": "application/x-www-form-urlencoded",
        }
        status, _, _ = self.request(
            "POST",
            "/memory",
            body="x" * 65_537,
            headers=large_headers,
        )
        self.assertEqual(status, 413)
        add_memory.assert_not_called()

    @patch("jarvis.dashboard.export_memory", return_value="/private/export.json")
    def test_authorized_zero_body_export_remains_available(self, export_memory) -> None:
        headers = {"X-Jarvis-Token": self.token}
        status, _, body = self.request("POST", "/export", headers=headers)
        self.assertEqual(status, 200)
        self.assertIn(b"Memory Exported", body)
        export_memory.assert_called_once_with()

    @patch("jarvis.dashboard.ENGINE.status", return_value={"loaded": False})
    def test_internal_api_requires_the_ephemeral_header_token(self, status_call) -> None:
        status, _, _ = self.request("GET", "/api/local-ai/status")
        self.assertEqual(status, 401)
        status_call.assert_not_called()

        status, _, body = self.request(
            "GET",
            "/api/local-ai/status",
            headers={"X-Jarvis-Token": self.token},
        )
        self.assertEqual(status, 200)
        self.assertEqual(body, b'{"loaded": false}')


if __name__ == "__main__":
    unittest.main()
