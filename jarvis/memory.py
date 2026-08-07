from __future__ import annotations

import json
import re
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from .config import DB_PATH, PRIVATE_FILE_MODE, ensure_dirs


MEMORY_KINDS = {
    "fact",
    "preference",
    "person",
    "project",
    "episode",
    "commitment",
    "procedure",
    "correction",
}
MEMORY_SCOPES = {"global", "personal", "project", "session"}
MEMORY_PRIVACY = {"local", "shareable", "private"}

SCHEMA = """
CREATE TABLE IF NOT EXISTS memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    category TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    confidence TEXT NOT NULL DEFAULT 'user_confirmed',
    kind TEXT NOT NULL DEFAULT 'fact',
    confidence_score REAL NOT NULL DEFAULT 1.0,
    source TEXT NOT NULL DEFAULT 'user',
    scope TEXT NOT NULL DEFAULT 'global',
    privacy TEXT NOT NULL DEFAULT 'local',
    valid_from TEXT,
    valid_to TEXT,
    expires_at TEXT,
    last_verified_at TEXT,
    supersedes_id INTEGER REFERENCES memories(id),
    active INTEGER NOT NULL DEFAULT 1,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS action_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action_type TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    risk_level TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    reason TEXT NOT NULL DEFAULT '',
    idempotency_key TEXT NOT NULL DEFAULT '',
    plan_id TEXT NOT NULL DEFAULT '',
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 1,
    preconditions_json TEXT NOT NULL DEFAULT '[]',
    postconditions_json TEXT NOT NULL DEFAULT '[]',
    checkpoint_json TEXT NOT NULL DEFAULT '[]',
    undo_json TEXT NOT NULL DEFAULT '[]',
    result TEXT NOT NULL DEFAULT '',
    error TEXT NOT NULL DEFAULT '',
    started_at TEXT,
    completed_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS timeline (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT NOT NULL,
    summary TEXT NOT NULL,
    details_json TEXT NOT NULL DEFAULT '{}',
    source TEXT NOT NULL DEFAULT 'jarvis',
    privacy TEXT NOT NULL DEFAULT 'local',
    correlation_id TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS routines (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    enabled INTEGER NOT NULL DEFAULT 1,
    current_version INTEGER NOT NULL DEFAULT 1,
    requires_confirmation INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS routine_versions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    routine_id INTEGER NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
    version INTEGER NOT NULL,
    parameters_json TEXT NOT NULL DEFAULT '{}',
    steps_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(routine_id, version)
);

CREATE TABLE IF NOT EXISTS proactive_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE,
    trigger_type TEXT NOT NULL,
    trigger_json TEXT NOT NULL DEFAULT '{}',
    routine_name TEXT NOT NULL DEFAULT '',
    notification_text TEXT NOT NULL DEFAULT '',
    risk_policy TEXT NOT NULL DEFAULT 'notify',
    enabled INTEGER NOT NULL DEFAULT 1,
    quiet_hours_exempt INTEGER NOT NULL DEFAULT 0,
    cooldown_seconds INTEGER NOT NULL DEFAULT 3600,
    last_fired_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS action_receipts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    receipt_id TEXT NOT NULL UNIQUE,
    plan_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    status TEXT NOT NULL,
    request_text TEXT NOT NULL DEFAULT '',
    steps_json TEXT NOT NULL DEFAULT '[]',
    result_json TEXT NOT NULL DEFAULT '{}',
    reversible_json TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL,
    completed_at TEXT
);

CREATE TABLE IF NOT EXISTS vocabulary (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    phrase TEXT NOT NULL COLLATE NOCASE UNIQUE,
    replacement TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT 'general',
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS project_documents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    root TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    language TEXT NOT NULL DEFAULT '',
    content_hash TEXT NOT NULL,
    symbols TEXT NOT NULL DEFAULT '',
    excerpt TEXT NOT NULL DEFAULT '',
    modified_at REAL NOT NULL DEFAULT 0,
    indexed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS trading_journal (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    review_id TEXT NOT NULL UNIQUE,
    symbol TEXT NOT NULL DEFAULT 'MGC+DXY',
    timeframes_json TEXT NOT NULL DEFAULT '[5,15,60,240]',
    screenshots_json TEXT NOT NULL DEFAULT '[]',
    analysis TEXT NOT NULL DEFAULT '',
    bias TEXT NOT NULL DEFAULT '',
    key_levels TEXT NOT NULL DEFAULT '',
    invalidation TEXT NOT NULL DEFAULT '',
    outcome TEXT NOT NULL DEFAULT '',
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS conversation_turns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_text TEXT NOT NULL,
    assistant_text TEXT NOT NULL DEFAULT '',
    turn_kind TEXT NOT NULL DEFAULT 'conversation',
    source TEXT NOT NULL DEFAULT 'jarvis',
    privacy TEXT NOT NULL DEFAULT 'local',
    correlation_id TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS intent_ledger (
    correlation_id TEXT PRIMARY KEY,
    user_request TEXT NOT NULL,
    inferred_goal TEXT NOT NULL,
    purpose TEXT NOT NULL,
    destination TEXT NOT NULL DEFAULT 'local',
    model TEXT NOT NULL DEFAULT '',
    expected_result TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'prepared',
    thread_id TEXT NOT NULL DEFAULT '',
    review_id TEXT NOT NULL DEFAULT '',
    result_summary TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_timeline_created
ON timeline(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_conversation_turns_created
ON conversation_turns(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_intent_ledger_updated
ON intent_ledger(updated_at DESC);
"""

