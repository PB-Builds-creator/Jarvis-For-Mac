from __future__ import annotations

import unittest
from unittest.mock import Mock, patch

from jarvis.dashboard import parent_process_is_current, watch_parent


class StartupTests(unittest.TestCase):
    @patch("jarvis.dashboard.os.getppid", return_value=4242)
    def test_parent_identity_must_match(self, _getppid) -> None:
        self.assertTrue(parent_process_is_current(4242))
        self.assertFalse(parent_process_is_current(1111))
        self.assertFalse(parent_process_is_current(1))

    @patch("jarvis.dashboard.parent_process_is_current", return_value=False)
    def test_orphan_dashboard_shuts_down(self, _current) -> None:
        server = Mock()
        watch_parent(server, 4242)
        server.shutdown.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
