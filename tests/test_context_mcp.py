import json
import unittest
from unittest.mock import patch

from jarvis.context import build_context, prepare_context
from jarvis.mcp_server import call_tool
from jarvis.screen import ScreenRead, screenshot_directory_for


class ContextMcpTests(unittest.TestCase):
    @patch("jarvis.context.open_chatgpt_project")
    @patch("jarvis.context.copy_to_clipboard")
    @patch("jarvis.context.read_active_window")
    def test_prepare_context(self, read, copy, open_project):
        read.return_value = ScreenRead("TradingView", "Gold chart", "MGC 5m VWAP FVG", None, "test")
        package = prepare_context("Analyze gold.")
        self.assertIn("TradingView", package)
        self.assertIn("Analyze gold", package)
        copy.assert_called_once()
        open_project.assert_called_once()

    @patch("jarvis.mcp_server.read_active_window")
    def test_mcp_read_active_window(self, read):
        read.return_value = ScreenRead("Chrome", "Jarvis", "hello", None, "test")
        result = call_tool("read_active_window", {})
        self.assertEqual(result["active_app"], "Chrome")

    def test_mcp_unknown_tool(self):
        with self.assertRaises(ValueError):
            call_tool("missing", {})

    def test_tradingview_captures_are_filed_with_chart_reviews(self):
        self.assertEqual(
            screenshot_directory_for("TradingView").name,
            "Chart Reviews",
        )
        self.assertEqual(screenshot_directory_for("Google Chrome").name, "Screenshots")

    @patch("jarvis.context.search_memories", return_value=[])
    @patch("jarvis.context.read_named_app_window")
    def test_named_window_context_is_labeled_as_background_one_shot(
        self, read_named, _memories
    ):
        read_named.return_value = ScreenRead(
            "Google Chrome", "Article", "visible page", "/tmp/chrome.png", "test"
        )

        package, screen = build_context("Review it.", target_app="Google Chrome")

        self.assertEqual(screen.active_app, "Google Chrome")
        read_named.assert_called_once_with("Google Chrome")
        self.assertIn("captured directly without activating that app", package)
        self.assertIn("Captured app:\nGoogle Chrome", package)
        self.assertNotIn("Active app:\nGoogle Chrome", package)


if __name__ == "__main__":
    unittest.main()
