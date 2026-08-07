from __future__ import annotations

import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import MagicMock, patch

from jarvis.local_ai import (
    backtest_workflow_decision,
    fast_local_decision,
    _clock_date_reply,
    is_backtest_review_request,
    is_ny_fib_strategy_request,
    is_today_market_review_request,
    fallback_local_decision,
    is_tradingview_workflow_request,
    local_model_instructions,
    normalize_local_decision,
    ny_fib_workflow_decision,
    parse_model_json,
    request_local_decision,
    tradingview_workflow_decision,
)


class LocalAITests(unittest.TestCase):
    def test_time_and_date_are_deterministic_natural_local_speech(self) -> None:
        reply = _clock_date_reply(
            include_time=True,
            include_date=True,
            now=datetime(2026, 8, 4, 18, 7),
        )

        self.assertEqual(
            reply,
            "It is six oh seven P.M. on Tuesday, August fourth, twenty twenty-six.",
        )
        for phrase in (
            "Tell me the time and today's date",
            "What time is it?",
            "What is today's date?",
            "What day is it?",
        ):
            with self.subTest(phrase=phrase):
                decision = fast_local_decision(phrase)
                self.assertIsNotNone(decision)
                self.assertEqual(decision.mode, "conversation")
                self.assertEqual(decision.source, "fast_rules_clock")
                self.assertEqual(decision.actions, ())
    def test_common_status_questions_reply_immediately_without_planning_actions(self) -> None:
        cases = {
            "Tell me you're online": "I'm online, listening, and ready.",
            "Are you there?": "I'm online, listening, and ready.",
            "Can you hear me?": "I'm online, listening, and ready.",
            "Are you still listening?": "I'm online, listening, and ready.",
            "How are you doing?": "Operating smoothly. What can I handle for you?",
        }
        for transcript, expected_reply in cases.items():
            with self.subTest(transcript=transcript):
                decision = fast_local_decision(transcript)
                self.assertIsNotNone(decision)
                self.assertEqual(decision.mode, "conversation")
                self.assertEqual(decision.reply, expected_reply)
                self.assertEqual(decision.actions, ())
                self.assertEqual(decision.source, "fast_rules")

    def test_capability_question_explains_local_and_delegated_roles(self) -> None:
        decision = fast_local_decision("What can you do?")

        self.assertIsNotNone(decision)
        self.assertEqual(decision.mode, "conversation")
        self.assertIn("approved Mac actions", decision.reply)
        self.assertIn("TradingView analysis workflow", decision.reply)
        self.assertIn("ChatGPT", decision.reply)
        self.assertEqual(decision.actions, ())

    def test_model_contract_forbids_partial_navigation_plans(self) -> None:
        instructions = local_model_instructions()

        self.assertIn("Every explicitly requested navigation step", instructions)
        self.assertIn("use delegate instead of returning a partial plan", instructions)

    def test_4b_receives_a_compact_complete_contract(self) -> None:
        compact = local_model_instructions("small")
        full = local_model_instructions("large")

        self.assertLess(len(compact), len(full) * 0.55)
        self.assertIn('"mode":"action|conversation|delegate"', compact)
        self.assertIn("Every requested step must appear in order", compact)
        self.assertIn("open_app", compact)
        self.assertIn("verify_ui", compact)
        self.assertIn("send_message", compact)

    def test_parses_json_from_model_wrapping(self) -> None:
        value = parse_model_json(
            '<think>brief</think>\n```json\n{"mode":"conversation","reply":"Ready.","actions":[]}\n```'
        )
        self.assertEqual(value["mode"], "conversation")

    def test_repairs_only_common_trailing_commas_from_quantized_model(self) -> None:
        value = parse_model_json(
            '{"mode":"action","actions":[{"type":"open_app",'
            '"payload":{"name":"TradingView",},},],}'
        )

        self.assertEqual(value["actions"][0]["payload"]["name"], "TradingView")

    def test_validates_allowlisted_navigation_action(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Open a new tab",
                "actions": [
                    {
                        "type": "key_combo",
                        "payload": {"key": "t", "modifiers": ["command"]},
                    }
                ],
            },
            "Open a new tab",
            source="test",
        )
        self.assertEqual(decision.mode, "action")
        self.assertEqual(decision.actions[0]["type"], "key_combo")

    def test_rejects_unknown_or_malformed_actions(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Run something",
                "actions": [{"type": "shell", "payload": {"command": "whoami"}}],
            },
            "Run something",
            source="test",
        )
        self.assertEqual(decision.mode, "delegate")
        self.assertEqual(decision.actions, ())

    def test_financial_actions_are_always_delegated(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Press a shortcut",
                "actions": [
                    {"type": "key_combo", "payload": {"key": "return", "modifiers": []}}
                ],
            },
            "Buy this gold position",
            source="test",
        )
        self.assertEqual(decision.mode, "delegate")
        self.assertEqual(decision.actions, ())

    def test_message_send_is_validated_and_marked_external(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Send the owner a message",
                "actions": [
                    {
                        "type": "send_message",
                        "payload": {
                            "app": "Messages",
                            "recipient": "the owner",
                            "text": "Testing Jarvis",
                            "subject": "",
                        },
                    }
                ],
            },
            "Send the owner a message saying Testing Jarvis",
            source="test",
        )

        self.assertEqual(decision.mode, "action")
        self.assertEqual(decision.confirmation_level, "external")
        self.assertEqual(decision.actions[0]["type"], "send_message")

    def test_file_changes_and_shortcuts_require_sensitive_confirmation(self) -> None:
        home = Path.home()
        for transcript, action in (
            ("Move a.pdf from Downloads to Documents", {
                "type": "move_file",
                "payload": {
                    "source": str(home / "Downloads" / "a.pdf"),
                    "destination": str(home / "Documents" / "a.pdf"),
                },
            }),
            ("Trash a.pdf from Downloads", {
                "type": "trash_file",
                "payload": {"path": str(home / "Downloads" / "a.pdf")},
            }),
            ("Run my Evening shortcut", {
                "type": "run_shortcut",
                "payload": {"name": "Evening"},
            }),
        ):
            with self.subTest(action=action["type"]):
                decision = normalize_local_decision(
                    {"mode": "action", "summary": "Do it", "actions": [action]},
                    transcript,
                    source="test",
                )
                self.assertEqual(decision.mode, "action")
                self.assertEqual(decision.confirmation_level, "sensitive")

    def test_relative_file_paths_and_unknown_message_apps_are_rejected(self) -> None:
        for action in (
            {"type": "trash_file", "payload": {"path": "Downloads/a.pdf"}},
            {
                "type": "send_message",
                "payload": {"app": "Unknown", "recipient": "P", "text": "Hi"},
            },
        ):
            with self.subTest(action=action):
                decision = normalize_local_decision(
                    {"mode": "action", "summary": "Do it", "actions": [action]},
                    "Do it",
                    source="test",
                )
                self.assertEqual(decision.mode, "delegate")
                self.assertEqual(decision.actions, ())

    def test_bounded_multi_step_navigation_is_preserved_in_order(self) -> None:
        actions = [
            {"type": "open_app", "payload": {"name": "Notes"}},
            {"type": "wait", "payload": {"seconds": 1}},
            {"type": "verify_ui", "payload": {"label": "New Note"}},
            {"type": "click_ui", "payload": {"label": "New Note"}},
            {"type": "focus_ui", "payload": {"label": "Note text"}},
            {"type": "type_text", "payload": {"text": "Buy milk"}},
        ]
        decision = normalize_local_decision(
            {"mode": "action", "summary": "Create a note", "actions": actions},
            "Open Notes, create a new note, and type Buy milk",
            source="test",
        )

        self.assertEqual(decision.mode, "action")
        self.assertEqual([item["type"] for item in decision.actions], [
            "open_app", "wait", "verify_ui", "click_ui", "focus_ui", "type_text"
        ])

    def test_explicit_visible_result_completes_model_plan(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Open the page and verify it",
                "actions": [
                    {"type": "open_app", "payload": {"name": "Safari"}},
                    {"type": "wait", "payload": {"seconds": 1}},
                    {"type": "focus_ui", "payload": {"label": "Address field"}},
                    {"type": "type_text", "payload": {"text": "example.com"}},
                    {"type": "key_combo", "payload": {"key": "return", "modifiers": []}},
                ],
            },
            (
                "Open Safari, focus the address field, type example.com, press Return, "
                "wait for the page, then verify Example Domain is visible."
            ),
            source="model",
        )

        self.assertEqual(
            [action["type"] for action in decision.actions[-2:]],
            ["wait", "verify_ui"],
        )
        self.assertEqual(decision.actions[-1]["payload"]["label"], "Example Domain")

    def test_explicit_visible_result_delegates_when_plan_would_exceed_limit(self) -> None:
        actions = [
            {"type": "key_combo", "payload": {"key": "tab", "modifiers": []}}
            for _ in range(8)
        ]
        decision = normalize_local_decision(
            {"mode": "action", "summary": "Navigate", "actions": actions},
            "Navigate and verify Done is visible",
            source="model",
        )

        self.assertEqual(decision.mode, "delegate")
        self.assertEqual(decision.actions, ())

    def test_wait_is_bounded(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Wait too long",
                "actions": [{"type": "wait", "payload": {"seconds": 30}}],
            },
            "Wait",
            source="test",
        )
        self.assertEqual(decision.mode, "delegate")

    def test_generic_ui_plans_inherit_risk_from_the_request(self) -> None:
        external = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Send in Discord",
                "actions": [
                    {"type": "type_text", "payload": {"text": "On my way"}},
                    {"type": "key_combo", "payload": {"key": "return", "modifiers": []}},
                ],
            },
            "Send this Discord message: On my way",
            source="test",
        )
        sensitive = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Save the file",
                "actions": [{"type": "click_ui", "payload": {"label": "Save"}}],
            },
            "Save this file",
            source="test",
        )

        self.assertEqual(external.confirmation_level, "external")
        self.assertEqual(sensitive.confirmation_level, "sensitive")

    def test_fallback_keeps_common_navigation_available(self) -> None:
        app = fallback_local_decision("Open Safari")
        tab = fallback_local_decision("open a new tab")
        hello = fallback_local_decision("Hello Jarvis")
        compound = fallback_local_decision("Open Google Chrome and go to Crunchyroll")

        self.assertEqual(app.actions[0], {"type": "open_app", "payload": {"name": "Safari"}})
        self.assertEqual(tab.actions[0]["type"], "key_combo")
        self.assertEqual(hello.mode, "conversation")
        self.assertEqual(compound.mode, "delegate")

    def test_trading_view_alias_uses_installed_application_name(self) -> None:
        spoken = fast_local_decision("Open Trading View")
        modeled = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Open Trading View",
                "actions": [
                    {"type": "open_app", "payload": {"name": "Trading View"}}
                ],
            },
            "Open Trading View",
            source="test",
        )

        expected = {"type": "open_app", "payload": {"name": "TradingView"}}
        self.assertIsNotNone(spoken)
        assert spoken is not None
        self.assertEqual(spoken.mode, "action")
        self.assertEqual(spoken.source, "fast_rules")
        self.assertEqual(spoken.actions, (expected,))
        self.assertEqual(modeled.actions[0], expected)

    def test_simple_tradingview_launch_is_instant_but_compound_work_uses_model(self) -> None:
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
            decision = fast_local_decision(transcript)
            self.assertIsNotNone(decision, transcript)
            assert decision is not None
            self.assertEqual(decision.mode, "action", transcript)
            self.assertEqual(decision.source, "fast_rules", transcript)
            self.assertEqual(
                decision.actions,
                ({"type": "open_app", "payload": {"name": "TradingView"}},),
                transcript,
            )
        self.assertIsNone(fast_local_decision(
            "Open TradingView, go to the 5-minute chart, analyze it, and send it to Work"
        ))

    def test_guarded_tradingview_workflow_is_complete_and_ordered(self) -> None:
        transcript = (
            "Open TradingView, go to the 5-minute chart, scan the screen, "
            "analyze it, and send it to Work"
        )
        decision = tradingview_workflow_decision(transcript, source="model_9b_guarded")

        self.assertTrue(is_tradingview_workflow_request(transcript))
        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(decision.source, "model_9b_guarded")
        self.assertEqual(decision.confirmation_level, "standard")
        self.assertEqual(
            [action["type"] for action in decision.actions],
            [
                "open_app",
                "wait",
                "send_tradingview_review_to_work",
            ],
        )
        self.assertEqual(decision.actions[2]["payload"]["timeframes"], [5, 15, 60, 240])
        task = decision.actions[-1]["payload"]["task"]
        self.assertIn("both the MGC gold chart and DXY", task)
        self.assertIn("full New York", task)
        self.assertIn("developing Asia", task)
        self.assertIn("1-hour", task)
        self.assertIn("4-hour", task)
        self.assertIn("do not place", task)

    def test_spoken_tradingview_interval_words_keep_complete_review_set(self) -> None:
        for phrase in (
            "five minute chart", "fifteen minutes", "one hour chart", "four hour chart",
        ):
            with self.subTest(phrase=phrase):
                decision = tradingview_workflow_decision(
                    f"Open TradingView, use the {phrase}, analyze it, and send it to Work",
                    source="test",
                )
                self.assertIsNotNone(decision)
                assert decision is not None
                review = decision.actions[-1]
                self.assertEqual(review["type"], "send_tradingview_review_to_work")
                self.assertEqual(review["payload"]["timeframes"], [5, 15, 60, 240])

    def test_tradingview_analysis_defaults_to_five_minutes_when_stt_drops_interval(self) -> None:
        decision = tradingview_workflow_decision(
            "Open TradingView, center the candles, analyze the screen, and send it to Work",
            source="test",
        )

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(decision.actions[-1]["payload"]["timeframes"], [5, 15, 60, 240])
        self.assertEqual(len(decision.actions), 3)

    def test_model_output_cannot_omit_guarded_tradingview_steps(self) -> None:
        decision = normalize_local_decision(
            {"mode": "delegate", "summary": "Send to ChatGPT", "actions": []},
            "Open TradingView, switch to 5 minutes, analyze the chart, and send it to Work",
            source="model_9b",
        )

        self.assertEqual(decision.mode, "action")
        self.assertEqual(decision.source, "model_9b_guarded")
        self.assertEqual(decision.actions[0]["payload"]["name"], "TradingView")
        self.assertEqual(decision.actions[-1]["type"], "send_tradingview_review_to_work")

    def test_model_review_action_is_canonicalized_without_duplicate_prepare(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Prepare and send the chart review",
                "actions": [
                    {"type": "open_app", "payload": {"name": "TradingView"}},
                    {"type": "prepare_tradingview_chart", "payload": {"interval": 5}},
                    {
                        "type": "send_tradingview_review_to_work",
                        "payload": {
                            "task": "Review the chart",
                            "timeframes": [5, 15, 60, 240],
                        },
                    },
                ],
            },
            "Open the trading chart, capture MGC and DXY, then send the review to Work",
            source="model_9b",
        )

        self.assertEqual(decision.source, "model_9b_guarded")
        self.assertEqual(
            [action["type"] for action in decision.actions],
            ["open_app", "wait", "send_tradingview_review_to_work"],
        )
        self.assertEqual(decision.actions[-1]["payload"]["timeframes"], [5, 15, 60, 240])
        self.assertIn("both the MGC gold chart and DXY", decision.actions[-1]["payload"]["task"])

    def test_today_market_phrases_use_instant_four_timeframe_review(self) -> None:
        phrases = (
            "Do today's technical analysis",
            "Do my daily technical analysis",
            "Do my daily technical analysis and send it to Work",
            "do todays scans",
            "Scan today's market",
            "Please run today's MGC and DXY review",
            "Analyze the market today",
        )
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertTrue(is_today_market_review_request(phrase))
                decision = fast_local_decision(phrase)
                self.assertIsNotNone(decision)
                assert decision is not None
                self.assertEqual(decision.source, "fast_rules")
                self.assertEqual(
                    [action["type"] for action in decision.actions],
                    ["open_app", "wait", "send_tradingview_review_to_work"],
                )
                self.assertEqual(
                    decision.actions[-1]["payload"]["timeframes"],
                    [5, 15, 60, 240],
                )

    def test_ny_fib_strategy_aliases_use_the_guarded_one_minute_workflow(self) -> None:
        phrases = (
            "Use my strat",
            "Use my strategy",
            "Mark out NY",
            "Fib NY",
            "Fibonacci the New York range",
            "Draw my NY range",
            "Map the New York session",
            "Jarvis, mark New York with my fib please",
        )
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertTrue(is_ny_fib_strategy_request(phrase))
                decision = fast_local_decision(phrase)
                self.assertIsNotNone(decision)
                assert decision is not None
                self.assertEqual(decision.mode, "action")
                self.assertEqual(decision.source, "fast_rules")
                self.assertEqual(decision.confirmation_level, "standard")
                self.assertEqual(
                    [action["type"] for action in decision.actions],
                    ["open_app", "wait", "mark_tradingview_ny_range_fib"],
                )
                self.assertEqual(decision.actions[0]["payload"]["name"], "TradingView")
                self.assertEqual(decision.actions[-1]["payload"], {})

    def test_ny_fib_rule_does_not_catch_analysis_or_financial_execution(self) -> None:
        for phrase in (
            "Summarize the New York session",
            "Explain my strategy",
            "Open strategy settings",
        ):
            with self.subTest(phrase=phrase):
                self.assertFalse(is_ny_fib_strategy_request(phrase))
        financial = fast_local_decision("Use my strat and buy gold")
        self.assertIsNotNone(financial)
        assert financial is not None
        self.assertEqual(financial.mode, "delegate")
        self.assertEqual(financial.actions, ())

    def test_model_cannot_replace_the_named_ny_fib_workflow(self) -> None:
        decision = normalize_local_decision(
            {"mode": "delegate", "summary": "Do something else", "actions": []},
            "Mark out NY with my Fib",
            source="model_9b",
        )

        self.assertEqual(decision.source, "model_9b_guarded")
        self.assertEqual(
            [action["type"] for action in decision.actions],
            ["open_app", "wait", "mark_tradingview_ny_range_fib"],
        )
        self.assertIn("MGC 1m", decision.summary)

    def test_unrelated_today_phrases_do_not_trigger_market_scan(self) -> None:
        for phrase in (
            "Summarize today's meeting",
            "Open today's notes",
            "What is today's weather",
        ):
            with self.subTest(phrase=phrase):
                self.assertFalse(is_today_market_review_request(phrase))

    def test_four_timeframe_test_and_tradingview_scan_aliases_use_review_workflow(self) -> None:
        phrases = (
            "do my four timeframe test",
            "run the 4 time frame scan",
            "do my TradingView scan",
            "do my TradingView scan like the four timeframe test",
        )
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                decision = request_local_decision(phrase)
                self.assertEqual(decision.mode, "action")
                self.assertEqual(decision.source, "fast_rules")
                self.assertEqual(
                    decision.actions[-1]["type"],
                    "send_tradingview_review_to_work",
                )
                self.assertEqual(
                    decision.actions[-1]["payload"]["timeframes"],
                    [5, 15, 60, 240],
                )

    def test_backtest_phrases_capture_visible_chart_without_navigation(self) -> None:
        phrases = (
            "Read my backtest",
            "Scan my back test",
            "Analyze my back testing",
            "Ask why this backtest rejected from the FVG",
        )
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertTrue(is_backtest_review_request(phrase))
                decision = fast_local_decision(phrase)
                self.assertIsNotNone(decision)
                assert decision is not None
                self.assertEqual(decision.source, "fast_rules")
                self.assertEqual(len(decision.actions), 1)
                self.assertEqual(decision.actions[0]["type"], "send_active_window_to_work")
                task = decision.actions[0]["payload"]["task"]
                self.assertIn("historical replay evidence", task)
                self.assertIn(f"User inquiry: {phrase}", task)
                self.assertIn("without hindsight", task)
                self.assertIn("do not place", task)

    def test_today_backtest_prefers_visible_backtest_capture(self) -> None:
        decision = backtest_workflow_decision(
            "Scan today's backtest and explain the New York reversal",
            source="fast_rules",
        )
        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(
            [action["type"] for action in decision.actions],
            ["send_active_window_to_work"],
        )

    def test_browser_and_site_command_is_split_into_fast_ordered_actions(self) -> None:
        decision = fast_local_decision("Open Google Chrome and go to Crunchyroll")

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(decision.source, "fast_rules")
        self.assertEqual([action["type"] for action in decision.actions], ["open_chrome_url"])
        self.assertEqual(
            decision.actions[0]["payload"]["url"],
            "https://www.crunchyroll.com",
        )

    def test_important_pinned_sites_use_only_approved_chrome_action(self) -> None:
        expected = {
            "Hulu": "https://www.hulu.com/hub/home",
            "Netflix": "https://www.netflix.com/browse",
            "Snapchat": "https://web.snapchat.com/",
            "Insta": "https://www.instagram.com/",
            "Fidelity": "https://digital.fidelity.com/ftgw/digital/portfolio/summary",
            "Xbox": "https://www.xbox.com/",
        }
        for site, url in expected.items():
            with self.subTest(site=site):
                decision = fast_local_decision(f"Open {site}")
                self.assertIsNotNone(decision)
                assert decision is not None
                self.assertEqual(
                    decision.actions,
                    ({"type": "open_chrome_url", "payload": {"url": url}},),
                )
                self.assertEqual(decision.confirmation_level, "standard")

    def test_passive_pinned_site_followup_stays_on_instant_rules(self) -> None:
        decision = fast_local_decision(
            "Open Chrome, go to Hulu, then scroll to Continue Watching and verify it is visible"
        )

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(decision.source, "fast_rules")
        self.assertEqual(
            [action["type"] for action in decision.actions],
            ["open_chrome_url", "wait", "scroll", "verify_ui"],
        )
        self.assertEqual(
            decision.actions[-1]["payload"]["label"],
            "Continue Watching",
        )

    def test_normalizer_repairs_pronoun_verification_and_missing_scroll(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Find the requested section",
                "actions": [
                    {"type": "open_app", "payload": {"name": "Google Chrome"}},
                    {"type": "verify_ui", "payload": {"label": "it"}},
                ],
            },
            "Open Chrome, scroll to Continue Watching and verify that it is visible",
            source="test",
        )

        self.assertEqual(
            [action["type"] for action in decision.actions],
            ["open_app", "scroll", "verify_ui"],
        )
        self.assertEqual(decision.actions[-1]["payload"]["label"], "Continue Watching")

    def test_common_multi_step_note_uses_instant_rules(self) -> None:
        decision = fast_local_decision(
            "Open Notes, create a new note, and type Jarvis test"
        )

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(decision.source, "fast_rules")
        self.assertEqual(
            [action["type"] for action in decision.actions],
            ["open_app", "wait", "key_combo", "wait", "type_text"],
        )

    def test_common_message_uses_instant_external_plan(self) -> None:
        decision = fast_local_decision(
            "Send Jane a message saying I am on my way"
        )

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(decision.source, "fast_rules")
        self.assertEqual(decision.confirmation_level, "external")
        self.assertEqual(decision.actions[0]["type"], "send_message")

    def test_policy_contract_is_versioned_and_prompt_has_no_placeholder_url(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Open Safari",
                "actions": [{"type": "open_app", "payload": {"name": "Safari"}}],
            },
            "Open Safari",
            source="test",
        )

        self.assertEqual(decision.to_dict()["policy_version"], "1")
        self.assertNotIn("https://example.com", local_model_instructions("small"))
        self.assertNotIn("https://example.com", local_model_instructions("large"))

    def test_app_only_request_cannot_acquire_an_invented_url(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Open Chrome",
                "actions": [{
                    "type": "open_chrome_url",
                    "payload": {"url": "https://example.com"},
                }],
            },
            "Open Chrome",
            source="model_4b",
        )

        self.assertEqual(decision.mode, "action")
        self.assertEqual(decision.actions, (
            {"type": "open_app", "payload": {"name": "Google Chrome"}},
        ))

    def test_unmentioned_url_in_a_multi_step_plan_is_rejected(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Open Chrome and focus the address field",
                "actions": [
                    {
                        "type": "open_chrome_url",
                        "payload": {"url": "https://example.com"},
                    },
                    {"type": "focus_ui", "payload": {"label": "Address field"}},
                ],
            },
            "Open Chrome and focus the address field",
            source="model_9b",
        )

        self.assertEqual(decision.mode, "delegate")
        self.assertEqual(decision.actions, ())

    def test_explicit_manual_browser_sequence_does_not_preopen_the_url(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Open and verify Example Domain",
                "actions": [
                    {
                        "type": "open_chrome_url",
                        "payload": {"url": "https://example.com"},
                    },
                    {"type": "wait", "payload": {"seconds": 0.8}},
                    {"type": "focus_ui", "payload": {"label": "Address field"}},
                    {"type": "type_text", "payload": {"text": "example.com"}},
                    {"type": "key_combo", "payload": {"key": "return", "modifiers": []}},
                    {"type": "wait", "payload": {"seconds": 1.0}},
                    {"type": "verify_ui", "payload": {"label": "Example Domain"}},
                ],
            },
            (
                "Open Chrome, focus the address field, type example.com, press Return, "
                "and verify Example Domain is visible"
            ),
            source="model_9b",
        )

        self.assertEqual(decision.mode, "action")
        self.assertEqual(decision.actions[0], {
            "type": "open_app", "payload": {"name": "Google Chrome"},
        })
        self.assertNotIn("open_chrome_url", [item["type"] for item in decision.actions])

    def test_private_credentialed_and_nonstandard_urls_are_rejected(self) -> None:
        for url in (
            "http://127.0.0.1/admin",
            "https://user:pass@example.com",
            "https://example.com:8443",
        ):
            with self.subTest(url=url):
                decision = normalize_local_decision(
                    {
                        "mode": "action",
                        "summary": "Open the URL",
                        "actions": [{"type": "open_url", "payload": {"url": url}}],
                    },
                    f"Open {url}",
                    source="model_4b",
                )
                self.assertEqual(decision.mode, "delegate")

    def test_mixed_external_and_file_side_effects_are_rejected(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Create a folder and send a message",
                "actions": [
                    {
                        "type": "create_folder",
                        "payload": {"path": str(Path.home() / "Documents" / "Jarvis Test")},
                    },
                    {
                        "type": "send_message",
                        "payload": {
                            "app": "Messages",
                            "recipient": "the owner",
                            "text": "Done",
                            "subject": "",
                        },
                    },
                ],
            },
            "Create a Jarvis Test folder in Documents, then message the owner saying Done",
            source="model_9b",
        )

        self.assertEqual(decision.mode, "delegate")

    def test_terminal_handoff_must_be_last(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Send the window and open Notes",
                "actions": [
                    {
                        "type": "send_active_window_to_work",
                        "payload": {"task": "Summarize the active window"},
                    },
                    {"type": "open_app", "payload": {"name": "Notes"}},
                ],
            },
            "Send the active window to Work and then open Notes",
            source="model_9b",
        )

        self.assertEqual(decision.mode, "delegate")

    def test_optimizer_deduplicates_actions_and_merges_waits(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Open Safari and verify Done",
                "actions": [
                    {"type": "open_app", "payload": {"name": "Safari"}},
                    {"type": "open_app", "payload": {"name": "Safari"}},
                    {"type": "wait", "payload": {"seconds": 0.4}},
                    {"type": "wait", "payload": {"seconds": 0.6}},
                    {"type": "verify_ui", "payload": {"label": "Done"}},
                ],
            },
            "Open Safari and verify Done is visible",
            source="model_4b",
        )

        self.assertEqual(
            [action["type"] for action in decision.actions],
            ["open_app", "wait", "verify_ui"],
        )
        self.assertEqual(decision.actions[1]["payload"]["seconds"], 1.0)

    def test_protected_jarvis_paths_are_rejected_before_confirmation(self) -> None:
        decision = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Trash Jarvis Code",
                "actions": [{
                    "type": "trash_file",
                    "payload": {"path": str(Path.home() / "Jarvis" / "Code")},
                }],
            },
            "Trash the Jarvis Code folder",
            source="model_9b",
        )

        self.assertEqual(decision.mode, "delegate")

    def test_wake_politeness_and_instead_stay_on_instant_rules(self) -> None:
        decision = fast_local_decision(
            "Jarvis, could you open Chrome instead please?"
        )

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(decision.source, "fast_rules")
        self.assertEqual(decision.actions, (
            {"type": "open_app", "payload": {"name": "Google Chrome"}},
        ))

    @patch("jarvis.local_ai.urlopen")
    def test_deterministic_app_request_never_loads_a_model(self, model_endpoint) -> None:
        decision = request_local_decision(
            "Jarvis, could you open Chrome instead please?"
        )

        model_endpoint.assert_not_called()
        self.assertEqual(decision.source, "fast_rules")
        self.assertEqual(decision.actions[0]["type"], "open_app")

    @patch.dict("os.environ", {"JARVIS_DASHBOARD_TOKEN": "s" * 64})
    @patch("jarvis.local_ai.urlopen")
    def test_model_request_carries_the_ephemeral_dashboard_token(self, model_endpoint) -> None:
        response = MagicMock()
        response.__enter__.return_value.read.return_value = (
            b'{"mode":"delegate","summary":"Send to ChatGPT","source":"model_4b"}'
        )
        model_endpoint.return_value = response

        request_local_decision("Navigate to the visible account section")

        request = model_endpoint.call_args.args[0]
        self.assertEqual(request.headers["X-jarvis-token"], "s" * 64)

    def test_named_window_display_and_percentage_phrases_use_fast_rules(self) -> None:
        expected = {
            "fullscreen tradingview on monitor": {
                "target": "TradingView", "display": "xb283k", "layout": "maximize",
            },
            "move farm rpg to mac on half the screen": {
                "target": "Farm RPG", "display": "mac", "layout": "left_half",
            },
            "resize chat gpt on the monitor to 25%": {
                "target": "ChatGPT", "display": "xb283k", "layout": "percent", "percent": 25,
            },
            "move this window to the Mac": {
                "target": "frontmost", "display": "mac", "layout": "preserve",
            },
        }
        for transcript, payload in expected.items():
            with self.subTest(transcript=transcript):
                decision = request_local_decision(transcript)
                self.assertEqual(decision.mode, "action")
                self.assertEqual(decision.source, "fast_rules")
                self.assertEqual(decision.confirmation_level, "standard")
                self.assertEqual(decision.actions, ({
                    "type": "move_resize_window", "payload": payload,
                },))

    def test_natural_window_phrases_and_speech_aliases_stay_local(self) -> None:
        expected = {
            "make treating you full screen on the monitor": {
                "target": "TradingView", "display": "xb283k", "layout": "maximize",
            },
            "put Farm R P G on half the Mac screen": {
                "target": "Farm RPG", "display": "mac", "layout": "left_half",
            },
            "resize Chat G P T to 25 percent on the external display": {
                "target": "ChatGPT", "display": "xb283k", "layout": "percent", "percent": 25,
            },
            "move trading view to the right side of the monitor": {
                "target": "TradingView", "display": "xb283k", "layout": "right_half",
            },
        }
        for transcript, payload in expected.items():
            with self.subTest(transcript=transcript):
                decision = request_local_decision(transcript)
                self.assertEqual(decision.mode, "action")
                self.assertNotEqual(decision.source, "model_4b_policy")
                self.assertEqual(decision.actions, ({
                    "type": "move_resize_window", "payload": payload,
                },))

    def test_natural_close_tab_phrase_stays_local(self) -> None:
        decision = request_local_decision("close the Crunchyroll tab in Google Chrome")

        self.assertEqual(decision.mode, "action")
        self.assertEqual(decision.confirmation_level, "sensitive")
        self.assertEqual(decision.actions, ({
            "type": "close_chrome_tab", "payload": {"query": "Crunchyroll"},
        },))

    @patch.dict("os.environ", {"JARVIS_DASHBOARD_TOKEN": "s" * 64})
    @patch("jarvis.local_ai.urlopen")
    def test_model_delegate_cannot_send_local_window_command_to_chatgpt(self, model_endpoint) -> None:
        response = MagicMock()
        response.__enter__.return_value.read.return_value = (
            b'{"mode":"delegate","summary":"Send to ChatGPT","source":"model_4b_policy"}'
        )
        model_endpoint.return_value = response

        decision = request_local_decision("resize the active app somehow on my monitor")

        self.assertEqual(decision.mode, "conversation")
        self.assertIn("no screen scan", decision.reply)
        self.assertTrue(decision.source.endswith("_local_guard"))

    def test_close_tab_and_normal_quit_are_sensitive_and_protected(self) -> None:
        tab = request_local_decision("close the Hulu tab")
        app = request_local_decision("quit Chrome")
        protected = request_local_decision("quit Jarvis")

        self.assertEqual(tab.actions, ({
            "type": "close_chrome_tab", "payload": {"query": "Hulu"},
        },))
        self.assertEqual(tab.confirmation_level, "sensitive")
        self.assertEqual(app.actions, ({
            "type": "quit_app", "payload": {"name": "Google Chrome"},
        },))
        self.assertEqual(app.confirmation_level, "sensitive")
        self.assertEqual(protected.mode, "conversation")
        self.assertIn("Nothing was sent to ChatGPT", protected.reply)

    def test_modeled_window_target_must_be_spoken_and_percentage_bounded(self) -> None:
        valid = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Resize ChatGPT",
                "actions": [{
                    "type": "move_resize_window",
                    "payload": {
                        "target": "ChatGPT", "display": "xb283k",
                        "layout": "percent", "percent": 25,
                    },
                }],
            },
            "Resize ChatGPT on the external monitor to 25 percent",
            source="model_9b",
        )
        invented = normalize_local_decision(
            {
                "mode": "action",
                "summary": "Move Notes",
                "actions": [{
                    "type": "move_resize_window",
                    "payload": {
                        "target": "Notes", "display": "mac", "layout": "maximize",
                    },
                }],
            },
            "Move ChatGPT to the Mac and maximize it",
            source="model_9b",
        )

        self.assertEqual(valid.mode, "action")
        self.assertEqual(valid.actions[0]["payload"]["percent"], 25)
        self.assertEqual(invented.mode, "delegate")

    def test_multi_window_sentence_bypasses_single_step_fast_rule(self) -> None:
        decision = fast_local_decision(
            "Move TradingView to the monitor fullscreen, then move Farm RPG to the Mac on half the screen"
        )

        self.assertIsNone(decision)


if __name__ == "__main__":
    unittest.main()
