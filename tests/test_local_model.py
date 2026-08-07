from __future__ import annotations

import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from jarvis.local_model import (
    LocalModelEngine,
    generation_token_limit,
    is_deep_conversation_request,
    model_is_installed,
    model_tier_for_request,
    task_usefulness_score,
    thermal_state_from_context,
)


class LocalModelRoutingTests(unittest.TestCase):
    def test_short_single_step_and_conversation_use_small_model(self) -> None:
        self.assertEqual(model_tier_for_request("Open Safari"), "small")
        self.assertEqual(model_tier_for_request("How are you today?"), "small")

    def test_memory_rich_conversation_uses_4b_with_larger_reply_budget(self) -> None:
        request = "What do you remember about my MGC strategy and why do I use ChatGPT?"
        context = "JARVIS OPERATIONAL AWARENESS\nRecent local dialogue:\n- the owner: Why?"

        self.assertTrue(is_deep_conversation_request(request, context=context))
        self.assertEqual(model_tier_for_request(request, context=context), "small")
        self.assertEqual(generation_token_limit("small", request), 512)

    def test_dependent_multi_step_request_uses_large_model(self) -> None:
        self.assertEqual(
            model_tier_for_request(
                "Open Chrome, then find Hulu and verify Continue Watching is visible."
            ),
            "large",
        )

    def test_tradingview_capture_workflow_uses_9b_tier(self) -> None:
        self.assertEqual(
            model_tier_for_request(
                "Open TradingView, switch to the 5-minute chart, analyze the screen, "
                "and send it to Work"
            ),
            "large",
        )

    def test_multiple_action_verbs_use_large_model(self) -> None:
        self.assertEqual(
            model_tier_for_request("Open Notes and type a grocery list"),
            "large",
        )

    def test_screen_context_planning_uses_large_model(self) -> None:
        self.assertEqual(
            model_tier_for_request(
                "Find Continue Watching",
                context="Chrome window with Hulu controls and several visible rows.",
            ),
            "large",
        )

    def test_native_thermal_state_is_parsed_without_sensor_polling(self) -> None:
        context = "Active app: TradingView\nSystem thermal state: serious\nVisible UI: MGC"
        self.assertEqual(thermal_state_from_context(context), "serious")
        self.assertEqual(thermal_state_from_context("Active app: Notes"), "unknown")

    def test_thermal_pressure_reserves_9b_for_useful_work(self) -> None:
        request = "Open Chrome, then find Hulu and verify Continue Watching is visible."
        nominal = "System thermal state: nominal\nVisible UI: Hulu"
        fair = "System thermal state: fair\nVisible UI: Hulu"
        serious = "System thermal state: serious\nVisible UI: Hulu"

        self.assertEqual(model_tier_for_request(request, context=nominal), "large")
        self.assertEqual(model_tier_for_request(request, context=fair), "large")
        self.assertEqual(model_tier_for_request(request, context=serious), "small")

        moderate = "Open Notes and type a grocery list"
        self.assertEqual(model_tier_for_request(moderate, context=fair), "small")

    def test_usefulness_and_generation_limits_keep_small_work_small(self) -> None:
        self.assertLess(
            task_usefulness_score("Open Safari"),
            task_usefulness_score("Open Safari, then find Downloads and verify it is visible"),
        )
        small_limit = generation_token_limit("small", "Open Safari")
        large_limit = generation_token_limit(
            "large", "Open Safari, then find Downloads and verify it is visible"
        )
        self.assertLess(small_limit, large_limit)
        self.assertLessEqual(large_limit, 448)

    def test_model_selection_has_no_model_or_network_latency(self) -> None:
        started = time.perf_counter()
        for _ in range(10_000):
            model_tier_for_request(
                "Open Chrome, then find Hulu and verify Continue Watching is visible.",
                context="Visible Chrome controls",
            )
        self.assertLess(time.perf_counter() - started, 1.0)

    def test_sharded_checkpoint_requires_every_weight_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            model_dir = Path(tmp)
            index = {
                "weight_map": {
                    "a": "model-00001-of-00002.safetensors",
                    "b": "model-00002-of-00002.safetensors",
                }
            }
            (model_dir / "model.safetensors.index.json").write_text(
                json.dumps(index), encoding="utf-8"
            )
            first = model_dir / "model-00001-of-00002.safetensors"
            second = model_dir / "model-00002-of-00002.safetensors"
            first.touch()
            self.assertFalse(model_is_installed(model_dir))
            second.touch()
            self.assertTrue(model_is_installed(model_dir))

    def test_idle_model_is_released_immediately(self) -> None:
        engine = LocalModelEngine()
        engine._model = object()
        engine._tokenizer = object()
        engine._last_used = time.monotonic() - 10

        with patch.object(engine, "_release_model") as release:
            engine._unload_if_idle(2)

        release.assert_called_once_with()

    def test_early_timer_reschedules_only_the_remaining_idle_time(self) -> None:
        engine = LocalModelEngine()
        engine._last_used = time.monotonic()

        with patch.object(engine, "_schedule_unload") as schedule:
            engine._unload_if_idle(120)

        remaining = schedule.call_args.args[0]
        self.assertGreater(remaining, 118)
        self.assertLessEqual(remaining, 120)


if __name__ == "__main__":
    unittest.main()
