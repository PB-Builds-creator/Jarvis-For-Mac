from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from jarvis.voice import (
    PushToTalkState,
    PushToTalkStateMachine,
    VoiceConfirmationRequired,
    cleanup_stale_voice_artifacts,
    dispatch_voice_intent,
    parse_voice_command,
)


class VoiceCommandTests(unittest.TestCase):
    @patch("jarvis.local_ai.urlopen")
    def test_open_tradingview_is_a_local_action_without_model_or_handoff(
        self, model_endpoint
    ) -> None:
        for transcript in (
            "Open TradingView",
            "Open trading view",
            "Jarvis, open TradingView",
            "Please open TradingView",
            "Launch TradingView",
            "Switch to trading view",
            "Bring up TradingView",
            "Show me TradingView",
            "Open the TradingView app",
            "Open TradingView instead",
            "Open treating you",
        ):
            intent = parse_voice_command(transcript)
            sent: list[tuple[str, str]] = []

            result = dispatch_voice_intent(
                intent,
                confirmed=True,
                sender=lambda task, route: sent.append((task, route)),
            )

            self.assertIs(result, intent, transcript)
            self.assertEqual(intent.kind, "local_action", transcript)
            self.assertEqual(intent.route, "local", transcript)
            self.assertEqual(intent.source, "fast_rules", transcript)
            self.assertEqual(intent.title, "Open TradingView", transcript)
            self.assertEqual(
                intent.actions,
                ({"type": "open_app", "payload": {"name": "TradingView"}},),
                transcript,
            )
            self.assertEqual(sent, [], transcript)
        model_endpoint.assert_not_called()

    def test_intended_commands_are_parsed(self) -> None:
        chart = parse_voice_command("Analyze this chart")
        window = parse_voice_command("summarize this window")
        work = parse_voice_command("Please send this to Work")

        self.assertEqual((chart.kind, chart.route), ("analyze_chart", "work"))
        self.assertIn("do not place", chart.task)
        self.assertEqual((window.kind, window.route), ("summarize_window", "chat"))
        self.assertEqual((work.kind, work.route), ("send_to_work", "work"))

    def test_named_app_scan_is_one_shot_and_routes_non_trading_apps_to_chat(self) -> None:
        cases = {
            "scan Chrome": "Google Chrome",
            "scan the Safari app": "Safari",
            "capture a Notes window": "Notes",
            "Jarvis, one-time scan Discord": "Discord",
        }
        for transcript, target in cases.items():
            with self.subTest(transcript=transcript):
                intent = parse_voice_command(transcript)
                self.assertEqual(intent.kind, "scan_app_window")
                self.assertEqual(intent.scan_target, target)
                self.assertEqual(intent.route, "chat")
                self.assertEqual(intent.source, "named_window_scan_rule")
                self.assertIn("single captured", intent.task)

    def test_tradingview_short_scan_remains_four_timeframe_but_once_is_single(self) -> None:
        four_timeframe = parse_voice_command("scan TradingView")
        one_shot = parse_voice_command("scan TradingView once")

        self.assertEqual(four_timeframe.kind, "local_action")
        self.assertEqual(
            four_timeframe.actions[-1]["type"],
            "send_tradingview_review_to_work",
        )
        self.assertEqual(
            four_timeframe.actions[-1]["payload"]["timeframes"],
            [5, 15, 60, 240],
        )
        self.assertEqual(one_shot.kind, "scan_app_window")
        self.assertEqual(one_shot.scan_target, "TradingView")
        self.assertEqual(one_shot.route, "work")
        self.assertIn("do not place", one_shot.task.casefold())

    def test_one_shot_scan_tolerates_multiple_recognition_errors(self) -> None:
        cases = (
            "skin training view wants",
            "scam treating you ones",
            "capture trading few one time",
            "review trading vue just once",
        )
        for transcript in cases:
            with self.subTest(transcript=transcript):
                intent = parse_voice_command(
                    transcript,
                    local_context="Active app: TradingView",
                )
                self.assertEqual(intent.kind, "scan_app_window")
                self.assertEqual(intent.scan_target, "TradingView")
                self.assertEqual(intent.route, "work")
                self.assertEqual(intent.transcript, "scan TradingView once")
                self.assertEqual(intent.heard_transcript, transcript)
                self.assertEqual(
                    intent.interpretation_reason,
                    "fuzzy_known_command",
                )
                self.assertGreaterEqual(intent.interpretation_confidence, 0.75)

    def test_one_shot_scan_uses_active_app_for_deictic_speech(self) -> None:
        tradingview = parse_voice_command(
            "can you scan the current chart one time",
            local_context="Active app: TradingView",
        )
        chrome = parse_voice_command(
            "please capture this window once",
            local_context="Active app: Google Chrome",
        )

        self.assertEqual(
            (tradingview.scan_target, tradingview.route, tradingview.transcript),
            ("TradingView", "work", "scan TradingView once"),
        )
        self.assertEqual(
            (chrome.scan_target, chrome.route, chrome.transcript),
            ("Google Chrome", "chat", "scan Google Chrome once"),
        )
        self.assertEqual(
            tradingview.interpretation_reason,
            "active_app_command_context",
        )

    @patch("jarvis.voice.request_local_decision")
    def test_context_matcher_does_not_turn_conversation_into_scan(self, planner) -> None:
        from jarvis.local_ai import LocalDecision

        planner.return_value = LocalDecision("delegate", "Send to ChatGPT")
        for transcript in (
            "can you explain this current chart once",
            "tell me about TradingView once",
            "what happened on this chart one time",
        ):
            with self.subTest(transcript=transcript):
                intent = parse_voice_command(
                    transcript,
                    local_context="Active app: TradingView",
                )
                self.assertNotEqual(intent.kind, "scan_app_window")
                self.assertEqual(intent.transcript, transcript)
                self.assertEqual(intent.interpretation_reason, "exact")

    def test_workflow_scan_nouns_are_not_mistaken_for_application_names(self) -> None:
        backtest = parse_voice_command("scan my backtest")
        market = parse_voice_command("scan today's market")

        self.assertEqual(backtest.kind, "local_action")
        self.assertEqual(backtest.actions[-1]["type"], "send_active_window_to_work")
        self.assertEqual(market.kind, "local_action")
        self.assertEqual(
            market.actions[-1]["type"],
            "send_tradingview_review_to_work",
        )

    def test_named_app_scan_requires_confirmation_and_uses_window_sender(self) -> None:
        intent = parse_voice_command("scan Chrome")
        ordinary: list[tuple[str, str]] = []
        scans: list[tuple[str, str, str]] = []

        with self.assertRaises(VoiceConfirmationRequired):
            dispatch_voice_intent(
                intent,
                confirmed=False,
                sender=lambda task, route: ordinary.append((task, route)),
                window_sender=lambda task, app, route: scans.append((task, app, route)),
            )
        result = dispatch_voice_intent(
            intent,
            confirmed=True,
            sender=lambda task, route: ordinary.append((task, route)),
            window_sender=lambda task, app, route: scans.append((task, app, route)),
        )

        self.assertIsNone(result)
        self.assertEqual(ordinary, [])
        self.assertEqual(len(scans), 1)
        self.assertEqual(scans[0][1:], ("Google Chrome", "chat"))

    @patch("jarvis.voice.request_local_decision")
    def test_compound_tradingview_workflow_reaches_local_planner_before_work_rule(
        self, planner
    ) -> None:
        from jarvis.local_ai import tradingview_workflow_decision

        transcript = (
            "Open TradingView, go to the 5-minute chart, scan the screen, "
            "analyze it, and send it to Work"
        )
        planner.return_value = tradingview_workflow_decision(
            transcript,
            source="model_9b_guarded",
        )

        intent = parse_voice_command(transcript, local_context="Active app: ChatGPT")

        planner.assert_called_once_with(transcript, context="Active app: ChatGPT")
        self.assertEqual(intent.kind, "local_action")
        self.assertEqual(intent.source, "model_9b_guarded")
        self.assertEqual(intent.actions[0]["payload"]["name"], "TradingView")
        self.assertEqual(intent.actions[-1]["type"], "send_tradingview_review_to_work")
        self.assertEqual(intent.actions[-1]["payload"]["timeframes"], [5, 15, 60, 240])

    def test_today_scan_voice_alias_uses_four_timeframe_workflow(self) -> None:
        intent = parse_voice_command("Do today's scans")

        self.assertEqual(intent.kind, "local_action")
        self.assertEqual(intent.source, "fast_rules")
        self.assertEqual(intent.actions[-1]["type"], "send_tradingview_review_to_work")
        self.assertEqual(intent.actions[-1]["payload"]["timeframes"], [5, 15, 60, 240])

    def test_daily_technical_analysis_sends_four_timeframes_to_work(self) -> None:
        intent = parse_voice_command("Do my daily technical analysis")

        self.assertEqual(intent.kind, "local_action")
        self.assertEqual(intent.route, "local")
        self.assertEqual(intent.source, "fast_rules")
        self.assertEqual(intent.actions[-1]["type"], "send_tradingview_review_to_work")
        self.assertEqual(intent.actions[-1]["payload"]["timeframes"], [5, 15, 60, 240])

    def test_ny_fib_voice_alias_uses_local_guarded_chart_drawing(self) -> None:
        intent = parse_voice_command("Jarvis, mark out NY with my Fib")

        self.assertEqual(intent.kind, "local_action")
        self.assertEqual(intent.route, "local")
        self.assertEqual(intent.source, "fast_rules")
        self.assertEqual(intent.confirmation_level, "standard")
        self.assertEqual(
            [action["type"] for action in intent.actions],
            ["open_app", "wait", "mark_tradingview_ny_range_fib"],
        )

    def test_four_timeframe_test_voice_alias_uses_local_review_workflow(self) -> None:
        intent = parse_voice_command("Do my TradingView scan like the four timeframe test")

        self.assertEqual(intent.kind, "local_action")
        self.assertEqual(intent.route, "local")
        self.assertEqual(intent.source, "fast_rules")
        self.assertEqual(intent.actions[-1]["type"], "send_tradingview_review_to_work")
        self.assertEqual(intent.actions[-1]["payload"]["timeframes"], [5, 15, 60, 240])

    def test_backtest_voice_alias_beats_generic_send_to_work_rule(self) -> None:
        intent = parse_voice_command("Read my backtest and send it to Work")

        self.assertEqual(intent.kind, "local_action")
        self.assertEqual(intent.source, "fast_rules")
        self.assertEqual(
            [action["type"] for action in intent.actions],
            ["send_active_window_to_work"],
        )
        self.assertIn("Read my backtest and send it to Work", intent.actions[0]["payload"]["task"])

    @patch("jarvis.voice.request_local_decision")
    def test_generic_transcript_is_preserved(self, planner) -> None:
        from jarvis.local_ai import LocalDecision

        planner.return_value = LocalDecision("delegate", "Send to ChatGPT")
        intent = parse_voice_command("  Explain what I am looking at  ")
        self.assertEqual(intent.kind, "jarvis_request")
        self.assertEqual(intent.task, "Explain what I am looking at")
        self.assertEqual(intent.route, "auto")

    @patch("jarvis.voice.request_local_decision")
    def test_delegated_window_command_is_never_sent_to_screen_scan_path(self, planner) -> None:
        from jarvis.local_ai import LocalDecision

        planner.return_value = LocalDecision(
            "delegate", "Send to ChatGPT", source="model_4b_policy"
        )
        intent = parse_voice_command("move TradingView somewhere on my monitor")
        sent: list[tuple[str, str]] = []

        result = dispatch_voice_intent(
            intent,
            confirmed=True,
            sender=lambda task, route: sent.append((task, route)),
        )

        self.assertIs(result, intent)
        self.assertEqual(intent.kind, "local_conversation")
        self.assertEqual(intent.route, "local")
        self.assertEqual(sent, [])

    def test_empty_transcript_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "No speech"):
            parse_voice_command(" \n ")

    def test_read_only_local_conversation_needs_no_confirmation(self) -> None:
        intent = parse_voice_command("Tell me the time and today's date")

        self.assertEqual(intent.kind, "local_conversation")
        self.assertFalse(intent.requires_confirmation)
        self.assertEqual(intent.source, "fast_rules_clock")
        self.assertIn("P.M.", intent.reply)
        self.assertEqual(
            dispatch_voice_intent(intent, confirmed=False, sender=lambda *_: None),
            intent,
        )

    @patch("jarvis.voice.request_local_decision")
    def test_every_voice_request_requires_preview_confirmation(self, planner) -> None:
        from jarvis.local_ai import LocalDecision

        planner.return_value = LocalDecision("delegate", "Send to ChatGPT")
        sent: list[tuple[str, str]] = []
        intent = parse_voice_command("Explain what I am looking at")

        with self.assertRaises(VoiceConfirmationRequired):
            dispatch_voice_intent(
                intent,
                confirmed=False,
                sender=lambda task, route: sent.append((task, route)),
            )

        self.assertEqual(sent, [])
        dispatch_voice_intent(
            intent,
            confirmed=True,
            sender=lambda task, route: sent.append((task, route)),
        )
        self.assertEqual(sent, [("Explain what I am looking at", "auto")])

    @patch("jarvis.voice.request_local_decision")
    def test_local_action_is_returned_only_after_confirmation(self, planner) -> None:
        from jarvis.local_ai import LocalDecision

        planner.return_value = LocalDecision(
            "action",
            "Open Safari",
            actions=({"type": "open_app", "payload": {"name": "Safari"}},),
            confirmation_level="sensitive",
        )
        intent = parse_voice_command("Open Safari")
        sent: list[tuple[str, str]] = []

        with self.assertRaises(VoiceConfirmationRequired):
            dispatch_voice_intent(
                intent,
                confirmed=False,
                sender=lambda task, route: sent.append((task, route)),
            )
        result = dispatch_voice_intent(
            intent,
            confirmed=True,
            sender=lambda task, route: sent.append((task, route)),
        )

        self.assertIs(result, intent)
        self.assertEqual(sent, [])
        self.assertEqual(intent.kind, "local_action")
        self.assertTrue(intent.requires_confirmation)
        self.assertEqual(intent.confirmation_level, "sensitive")

    @patch("jarvis.voice.request_local_decision")
    def test_local_ui_context_is_passed_only_to_local_planner(self, planner) -> None:
        from jarvis.local_ai import LocalDecision

        planner.return_value = LocalDecision("delegate", "Send to ChatGPT")
        parse_voice_command(
            "Navigate to the account page",
            local_context="Active app: Safari\nVisible UI: Account",
        )

        planner.assert_called_once_with(
            "Navigate to the account page",
            context="Active app: Safari\nVisible UI: Account",
        )

    def test_push_to_talk_state_is_explicit_and_cancelable(self) -> None:
        state = PushToTalkStateMachine()
        state.request_start()
        self.assertEqual(state.state, PushToTalkState.AUTHORIZING)
        state.permission_resolved(True)
        self.assertEqual(state.state, PushToTalkState.RECORDING)
        state.request_stop()
        self.assertEqual(state.state, PushToTalkState.TRANSCRIBING)
        state.transcription_ready("summarize this window")
        self.assertEqual(state.state, PushToTalkState.PREVIEW)
        state.finish_preview()
        self.assertEqual(state.state, PushToTalkState.IDLE)

        state.request_start()
        state.cancel()
        self.assertEqual(state.state, PushToTalkState.IDLE)

    def test_empty_audio_returns_to_idle(self) -> None:
        state = PushToTalkStateMachine()
        state.request_start()
        state.permission_resolved(True)
        state.request_stop()
        state.transcription_ready("  ")
        self.assertEqual(state.state, PushToTalkState.IDLE)

    def test_cleanup_is_scoped_to_old_known_voice_files(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            old_audio = root / "voice-old.wav"
            recent_text = root / "voice-recent.txt"
            unrelated = root / "notes.txt"
            old_audio.write_bytes(b"audio")
            recent_text.write_text("transcript")
            unrelated.write_text("keep")
            os.utime(old_audio, (10, 10))
            os.utime(recent_text, (95, 95))

            removed = cleanup_stale_voice_artifacts(
                root,
                older_than_seconds=20,
                now=100,
            )

            self.assertEqual(removed, [old_audio])
            self.assertFalse(old_audio.exists())
            self.assertTrue(recent_text.exists())
            self.assertTrue(unrelated.exists())


if __name__ == "__main__":
    unittest.main()
