from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from jarvis.screen import read_named_app_window


class NamedWindowScreenTests(unittest.TestCase):
    def test_named_window_uses_native_background_capture_and_ocr(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_binary = root / "Jarvis"
            helper = root / "jarvis-native"
            captures = root / "captures"
            app_binary.touch()
            helper.touch()
            captures.mkdir()
            commands: list[list[str]] = []

            def run(args: list[str], timeout: int = 20):
                commands.append(args)
                if "--capture-app-window" in args:
                    Path(args[-1]).write_bytes(b"png")
                    return subprocess.CompletedProcess(
                        args,
                        0,
                        json.dumps({
                            "ok": True,
                            "owner": "Google Chrome",
                            "title": "Article",
                            "focus_preserved": True,
                        }),
                        "",
                    )
                return subprocess.CompletedProcess(args, 0, "Visible article text", "")

            with (
                patch("jarvis.screen.JARVIS_APP_BINARY", app_binary),
                patch("jarvis.screen.NATIVE_HELPER", helper),
                patch("jarvis.screen.screenshot_directory_for", return_value=captures),
                patch("jarvis.screen._run", side_effect=run),
            ):
                screen = read_named_app_window("Google Chrome")

        self.assertEqual(commands[0][1:3], ["--capture-app-window", "Google Chrome"])
        self.assertEqual(commands[1][1], "ocr-image")
        self.assertEqual(screen.active_app, "Google Chrome")
        self.assertEqual(screen.window_title, "Article")
        self.assertEqual(screen.text, "Visible article text")
        self.assertEqual(screen.method, "jarvis-app-named-capture-plus-vision-ocr")
        self.assertIsNotNone(screen.screenshot_path)

    def test_named_window_failure_never_falls_back_to_the_active_screen(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            app_binary = Path(td) / "Jarvis"
            app_binary.touch()
            failure = subprocess.CompletedProcess(
                [], 1, "", "Notes is not open."
            )
            with (
                patch("jarvis.screen.JARVIS_APP_BINARY", app_binary),
                patch("jarvis.screen._run", return_value=failure) as run,
            ):
                screen = read_named_app_window("Notes")

        self.assertEqual(run.call_count, 1)
        self.assertIsNone(screen.screenshot_path)
        self.assertEqual(screen.method, "jarvis-app-named-capture-error")
        self.assertIn("Notes is not open", screen.text)

    def test_named_window_rejects_path_like_app_names(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid application name"):
            read_named_app_window("../../Safari")


if __name__ == "__main__":
    unittest.main()