SEED_MEMORIES = [
    (
        "hardware",
        "Resource policy",
        "Preserve Apple-silicon MacBook responsiveness while browsers, communication tools, and normal applications remain open. Load larger local models only on demand and retain reclaimable-memory headroom.",
        "procedure",
    ),
    (
        "architecture",
        "No-API Jarvis architecture",
        "Use deterministic commands first, Apple's on-device model when available, Qwen 4B and 9B only on demand, and persistent ChatGPT desktop tasks for deep work without an API key.",
        "procedure",
    ),
    (
        "safety",
        "Trading safety rule",
        "Jarvis may analyze charts and prepare decision support, but must never place, modify, or close live financial trades.",
        "preference",
    ),
    (
        "audio",
        "Preferred microphone",
        "Prefer the connected Razer Seiren V3 Mini for Jarvis and Siri input without changing output devices. Fall back safely when it is unplugged.",
        "preference",
    ),
    (
        "mission",
        "Jarvis operating purpose",
        "Jarvis helps the owner turn an intended outcome into a verified result. It should understand the goal, use relevant memory and current evidence, handle safe deterministic Mac control locally, and use ChatGPT only when deeper reasoning, visual interpretation, research, or implementation is genuinely useful.",
        "procedure",
    ),
    (
        "mission",
        "Purpose of ChatGPT handoffs",
        "Sending something to ChatGPT is a reasoning handoff, not the final action. Jarvis should explain why the handoff is useful, include the current objective, relevant strategy and evidence, define the expected deliverable, preserve continuity with the prior task, and keep consequential Mac actions behind Jarvis confirmation.",
        "procedure",
    ),
    (
        "strategy",
        "Asia-session MGC decision process",
        "Use the completed New York range, saved Fibonacci levels, fair value gaps, DXY acceptance or rejection, higher-timeframe structure, invalidation, uncertainty, and later outcome review as a hand-reviewed MGC research process rather than an automatic trading signal.",
        "procedure",
    ),
]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {
        str(row["name"])
        for row in conn.execute(f"PRAGMA table_info({table})")
    }


