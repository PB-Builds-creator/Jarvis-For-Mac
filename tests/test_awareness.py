from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from jarvis.awareness import (
    awareness_status,
    clear_conversation_history,
    handoff_context,
    local_awareness_context,
    prepare_handoff,
    record_conversation,
    relevant_conversations,
    update_handoff,
)
from jarvis.memory import search_memories


class AwarenessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.db_patch = patch(
            "jarvis.memory.DB_PATH",
            Path(self.temporary_directory.name) / "jarvis.db",
        )
        self.db_patch.start()
        self.addCleanup(self.db_patch.stop)
        self.addCleanup(self.temporary_directory.cleanup)

    def test_natural_strategy_query_recalls_saved_process(self) -> None:
        rows = search_memories(
            "What am I trying to accomplish with the gold scan?",
            include_private=False,
        )

        self.assertTrue(rows)
        self.assertTrue(
            any("MGC" in row["body"] or "Trading" in row["title"] for row in rows)
        )

    def test_recent_local_dialogue_is_available_to_followups(self) -> None:
        record_conversation(
            "What was the invalidation?",
            "Acceptance back above the saved range.",
            source="voice",
        )

        context = local_awareness_context("What about if DXY rejects?")

        self.assertIn("Recent local dialogue", context)
        self.assertIn("What was the invalidation?", context)
        self.assertIn("Acceptance back above", context)

    def test_earlier_dialogue_is_searchable_and_can_be_cleared(self) -> None:
        for index in range(15):
            record_conversation(
                f"Routine discussion {index}",
                "Ordinary continuity.",
            )
        record_conversation(
            "Remember the DXY rejection at the New York range?",
            "Yes, it was opposing evidence for the MGC continuation.",
        )
        for index in range(15, 30):
            record_conversation(
                f"Routine discussion {index}",
                "Ordinary continuity.",
            )

        rows = relevant_conversations("DXY rejection New York range")
        self.assertTrue(any("DXY rejection" in row["user_text"] for row in rows))
        self.assertIn("Relevant earlier dialogue", local_awareness_context(
            "What did we say about that DXY rejection?"
        ))
        removed = clear_conversation_history()
        self.assertGreater(removed, 0)
        self.assertEqual(awareness_status()["short_term_conversation_turns"], 0)

    def test_handoff_tracks_goal_purpose_expected_result_and_status(self) -> None:
        intent = prepare_handoff(
            "Scan my 5 minute MGC and DXY chart with my strategy.",
            active_app="TradingView",
            destination="work",
            model="gpt-5.6-sol",
        )
        context = handoff_context(intent, active_app="TradingView")
        update_handoff(
            intent.correlation_id,
            status="submitted",
            thread_id="thread-123",
            review_id="review-123",
        )
        status = awareness_status()

        self.assertIn("JARVIS INTENT AND CONTINUITY", context)
        self.assertIn("Why Jarvis is using ChatGPT", context)
        self.assertIn("Expected deliverable", context)
        self.assertIn("Asia-session MGC", context)
        self.assertEqual(status["latest_intent"]["status"], "submitted")
        self.assertTrue(status["strategy_memory_ready"])
        self.assertTrue(status["deep_conversation_enabled"])
        self.assertEqual(status["conversation_retention_turns"], 500)
