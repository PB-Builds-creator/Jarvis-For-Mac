import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from jarvis.actions import approve_action, execute_action, list_actions, queue_action
from jarvis.config import JarvisConfig
from jarvis.events import emit_event, save_event_rule
from jarvis.foundation_planner import FoundationPlanner
from jarvis.memory import (
    add_memory,
    correct_memory,
    forget_memory,
    get_memory,
    search_memories,
)
from jarvis.privacy import redact_for_cloud
from jarvis.project_index import index_projects, search_projects
from jarvis.routines import get_routine, run_routine, save_routine
from jarvis.trading_journal import (
    create_review,
    list_reviews,
    update_review_analysis,
)
from jarvis.transcription import (
    add_vocabulary,
    apply_vocabulary,
    write_voice_context_snapshot,
)


class AdvancedFoundationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.database_path = Path(self.temporary.name) / "jarvis.db"
        self.database_patch = patch("jarvis.memory.DB_PATH", self.database_path)
        self.database_patch.start()

    def tearDown(self):
        self.database_patch.stop()
        self.temporary.cleanup()

    def test_structured_memory_correction_privacy_and_forgetting(self):
        original = add_memory(
            "preference",
            "Voice",
            "Use the built-in microphone.",
            kind="preference",
            scope="personal",
            privacy="private",
        )
        self.assertEqual(
            search_memories("built-in", include_private=False),
            [],
        )
        correction = correct_memory(
            original,
            "Use the Razer Seiren V3 Mini when connected.",
            reason="Hardware preference changed.",
        )
        self.assertIsNone(get_memory(original))
        current = get_memory(correction)
        self.assertEqual(current["supersedes_id"], original)
        self.assertEqual(current["kind"], "correction")
        self.assertTrue(forget_memory(correction))
        self.assertIsNone(get_memory(correction))

    def test_versioned_routine_parameters_and_dry_run(self):
        routine_id = save_routine(
            "Open project",
            [{"type": "open_app", "payload": {"name": "{{app}}"}}],
            parameters={"app": "Notes"},
        )
        self.assertGreater(routine_id, 0)
        first = run_routine("Open project", dry_run=True)
        self.assertEqual(first.steps[0]["payload"]["name"], "Notes")
        save_routine(
            "Open project",
            [{"type": "open_app", "payload": {"name": "{{app}}"}}],
            parameters={"app": "Calendar"},
        )
        self.assertEqual(get_routine("Open project")["version"], 2)

    def test_event_engine_matches_without_automatic_mutation(self):
        save_event_rule(
            "Razer disconnected",
            "microphone_disconnected",
            trigger={"device": "Razer"},
            notification_text="Razer microphone disconnected.",
            risk_policy="notify",
            cooldown_seconds=30,
            quiet_hours_exempt=True,
        )
        outcome = emit_event(
            "microphone_disconnected",
            {"device": "Razer Seiren V3 Mini"},
            deliver_notifications=False,
        )
        self.assertEqual(outcome.matched_rules, ("Razer disconnected",))
        self.assertEqual(outcome.notifications, ("Razer microphone disconnected.",))
        self.assertEqual(outcome.queued_routines, ())

    def test_local_project_index_and_search(self):
        project = Path(self.temporary.name) / "Project"
        project.mkdir()
        (project / "assistant.py").write_text(
            "class VoiceRouter:\n    def select_microphone(self):\n        return 'Razer'\n",
            encoding="utf-8",
        )
        cfg = SimpleNamespace(
            project_index_enabled=True,
            project_index_roots=(str(project),),
        )
        with patch("jarvis.project_index.load_config", return_value=cfg):
            result = index_projects()
            matches = search_projects("VoiceRouter")
        self.assertEqual(result["indexed"], 1)
        self.assertEqual(Path(matches[0]["path"]).name, "assistant.py")

    def test_trading_journal_is_analysis_only(self):
        review_id = create_review(
            [str(Path(self.temporary.name) / "5m.png")],
            timeframes=[5],
            metadata={"analysis_only": True},
        )
        self.assertTrue(update_review_analysis(
            review_id,
            bias="Bullish",
            invalidation="Below the visible session low",
        ))
        review = list_reviews()[0]
        self.assertEqual(review["review_id"], review_id)
        self.assertEqual(review["bias"], "Bullish")
        self.assertNotIn("order", review)

    def test_vocabulary_and_secret_redaction(self):
        add_vocabulary("trading few", replacement="TradingView", category="apps")
        self.assertEqual(
            apply_vocabulary("open trading few"),
            "open TradingView",
        )
        snapshot = Path(self.temporary.name) / "voice-context.json"
        write_voice_context_snapshot(snapshot)
        context = json.loads(snapshot.read_text(encoding="utf-8"))
        self.assertIn("TradingView", context["phrases"])
        self.assertIn(
            {"phrase": "trading few", "replacement": "TradingView"},
            context["replacements"],
        )
        redacted = redact_for_cloud("api_key=abcdefghijk123456")
        self.assertNotIn("abcdefghijk123456", redacted.text)
        self.assertIn("common_secret", redacted.labels)

    def test_foundation_planner_uses_typed_normalization(self):
        planner = FoundationPlanner(Path("/private/tmp/fake-helper"))
        planner._status_cache = {"available": True, "reason": "available"}
        planner._status_checked_at = 10**12
        response = {
            "ok": True,
            "decision": {
                "mode": "action",
                "summary": "Open Notes",
                "reply": "",
                "actions": [
                    {"type": "open_app", "payload": {"name": "Notes"}},
                ],
            },
            "availability": {"available": True, "reason": "available"},
        }
        with patch("jarvis.foundation_planner.load_config") as load, patch.object(
            planner,
            "_run",
            return_value=(response, 0),
        ):
            load.return_value = SimpleNamespace(
                apple_foundation_models_enabled=True,
                apple_foundation_model_timeout_seconds=30,
            )
            decision = planner.decide("Open Notes")
        self.assertEqual(decision.source, "apple_foundation_model")
        self.assertEqual(decision.actions[0]["type"], "open_app")

    def test_transaction_precondition_fails_closed_with_checkpoint(self):
        action_id = queue_action(
            "open_url",
            {"url": "https://example.com"},
            preconditions=[
                {"type": "path_exists", "value": "/definitely/not/here"},
            ],
            max_attempts=2,
        )
        self.assertTrue(approve_action(action_id))
        with self.assertRaisesRegex(RuntimeError, "Precondition failed"):
            execute_action(action_id)
        action = list_actions()[0]
        self.assertEqual(action["status"], "failed")

    def test_specialist_defaults_are_local_and_on_demand(self):
        cfg = JarvisConfig()
        self.assertIn("whisper-cli", cfg.transcription_fallback_command)
        self.assertIn("mlx_vlm.generate", cfg.visual_fallback_command)
        self.assertTrue(cfg.visual_fallback_enabled)


