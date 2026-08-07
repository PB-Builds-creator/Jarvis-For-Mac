import subprocess
import tempfile
import unittest
import json
import struct
from pathlib import Path
from unittest.mock import MagicMock, patch

from jarvis.desktop_bridge import (
    DesktopResult,
    RouteDecision,
    _connect_live_desktop_ipc,
    ask_named_app_window,
    ask_jarvis,
    choose_route,
    open_desktop_thread,
    refresh_desktop_thread,
    run_desktop_task,
    screen_capture_failure,
    set_desktop_thread_name,
    submit_to_live_desktop_thread,
)
from jarvis.screen import ScreenRead


class DesktopBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary_database = tempfile.TemporaryDirectory()
        self.database_patch = patch(
            "jarvis.memory.DB_PATH",
            Path(self.temporary_database.name) / "jarvis.db",
        )
        self.database_patch.start()
        self.addCleanup(self.database_patch.stop)
        self.addCleanup(self.temporary_database.cleanup)

    @patch("jarvis.desktop_bridge.time.sleep")
    @patch("jarvis.desktop_bridge.socket.socket")
    def test_live_ipc_connect_retries_connection_refused(
        self, socket_factory, sleep
    ):
        refused = MagicMock()
        refused.connect.side_effect = ConnectionRefusedError(
            61, "Connection refused"
        )
        connected = MagicMock()
        socket_factory.side_effect = [refused, connected]

        result = _connect_live_desktop_ipc((0.15,))

        self.assertIs(result, connected)
        refused.close.assert_called_once_with()
        sleep.assert_called_once_with(0.15)
        connected.connect.assert_called_once()

    @patch("jarvis.desktop_bridge.time.sleep")
    @patch("jarvis.desktop_bridge.socket.socket")
    def test_live_ipc_connect_reports_clear_error_after_retries(
        self, socket_factory, sleep
    ):
        attempts = [MagicMock(), MagicMock()]
        for connection in attempts:
            connection.connect.side_effect = ConnectionRefusedError(
                61, "Connection refused"
            )
        socket_factory.side_effect = attempts

        with self.assertRaisesRegex(
            RuntimeError, "still starting or unavailable"
        ) as raised:
            _connect_live_desktop_ipc((0.15,))

        self.assertIsInstance(raised.exception.__cause__, ConnectionRefusedError)
        sleep.assert_called_once_with(0.15)
        for connection in attempts:
            connection.close.assert_called_once_with()

    def test_routes_tradingview_analysis_to_visual_work_task(self):
        screen = ScreenRead("TradingView", "MGC chart", "MGC 5m", None, "test")
        route = choose_route("Analyze the visible trading strategy setup.", screen)
        self.assertEqual(route.destination, "work")
        self.assertEqual(route.model, "gpt-5.6-sol")
        self.assertEqual(route.sandbox, "workspace-write")
        self.assertIn("visual chart analysis", route.reason)

    def test_routes_terminal_task_to_work(self):
        screen = ScreenRead("Terminal", "zsh", "test failure", None, "test")
        route = choose_route("Fix and test this error.", screen)
        self.assertEqual(route.destination, "work")
        self.assertEqual(route.sandbox, "workspace-write")

    def test_routes_every_chat_request_to_terra_medium(self):
        screen = ScreenRead("Google Chrome", "Article", "visible page", None, "test")
        route = choose_route("Summarize the visible page.", screen)
        self.assertEqual(route.destination, "chat")
        self.assertEqual(route.model, "gpt-5.6-terra")
        self.assertEqual(route.reasoning, "medium")

    def test_routes_every_work_request_to_sol_high(self):
        screen = ScreenRead("Notes", "Draft", "plain text", None, "test")
        route = choose_route("Review this.", screen, "work")
        self.assertEqual(route.destination, "work")
        self.assertEqual(route.model, "gpt-5.6-sol")
        self.assertEqual(route.reasoning, "high")

    @patch("jarvis.desktop_bridge.ask_jarvis")
    def test_named_app_policy_forces_chat_except_tradingview(self, ask):
        ask.return_value = MagicMock()

        ask_named_app_window("Review it.", "Google Chrome", "auto")
        ask.assert_called_once_with(
            "Review it.", "chat", target_app="Google Chrome"
        )
        ask.reset_mock()

        ask_named_app_window("Review it.", "TradingView", "work")
        ask.assert_called_once_with(
            "Review it.", "work", target_app="TradingView"
        )
        ask.reset_mock()
        ask_named_app_window("Review it.", "trading view", "auto")
        ask.assert_called_once_with(
            "Review it.", "work", target_app="TradingView"
        )
        with self.assertRaisesRegex(ValueError, "must route to Jarvis Chat"):
            ask_named_app_window("Review it.", "Notes", "work")
        with self.assertRaisesRegex(ValueError, "requires an application name"):
            ask_named_app_window("Review it.", "   ")

    @patch("jarvis.desktop_bridge.codex_binary", return_value=Path("/fake/codex"))
    @patch("jarvis.desktop_bridge.subprocess.run")
    def test_runs_signed_in_desktop_task_and_parses_thread(self, run, _binary):
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                '{"type":"thread.started","thread_id":"thread-123"}\n'
                '{"type":"item.completed","item":{"type":"agent_message","text":"Done."}}\n'
            ),
            stderr="",
        )
        screen = ScreenRead("TradingView", "MGC", "chart", None, "test")
        route = choose_route("Analyze the chart.", screen, "chat")
        with tempfile.TemporaryDirectory() as td, patch(
            "jarvis.desktop_bridge.DESKTOP_THREADS_PATH", Path(td) / "threads.json"
        ):
            result = run_desktop_task("context", screen, route)
        self.assertEqual(result.thread_id, "thread-123")
        self.assertEqual(result.answer, "Done.")
        command = run.call_args.args[0]
        self.assertIn("exec", command)
        self.assertIn("read-only", command)
        self.assertNotIn("resume", command)

    @patch("jarvis.desktop_bridge.codex_binary", return_value=Path("/fake/codex"))
    @patch("jarvis.desktop_bridge.subprocess.run")
    def test_resumes_saved_route_thread(self, run, _binary):
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                '{"type":"thread.started","thread_id":"thread-123"}\n'
                '{"type":"item.completed","item":{"type":"agent_message","text":"Again."}}\n'
            ),
            stderr="",
        )
        screen = ScreenRead("TradingView", "MGC", "chart", None, "test")
        route = choose_route("Analyze the chart.", screen, "chat")
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "threads.json"
            path.write_text(json.dumps({
                "version": 1,
                "routes": {
                    "chat": {
                        "thread_id": "thread-123",
                        "workspace": str(route.workspace),
                        "sandbox": route.sandbox,
                    }
                },
            }))
            with patch("jarvis.desktop_bridge.DESKTOP_THREADS_PATH", path):
                result = run_desktop_task("follow-up", screen, route)

        self.assertEqual(result.thread_id, "thread-123")
        self.assertEqual(result.answer, "Again.")
        command = run.call_args.args[0]
        self.assertIn("resume", command)
        self.assertIn("thread-123", command)

    @patch("jarvis.desktop_bridge.codex_binary", return_value=Path("/fake/codex"))
    @patch("jarvis.desktop_bridge.subprocess.run")
    def test_replaces_missing_saved_thread_once(self, run, _binary):
        run.side_effect = [
            subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="thread not found"),
            subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout='{"type":"thread.started","thread_id":"thread-new"}\n',
                stderr="",
            ),
        ]
        screen = ScreenRead("Terminal", "zsh", "error", None, "test")
        route = choose_route("Fix this error.", screen, "work")
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "threads.json"
            path.write_text(json.dumps({
                "version": 1,
                "routes": {
                    "work": {
                        "thread_id": "thread-missing",
                        "workspace": str(route.workspace),
                        "sandbox": route.sandbox,
                    }
                },
            }))
            with patch("jarvis.desktop_bridge.DESKTOP_THREADS_PATH", path):
                result = run_desktop_task("fix", screen, route)
                saved = json.loads(path.read_text())

        self.assertEqual(result.thread_id, "thread-new")
        self.assertEqual(saved["routes"]["work"]["thread_id"], "thread-new")
        self.assertEqual(run.call_count, 2)
        self.assertIn("resume", run.call_args_list[0].args[0])
        self.assertNotIn("resume", run.call_args_list[1].args[0])

    @patch("jarvis.desktop_bridge.subprocess.run")
    def test_open_thread_uses_existing_chatgpt_task(self, run):
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="", stderr=""
        )
        with tempfile.TemporaryDirectory() as td, patch(
            "jarvis.desktop_bridge.load_config"
        ) as config:
            app = Path(td) / "ChatGPT.app"
            app.mkdir()
            config.return_value.desktop_app_path = str(app)
            opened = open_desktop_thread("thread-123")

        self.assertTrue(opened)
        self.assertEqual(run.call_count, 1)
        self.assertIn("codex://threads/thread-123", run.call_args.args[0])

    @patch("jarvis.desktop_bridge.time.sleep")
    @patch("jarvis.desktop_bridge.open_desktop_thread")
    @patch("jarvis.desktop_bridge._load_desktop_threads")
    def test_refresh_switches_away_then_back_to_force_reload(self, load, opened, sleep):
        load.return_value = {
            "routes": {
                "chat": {"thread_id": "thread-chat"},
                "work": {"thread_id": "thread-work"},
            }
        }

        refresh_desktop_thread("thread-work")

        self.assertEqual(
            opened.call_args_list,
            [unittest.mock.call("thread-chat"), unittest.mock.call("thread-work")],
        )
        sleep.assert_called_once_with(0.8)

    @patch("jarvis.desktop_bridge.uuid.uuid4")
    @patch("jarvis.desktop_bridge.socket.socket")
    def test_live_renderer_submits_text_and_screenshot_to_visible_task(
        self, socket_factory, uuid4
    ):
        uuid4.side_effect = ["init-1", "request-1", "message-1"]
        initialized = json.dumps({
            "type": "response",
            "requestId": "init-1",
            "resultType": "success",
            "method": "initialize",
            "result": {"clientId": "client-1"},
        }).encode()
        submitted = json.dumps({
            "type": "response",
            "requestId": "request-1",
            "resultType": "success",
            "method": "thread-follower-start-turn",
            "result": {"result": {"turnId": "turn-1"}},
        }).encode()
        connection = MagicMock()
        connection.recv.side_effect = [
            struct.pack("<I", len(initialized)),
            initialized,
            struct.pack("<I", len(submitted)),
            submitted,
        ]
        socket_factory.return_value.__enter__.return_value = connection
        route = RouteDecision(
            destination="work",
            workspace=Path("/tmp"),
            model="gpt-5.6-sol",
            reasoning="high",
            sandbox="workspace-write",
            reason="test",
        )
        with tempfile.TemporaryDirectory() as td:
            ipc_path = Path(td) / "ipc.sock"
            ipc_path.touch()
            screenshots = [Path(td) / f"chart-{index}.png" for index in range(4)]
            for screenshot in screenshots:
                screenshot.touch()
            screen = ScreenRead(
                "TradingView",
                "MGC and DXY",
                "chart",
                str(screenshots[0]),
                "test",
                tuple(str(path) for path in screenshots[1:]),
            )
            with patch("jarvis.desktop_bridge.IPC_SOCKET_PATH", ipc_path):
                result = submit_to_live_desktop_thread(
                    "thread-123", "screen context", screen, route
                )

        self.assertEqual(result.thread_id, "thread-123")
        frames = [call.args[0] for call in connection.sendall.call_args_list]
        messages = [json.loads(frame[4:].decode()) for frame in frames]
        self.assertEqual(messages[0]["method"], "initialize")
        request = messages[1]
        self.assertEqual(request["method"], "thread-follower-start-turn")
        self.assertEqual(request["version"], 1)
        self.assertEqual(request["sourceClientId"], "client-1")
        self.assertEqual(request["params"]["conversationId"], "thread-123")
        turn = request["params"]["turnStartParams"]
        self.assertEqual(turn["clientUserMessageId"], "message-1")
        self.assertEqual(turn["input"][0], {"type": "text", "text": "screen context"})
        self.assertEqual([item["type"] for item in turn["input"]], [
            "text", "localImage", "localImage", "localImage", "localImage",
        ])
        self.assertEqual(
            [item["path"] for item in turn["input"][1:]],
            [str(path.resolve()) for path in screenshots],
        )
        self.assertEqual(turn["model"], "gpt-5.6-sol")

    @patch("jarvis.desktop_bridge.time.sleep")
    @patch("jarvis.desktop_bridge.open_desktop_thread")
    @patch("jarvis.desktop_bridge.uuid.uuid4")
    @patch("jarvis.desktop_bridge.socket.socket")
    def test_live_renderer_retries_only_when_no_renderer_owns_open_task(
        self, socket_factory, uuid4, opened, sleep
    ):
        uuid4.side_effect = [
            "init-1", "request-1", "message-1", "request-2", "message-2"
        ]
        responses = [
            {
                "type": "response", "requestId": "init-1",
                "resultType": "success", "method": "initialize",
                "result": {"clientId": "client-1"},
            },
            {
                "type": "response", "requestId": "request-1",
                "resultType": "error", "error": "no-client-found",
            },
            {
                "type": "response", "requestId": "request-2",
                "resultType": "success", "method": "thread-follower-start-turn",
                "result": {},
            },
        ]
        chunks = []
        for response in responses:
            payload = json.dumps(response).encode()
            chunks.extend([struct.pack("<I", len(payload)), payload])
        connection = MagicMock()
        connection.recv.side_effect = chunks
        socket_factory.return_value.__enter__.return_value = connection
        route = RouteDecision(
            "chat", Path("/tmp"), "gpt-5.6-terra", "medium", "read-only", "test"
        )
        screen = ScreenRead("Google Chrome", "Page", "text", None, "test")
        with tempfile.TemporaryDirectory() as td:
            ipc_path = Path(td) / "ipc.sock"
            ipc_path.touch()
            with patch("jarvis.desktop_bridge.IPC_SOCKET_PATH", ipc_path):
                submit_to_live_desktop_thread(
                    "thread-123", "context", screen, route
                )

        opened.assert_called_once_with("thread-123")
        sleep.assert_called_once_with(1.0)
        self.assertEqual(connection.sendall.call_count, 3)

    def test_reports_screen_permission_failure_before_handoff(self):
        screen = ScreenRead(
            "ChatGPT",
            "Unknown",
            "Jarvis does not yet have Screen Recording permission.",
            None,
            "jarvis-app-capture-error",
        )
        self.assertIn("Screen Recording permission", screen_capture_failure(screen))

    def test_named_app_not_open_error_is_not_misreported_as_permission(self):
        screen = ScreenRead(
            "Notes",
            "",
            "Jarvis.app could not capture Notes: Notes is not open.",
            None,
            "jarvis-app-named-capture-error",
        )
        failure = screen_capture_failure(screen)
        self.assertIn("Notes is not open", failure)
        self.assertNotIn("Screen Recording permission", failure)

    def test_named_tcc_denial_is_reported_as_screen_recording_permission(self):
        screen = ScreenRead(
            "Calculator",
            "",
            "Jarvis.app could not capture Calculator: The user declined TCCs.",
            None,
            "jarvis-app-named-capture-error",
        )
        failure = screen_capture_failure(screen)
        self.assertIn("requested app window", failure)
        self.assertIn("Screen Recording permission", failure)

    @patch("jarvis.desktop_bridge.open_desktop_thread")
    @patch("jarvis.desktop_bridge.run_desktop_task")
    @patch("jarvis.desktop_bridge.submit_to_live_desktop_thread")
    @patch("jarvis.desktop_bridge._saved_thread_id", return_value="thread-chat")
    @patch("jarvis.desktop_bridge.build_context")
    @patch("jarvis.desktop_bridge.notify")
    def test_named_window_handoff_includes_single_scope_and_terra_model(
        self, _notify, build, _saved, submit, run_task, opened
    ):
        with tempfile.NamedTemporaryFile(suffix=".png") as screenshot:
            screen = ScreenRead(
                "Google Chrome",
                "Article",
                "visible page",
                screenshot.name,
                "jarvis-app-named-capture-plus-vision-ocr",
            )
            route = choose_route("Review this window.", screen, "chat")
            build.return_value = ("screen context", screen)
            submit.return_value = DesktopResult(
                thread_id="thread-chat", answer="Done.", route=route
            )

            result = ask_jarvis(
                "Review this window.",
                "chat",
                target_app="Google Chrome",
            )

        self.assertEqual(result.route.model, "gpt-5.6-terra")
        self.assertEqual(result.route.reasoning, "medium")
        build.assert_called_once_with(
            "Review this window.",
            screenshot_paths=None,
            target_app="Google Chrome",
        )
        prompt = submit.call_args.args[1]
        self.assertIn("JARVIS ONE-SHOT NAMED-WINDOW ANALYSIS", prompt)
        self.assertIn("do not claim that any other window was scanned", prompt)
        run_task.assert_not_called()
        opened.assert_called_once_with("thread-chat")

    @patch("jarvis.desktop_bridge.open_desktop_thread")
    @patch("jarvis.desktop_bridge.run_desktop_task")
    @patch("jarvis.desktop_bridge.submit_to_live_desktop_thread")
    @patch("jarvis.desktop_bridge._saved_thread_id", return_value="thread-123")
    @patch("jarvis.desktop_bridge.choose_route")
    @patch("jarvis.desktop_bridge.build_context")
    @patch("jarvis.desktop_bridge.notify")
    def test_repeated_request_uses_live_renderer_not_hidden_task_service(
        self, _notify, build, choose, _saved, submit, run_task, opened
    ):
        with tempfile.NamedTemporaryFile(suffix=".png") as screenshot:
            screen = ScreenRead(
                "TradingView", "MGC", "chart", screenshot.name, "test"
            )
            route = RouteDecision(
                destination="work",
                workspace=Path("/tmp"),
                model="gpt-5.6-sol",
                reasoning="high",
                sandbox="workspace-write",
                reason="test",
            )
            build.return_value = ("screen context", screen)
            choose.return_value = route
            submit.return_value = DesktopResult(
                thread_id="thread-123", answer="Done.", route=route
            )

            result = ask_jarvis("Analyze this.", "work")

        self.assertEqual(result.thread_id, "thread-123")
        submit.assert_called_once()
        self.assertIn("screen context", submit.call_args.args[1])
        self.assertEqual(submit.call_args.args[2], screen)
        self.assertEqual(submit.call_args.args[3], route)
        self.assertIn("use view_image", submit.call_args.args[1])
        self.assertIn("directional bias", submit.call_args.args[1])
        self.assertIn("do not place, modify, or close a trade", submit.call_args.args[1])
        run_task.assert_not_called()
        opened.assert_called_once_with("thread-123")

    @patch("jarvis.desktop_bridge.choose_route")
    @patch("jarvis.desktop_bridge.build_context")
    @patch("jarvis.desktop_bridge.notify")
    def test_tradingview_requires_a_real_screenshot(self, notify, build, choose):
        screen = ScreenRead("TradingView", "MGC", "chart", None, "test")
        route = RouteDecision(
            destination="work",
            workspace=Path("/tmp"),
            model="gpt-5.6-sol",
            reasoning="high",
            sandbox="workspace-write",
            reason="test",
        )
        build.return_value = ("screen context", screen)
        choose.return_value = route

        with self.assertRaisesRegex(RuntimeError, "screenshot was not captured"):
            ask_jarvis("Analyze this.", "auto")

        notify.assert_called_with(
            "TradingView was detected, but its chart screenshot was not captured."
        )

    @patch("jarvis.desktop_bridge.select.select")
    @patch("jarvis.desktop_bridge.codex_binary", return_value=Path("/fake/codex"))
    @patch("jarvis.desktop_bridge.subprocess.Popen")
    def test_sets_persisted_desktop_task_name(self, popen, _binary, selected):
        process = popen.return_value
        process.stdout.readline.side_effect = [
            '{"id":1,"result":{}}\n',
            '{"id":2,"result":{}}\n',
        ]
        selected.side_effect = lambda streams, _write, _error, _timeout: (streams, [], [])

        set_desktop_thread_name("thread-123", "Jarvis Work — Build & Fix")

        command = popen.call_args.args[0]
        self.assertEqual(command, ["/fake/codex", "app-server"])
        sent = "".join(call.args[0] for call in process.stdin.write.call_args_list)
        self.assertIn('"method": "thread/name/set"', sent)
        self.assertIn('"threadId": "thread-123"', sent)
        self.assertIn("Jarvis Work", sent)
        process.terminate.assert_called_once()


if __name__ == "__main__":
    unittest.main()
