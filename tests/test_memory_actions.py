import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from jarvis.actions import approve_action, classify_risk, execute_action, queue_action
from jarvis.memory import add_memory, connect, export_memory, import_memory, search_memories


class MemoryActionTests(unittest.TestCase):
    def test_migrates_v05_memory_database(self):
        with tempfile.TemporaryDirectory() as td:
            database_path = Path(td) / "jarvis.db"
            old = sqlite3.connect(database_path)
            old.execute(
                """
                CREATE TABLE memories (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    category TEXT NOT NULL,
                    memory_key TEXT NOT NULL,
                    value TEXT NOT NULL,
                    source TEXT NOT NULL DEFAULT 'user',
                    confidence REAL NOT NULL DEFAULT 1.0,
                    active INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(category, memory_key)
                )
                """
            )
            old.execute(
                "INSERT INTO memories(category, memory_key, value, created_at, updated_at) "
                "VALUES ('trading', 'Asia session', 'Wait for confirmation.', 'old', 'old')"
            )
            old.commit()
            old.close()

            with patch("jarvis.memory.DB_PATH", database_path):
                upgraded = connect()
                memory = upgraded.execute(
                    "SELECT category, title, body FROM memories WHERE title = 'Asia session'"
                ).fetchone()
                backup_count = upgraded.execute(
                    "SELECT COUNT(*) FROM memories_legacy_v050"
                ).fetchone()[0]
                upgraded.close()

            self.assertEqual(dict(memory), {
                "category": "trading",
                "title": "Asia session",
                "body": "Wait for confirmation.",
            })
            self.assertEqual(backup_count, 1)

    def test_seed_memory_search(self):
        rows = search_memories("MacBook", limit=5)
        self.assertTrue(any("MacBook" in row["body"] for row in rows))

    def test_search_ranks_partial_keyword_matches(self):
        rows = search_memories("trading Jarvis MacBook", limit=10)
        self.assertTrue(rows)
        self.assertTrue(any("trading" in row["body"].lower() for row in rows))

    def test_add_export_import_memory(self):
        add_memory("test", "Unit test memory", "Jarvis remembers test content.")
        out = export_memory()
        self.assertTrue(out.exists())
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "mem.json"
            path.write_text(json.dumps({"memories": [{"category": "import", "title": "Imported", "body": "Imported body"}]}))
            count = import_memory(path)
        self.assertGreaterEqual(count, 0)

    def test_risk_classification_blocks_financial_actions(self):
        self.assertEqual(classify_risk("financial_action", {}), "blocked")
        self.assertEqual(classify_risk("open_url", {"url": "https://chatgpt.com"}), "low")

    @patch("subprocess.run")
    def test_queue_approve_execute_open_url(self, run):
        run.return_value.returncode = 0
        action_id = queue_action("open_url", {"url": "https://chatgpt.com"}, "test")
        self.assertTrue(approve_action(action_id))
        result = execute_action(action_id)
        self.assertIn("Opened URL", result)


if __name__ == "__main__":
    unittest.main()