class NativeRoadmapSourceTests(unittest.TestCase):
    def test_app_intents_and_spoken_followups_are_built(self):
        root = Path(__file__).parents[1]
        intents = (root / "native" / "JarvisIntents.swift").read_text()
        menu = (root / "native" / "JarvisMenuBar.swift").read_text()
        bootstrap = (root / "bootstrap.command").read_text()
        self.assertIn("ScanTradingViewIntent", intents)
        self.assertIn("AppShortcutsProvider", intents)
        self.assertIn("AVSpeechSynthesizerDelegate", menu)
        self.assertIn("Automatically Record Follow-ups", menu)
        self.assertIn("Emergency Stop All Actions", menu)
        self.assertIn("whisper_large_v3_turbo", menu)
        self.assertIn("viewfinder.circle.fill", menu)
        self.assertIn("-framework AppIntents", bootstrap)
        self.assertIn("appintentsmetadataprocessor", bootstrap)
        self.assertIn("JarvisAppIntents.swiftconstvalues", bootstrap)
        self.assertIn("Jarvis App Intents metadata extraction failed.", bootstrap)

    def test_apple_planner_and_personal_helpers_are_built(self):
        root = Path(__file__).parents[1]
        planner = (root / "native" / "JarvisFoundationPlanner.swift").read_text()
        personal = (root / "native" / "JarvisPersonalData.swift").read_text()
        bootstrap = (root / "bootstrap.command").read_text()
        self.assertIn("@Generable", planner)
        self.assertIn("SystemLanguageModel.default", planner)
        self.assertIn("EKEventStore", personal)
        self.assertIn("CNContactStore", personal)
        self.assertIn("jarvis-foundation-planner", bootstrap)
        self.assertIn("jarvis-personal-data", bootstrap)


if __name__ == "__main__":
    unittest.main()