def migrate_legacy_memories(conn: sqlite3.Connection) -> None:
    """Upgrade the v0.5 key/value layout without discarding original records."""
    columns = _table_columns(conn, "memories")
    if not columns or {"title", "body"}.issubset(columns):
        return
    legacy_columns = {"category", "memory_key", "value"}
    if not legacy_columns.issubset(columns):
        raise RuntimeError(
            "Jarvis found an unsupported memory database layout. "
            "The database was left unchanged."
        )
    backup_table = "memories_legacy_v050"
    suffix = 1
    while _table_columns(conn, backup_table):
        backup_table = f"memories_legacy_v050_{suffix}"
        suffix += 1
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute(f"ALTER TABLE memories RENAME TO {backup_table}")
        conn.execute(
            """
            CREATE TABLE memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                category TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                confidence TEXT NOT NULL DEFAULT 'user_confirmed',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        active_filter = "WHERE active != 0" if "active" in columns else ""
        source_expr = (
            "CASE WHEN source = 'user' THEN 'user_confirmed' "
            "ELSE COALESCE(NULLIF(source, ''), 'imported') END"
            if "source" in columns
            else "'imported'"
        )
        now = utc_now()
        created_expr = "COALESCE(created_at, ?)" if "created_at" in columns else "?"
        updated_expr = "COALESCE(updated_at, ?)" if "updated_at" in columns else "?"
        conn.execute(
            f"""
            INSERT INTO memories(category, title, body, confidence, created_at, updated_at)
            SELECT category, memory_key, value, {source_expr},
                   {created_expr}, {updated_expr}
            FROM {backup_table}
            {active_filter}
            """,
            (now, now),
        )
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def _add_missing_columns(
    conn: sqlite3.Connection,
    table: str,
    definitions: dict[str, str],
) -> None:
    existing = _table_columns(conn, table)
    for name, definition in definitions.items():
        if name not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {definition}")


def migrate_v2(conn: sqlite3.Connection) -> None:
    """Add v2 fields and full-text search in-place; safe to run every startup."""
    _add_missing_columns(
        conn,
        "memories",
        {
            "kind": "TEXT NOT NULL DEFAULT 'fact'",
            "confidence_score": "REAL NOT NULL DEFAULT 1.0",
            "source": "TEXT NOT NULL DEFAULT 'user'",
            "scope": "TEXT NOT NULL DEFAULT 'global'",
            "privacy": "TEXT NOT NULL DEFAULT 'local'",
            "valid_from": "TEXT",
            "valid_to": "TEXT",
            "expires_at": "TEXT",
            "last_verified_at": "TEXT",
            "supersedes_id": "INTEGER REFERENCES memories(id)",
            "active": "INTEGER NOT NULL DEFAULT 1",
            "metadata_json": "TEXT NOT NULL DEFAULT '{}'",
        },
    )
    _add_missing_columns(
        conn,
        "action_queue",
        {
            "idempotency_key": "TEXT NOT NULL DEFAULT ''",
            "plan_id": "TEXT NOT NULL DEFAULT ''",
            "attempts": "INTEGER NOT NULL DEFAULT 0",
            "max_attempts": "INTEGER NOT NULL DEFAULT 1",
            "preconditions_json": "TEXT NOT NULL DEFAULT '[]'",
            "postconditions_json": "TEXT NOT NULL DEFAULT '[]'",
            "checkpoint_json": "TEXT NOT NULL DEFAULT '[]'",
            "undo_json": "TEXT NOT NULL DEFAULT '[]'",
            "result": "TEXT NOT NULL DEFAULT ''",
            "error": "TEXT NOT NULL DEFAULT ''",
            "started_at": "TEXT",
            "completed_at": "TEXT",
        },
    )
    conn.executescript(
        """
        CREATE INDEX IF NOT EXISTS idx_memories_active_updated
        ON memories(active, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_memories_kind_scope
        ON memories(kind, scope, active);
        CREATE INDEX IF NOT EXISTS idx_actions_idempotency
        ON action_queue(idempotency_key, status);
        """
    )
    try:
        conn.executescript(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
                title, body, category, kind,
                content='memories',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS memories_fts_insert AFTER INSERT ON memories BEGIN
                INSERT INTO memories_fts(rowid, title, body, category, kind)
                VALUES (new.id, new.title, new.body, new.category, new.kind);
            END;
            CREATE TRIGGER IF NOT EXISTS memories_fts_delete AFTER DELETE ON memories BEGIN
                INSERT INTO memories_fts(memories_fts, rowid, title, body, category, kind)
                VALUES ('delete', old.id, old.title, old.body, old.category, old.kind);
            END;
            CREATE TRIGGER IF NOT EXISTS memories_fts_update AFTER UPDATE ON memories BEGIN
                INSERT INTO memories_fts(memories_fts, rowid, title, body, category, kind)
                VALUES ('delete', old.id, old.title, old.body, old.category, old.kind);
                INSERT INTO memories_fts(rowid, title, body, category, kind)
                VALUES (new.id, new.title, new.body, new.category, new.kind);
            END;
            """
        )
        schema_version = int(
            conn.execute("PRAGMA user_version").fetchone()[0]
        )
        if schema_version < 2:
            conn.execute("INSERT INTO memories_fts(memories_fts) VALUES('rebuild')")
            conn.execute("PRAGMA user_version=2")
    except sqlite3.OperationalError:
        # Some custom SQLite builds omit FTS5. LIKE search remains available.
        pass
    conn.commit()


def migrate_v3(conn: sqlite3.Connection) -> None:
    """Add searchable local conversation continuity without storing audio."""
    try:
        conn.executescript(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS conversation_turns_fts USING fts5(
                user_text, assistant_text, turn_kind, source,
                content='conversation_turns',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS conversation_fts_insert
            AFTER INSERT ON conversation_turns BEGIN
                INSERT INTO conversation_turns_fts(
                    rowid, user_text, assistant_text, turn_kind, source
                ) VALUES (
                    new.id, new.user_text, new.assistant_text,
                    new.turn_kind, new.source
                );
            END;
            CREATE TRIGGER IF NOT EXISTS conversation_fts_delete
            AFTER DELETE ON conversation_turns BEGIN
                INSERT INTO conversation_turns_fts(
                    conversation_turns_fts, rowid, user_text,
                    assistant_text, turn_kind, source
                ) VALUES (
                    'delete', old.id, old.user_text, old.assistant_text,
                    old.turn_kind, old.source
                );
            END;
            """
        )
        schema_version = int(conn.execute("PRAGMA user_version").fetchone()[0])
        if schema_version < 3:
            conn.execute(
                "INSERT INTO conversation_turns_fts(conversation_turns_fts) "
                "VALUES('rebuild')"
            )
            conn.execute("PRAGMA user_version=3")
    except sqlite3.OperationalError:
        # LIKE-based recall remains available on SQLite builds without FTS5.
        pass
    conn.commit()


def connect() -> sqlite3.Connection:
    ensure_dirs()
    conn = sqlite3.connect(DB_PATH, timeout=10)
    DB_PATH.chmod(PRIVATE_FILE_MODE)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    migrate_legacy_memories(conn)
    conn.executescript(SCHEMA)
    migrate_v2(conn)
    migrate_v3(conn)
    seed(conn)
    return conn


@contextmanager
def database():
    conn = connect()
    try:
        yield conn
    finally:
        conn.close()


def seed(conn: sqlite3.Connection) -> None:
    now = utc_now()
    for category, title, body, kind in SEED_MEMORIES:
        exists = conn.execute(
            "SELECT 1 FROM memories WHERE category = ? AND title = ? AND active = 1",
            (category, title),
        ).fetchone()
        if not exists:
            conn.execute(
                """
                INSERT INTO memories(
                    category, title, body, confidence, kind, source, scope,
                    privacy, last_verified_at, created_at, updated_at
                ) VALUES (?, ?, ?, 'user_confirmed', ?, 'system_seed',
                          'global', 'local', ?, ?, ?)
                """,
                (category, title, body, kind, now, now, now),
            )
    # A legacy test harness wrote one fixed fixture into the live database.
    # Remove only that exact fixture; never pattern-delete normal user memory.
    conn.execute(
        "DELETE FROM memories WHERE category = 'test' "
        "AND title = 'Unit test memory' "
        "AND body = 'Jarvis remembers test content.'"
    )
    conn.execute(
        "DELETE FROM memories WHERE category = 'import' "
        "AND title = 'Imported' AND body = 'Imported body'"
    )
    conn.commit()


def _choice(value: str, allowed: set[str], fallback: str) -> str:
    cleaned = value.strip().casefold()
    return cleaned if cleaned in allowed else fallback


def add_memory(
    category: str,
    title: str,
    body: str,
    confidence: str = "user_confirmed",
    *,
    kind: str = "fact",
    confidence_score: float = 1.0,
    source: str = "user",
    scope: str = "global",
    privacy: str = "local",
    valid_from: str | None = None,
    valid_to: str | None = None,
    expires_at: str | None = None,
    last_verified_at: str | None = None,
    supersedes_id: int | None = None,
    metadata: dict[str, Any] | None = None,
) -> int:
    clean_body = body.strip()
    if not clean_body:
        raise ValueError("Memory text cannot be empty.")
    clean_title = title.strip() or clean_body[:80]
    now = utc_now()
    with database() as conn:
        cur = conn.execute(
            """
            INSERT INTO memories(
                category, title, body, confidence, kind, confidence_score,
                source, scope, privacy, valid_from, valid_to, expires_at,
                last_verified_at, supersedes_id, active, metadata_json,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
            """,
            (
                category.strip() or "note",
                clean_title,
                clean_body,
                confidence.strip() or "user_confirmed",
                _choice(kind, MEMORY_KINDS, "fact"),
                max(0.0, min(float(confidence_score), 1.0)),
                source.strip() or "user",
                _choice(scope, MEMORY_SCOPES, "global"),
                _choice(privacy, MEMORY_PRIVACY, "local"),
                valid_from,
                valid_to,
                expires_at,
                last_verified_at or now,
                supersedes_id,
                json.dumps(metadata or {}, sort_keys=True),
                now,
                now,
            ),
        )
        if supersedes_id is not None:
            conn.execute(
                "UPDATE memories SET active = 0, valid_to = COALESCE(valid_to, ?), "
                "updated_at = ? WHERE id = ?",
                (now, now, supersedes_id),
            )
        conn.commit()
        memory_id = int(cur.lastrowid)
    record_timeline(
        "memory_added",
        f"Remembered {clean_title}",
        {"memory_id": memory_id, "kind": kind, "scope": scope},
        privacy=privacy,
    )
    return memory_id


def get_memory(memory_id: int, *, include_inactive: bool = False) -> dict[str, Any] | None:
    with database() as conn:
        query = "SELECT * FROM memories WHERE id = ?"
        if not include_inactive:
            query += " AND active = 1"
        row = conn.execute(query, (memory_id,)).fetchone()
    return dict(row) if row else None


def correct_memory(
    memory_id: int,
    body: str,
    *,
    title: str | None = None,
    reason: str = "",
) -> int:
    previous = get_memory(memory_id)
    if previous is None:
        raise ValueError("Active memory not found.")
    metadata = {"correction_reason": reason.strip()} if reason.strip() else {}
    return add_memory(
        str(previous["category"]),
        title or str(previous["title"]),
        body,
        "user_confirmed",
        kind="correction",
        confidence_score=1.0,
        source="user_correction",
        scope=str(previous["scope"]),
        privacy=str(previous["privacy"]),
        supersedes_id=memory_id,
        metadata=metadata,
    )


def forget_memory(memory_id: int) -> bool:
    now = utc_now()
    with database() as conn:
        changed = conn.execute(
            "UPDATE memories SET active = 0, valid_to = COALESCE(valid_to, ?), "
            "updated_at = ? WHERE id = ? AND active = 1",
            (now, now, memory_id),
        ).rowcount
        conn.commit()
    if changed:
        record_timeline(
            "memory_forgotten",
            "Forgot a memory",
            {"memory_id": memory_id},
        )
    return bool(changed)


def _fts_query(query: str) -> str:
    tokens = re.findall(r"[\w@.+-]+", query, flags=re.UNICODE)
    # Natural requests contain incidental words. OR recall keeps relevant
    # strategy memories visible instead of requiring every token to match.
    return " OR ".join(f'"{token.replace(chr(34), "")}"*' for token in tokens[:12])


def search_memories(
    query: str = "",
    limit: int = 12,
    *,
    kind: str | None = None,
    scope: str | None = None,
    include_private: bool = True,
    include_inactive: bool = False,
) -> list[dict[str, Any]]:
    limit = max(1, min(int(limit), 100))
    filters = ["1=1"]
    parameters: list[Any] = []
    if not include_inactive:
        filters.append("m.active = 1")
    filters.append("(m.expires_at IS NULL OR m.expires_at > ?)")
    parameters.append(utc_now())
    if kind:
        filters.append("m.kind = ?")
        parameters.append(_choice(kind, MEMORY_KINDS, "fact"))
    if scope:
        filters.append("m.scope = ?")
        parameters.append(_choice(scope, MEMORY_SCOPES, "global"))
    if not include_private:
        filters.append("m.privacy != 'private'")
    where = " AND ".join(filters)
    with database() as conn:
        if query.strip():
            fts = _fts_query(query)
            if fts:
                try:
                    rows = conn.execute(
                        f"""
                        SELECT m.*, bm25(memories_fts, 4.0, 1.0, 0.5, 0.25) AS rank
                        FROM memories_fts
                        JOIN memories m ON m.id = memories_fts.rowid
                        WHERE memories_fts MATCH ? AND {where}
                        ORDER BY rank, m.confidence_score DESC, m.updated_at DESC
                        LIMIT ?
                        """,
                        [fts, *parameters, limit],
                    ).fetchall()
                    return [dict(row) for row in rows]
                except sqlite3.OperationalError:
                    pass
            lowered_terms = [part.casefold() for part in query.split() if part.strip()]
            rows = conn.execute(
                f"SELECT m.* FROM memories m WHERE {where} "
                "ORDER BY m.updated_at DESC, m.id DESC",
                parameters,
            ).fetchall()
            ranked: list[tuple[int, sqlite3.Row]] = []
            for row in rows:
                text = f"{row['category']} {row['title']} {row['body']} {row['kind']}".casefold()
                score = sum(term in text for term in lowered_terms)
                if score:
                    ranked.append((score, row))
            ranked.sort(
                key=lambda item: (item[0], float(item[1]["confidence_score"])),
                reverse=True,
            )
            return [dict(row) for _, row in ranked[:limit]]
        rows = conn.execute(
            f"SELECT m.* FROM memories m WHERE {where} "
            "ORDER BY m.updated_at DESC, m.id DESC LIMIT ?",
            [*parameters, limit],
        ).fetchall()
    return [dict(row) for row in rows]


def consolidate_memories() -> dict[str, int]:
    """Deactivate exact duplicates and expired session memories."""
    now = utc_now()
    deactivated = 0
    expired = 0
    with database() as conn:
        rows = conn.execute(
            "SELECT id, category, title, body, scope, privacy, expires_at "
            "FROM memories WHERE active = 1 ORDER BY id DESC"
        ).fetchall()
        seen: set[tuple[str, ...]] = set()
        for row in rows:
            key = tuple(
                str(row[name]).strip().casefold()
                for name in ("category", "title", "body", "scope", "privacy")
            )
            if row["expires_at"] and str(row["expires_at"]) <= now:
                conn.execute(
                    "UPDATE memories SET active = 0, updated_at = ? WHERE id = ?",
                    (now, row["id"]),
                )
                expired += 1
            elif key in seen:
                conn.execute(
                    "UPDATE memories SET active = 0, updated_at = ? WHERE id = ?",
                    (now, row["id"]),
                )
                deactivated += 1
            else:
                seen.add(key)
        conn.commit()
    result = {"duplicates": deactivated, "expired": expired}
    record_timeline("memory_consolidated", "Consolidated memory", result)
    return result


def record_timeline(
    event_type: str,
    summary: str,
    details: dict[str, Any] | None = None,
    *,
    source: str = "jarvis",
    privacy: str = "local",
    correlation_id: str = "",
) -> int:
    with database() as conn:
        cur = conn.execute(
            """
            INSERT INTO timeline(
                event_type, summary, details_json, source, privacy,
                correlation_id, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                event_type.strip()[:80] or "event",
                summary.strip()[:500],
                json.dumps(details or {}, sort_keys=True, default=str),
                source.strip()[:80] or "jarvis",
                _choice(privacy, MEMORY_PRIVACY, "local"),
                correlation_id.strip()[:128],
                utc_now(),
            ),
        )
        conn.commit()
        return int(cur.lastrowid)


def list_timeline(
    limit: int = 100,
    *,
    event_type: str | None = None,
    include_private: bool = True,
) -> list[dict[str, Any]]:
    conditions = ["1=1"]
    parameters: list[Any] = []
    if event_type:
        conditions.append("event_type = ?")
        parameters.append(event_type)
    if not include_private:
        conditions.append("privacy != 'private'")
    with database() as conn:
        rows = conn.execute(
            f"SELECT * FROM timeline WHERE {' AND '.join(conditions)} "
            "ORDER BY id DESC LIMIT ?",
            [*parameters, max(1, min(int(limit), 500))],
        ).fetchall()
    return [dict(row) for row in rows]


def memory_stats() -> dict[str, Any]:
    with database() as conn:
        active = conn.execute(
            "SELECT COUNT(*) FROM memories WHERE active = 1"
        ).fetchone()[0]
        private = conn.execute(
            "SELECT COUNT(*) FROM memories WHERE active = 1 AND privacy = 'private'"
        ).fetchone()[0]
        by_kind = {
            str(row["kind"]): int(row["count"])
            for row in conn.execute(
                "SELECT kind, COUNT(*) AS count FROM memories "
                "WHERE active = 1 GROUP BY kind"
            )
        }
    return {"active": int(active), "private": int(private), "by_kind": by_kind}


def export_memory(path: Path | None = None) -> Path:
    from .config import EXPORT_DIR

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out = path or (EXPORT_DIR / f"jarvis_memory_export_{timestamp}.json")
    with database() as conn:
        memories = [
            dict(row)
            for row in conn.execute("SELECT * FROM memories ORDER BY id").fetchall()
        ]
        actions = [
            dict(row)
            for row in conn.execute("SELECT * FROM action_queue ORDER BY id").fetchall()
        ]
        vocabulary = [
            dict(row)
            for row in conn.execute("SELECT * FROM vocabulary ORDER BY id").fetchall()
        ]
        routines = [
            dict(row)
            for row in conn.execute("SELECT * FROM routines ORDER BY id").fetchall()
        ]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(
            {
                "format": "jarvis-memory-export-v2",
                "exported_at": utc_now(),
                "memories": memories,
                "action_queue": actions,
                "vocabulary": vocabulary,
                "routines": routines,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    out.chmod(PRIVATE_FILE_MODE)
    return out


def import_memory(path: Path) -> int:
    raw = json.loads(path.read_text(encoding="utf-8"))
    items: Iterable[dict[str, Any]] = (
        raw.get("memories", []) if isinstance(raw, dict) else []
    )
    count = 0
    for item in items:
        category = str(item.get("category", "imported")).strip()
        title = str(item.get("title", "Untitled")).strip()
        body = str(item.get("body", "")).strip()
        if not body:
            continue
        with database() as conn:
            existing = conn.execute(
                "SELECT id FROM memories WHERE category = ? AND title = ? "
                "AND body = ? AND active = 1",
                (category, title, body),
            ).fetchone()
        if existing:
            continue
        add_memory(
            category,
            title,
            body,
            str(item.get("confidence", "imported")),
            kind=str(item.get("kind", "fact")),
            confidence_score=float(item.get("confidence_score", 0.7)),
            source=str(item.get("source", "import")),
            scope=str(item.get("scope", "global")),
            privacy=str(item.get("privacy", "local")),
            valid_from=item.get("valid_from"),
            valid_to=item.get("valid_to"),
            expires_at=item.get("expires_at"),
            metadata=(
                json.loads(str(item.get("metadata_json", "{}")))
                if item.get("metadata_json")
                else {}
            ),
        )
        count += 1
    return count
