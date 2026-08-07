from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from typing import Any

from .config import load_config, safe_owner_name
from .memory import database, record_timeline, search_memories, utc_now


TRADING_TERMS = re.compile(
    r"\b(?:tradingview|trading view|mgc|gold|dxy|chart|market|trade|"
    r"fibonacci|fib|fair value gap|fvg|new york range|asia session)\b",
    re.IGNORECASE,
)
WORK_TERMS = re.compile(
    r"\b(?:build|code|debug|fix|implement|install|project|repository|"
    r"refactor|test|update)\b",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class IntentAwareness:
    correlation_id: str
    user_request: str
    inferred_goal: str
    purpose: str
    destination: str
    model: str
    expected_result: str


def _clean(value: object, limit: int) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())[:limit]


def _is_trading_context(task: str, active_app: str = "") -> bool:
    return active_app.strip().casefold() == "tradingview" or bool(
        TRADING_TERMS.search(task)
    )


def infer_goal(task: str, *, active_app: str = "") -> str:
    cleaned = _clean(task, 1_500)
    owner = safe_owner_name(load_config().owner_name)
    owner_possessive = owner + ("'" if owner.casefold().endswith("s") else "'s")
    if _is_trading_context(cleaned, active_app):
        return (
            f"Help {owner} make a disciplined, evidence-based MGC decision using "
            f"{owner_possessive} saved Asia-session process, while exposing uncertainty and "
            "never executing a trade."
        )
    if WORK_TERMS.search(cleaned):
        return (
            f"Turn {owner_possessive} requested change into a verified working result while "
            "preserving existing behavior and unrelated files."
        )
    if active_app:
        return (
            f"Understand the relevant evidence in {active_app} and give {owner} "
            "a useful, concrete next step."
        )
    return (
        f"Understand what {owner} is trying to accomplish, answer in context, and "
        "move the objective forward without inventing actions or results."
    )


def handoff_purpose(
    task: str,
    *,
    active_app: str,
    destination: str,
) -> str:
    if _is_trading_context(task, active_app):
        return (
            "ChatGPT is being used for visual multi-factor reasoning across chart "
            "evidence and saved strategy. Jarvis gathered the screenshots, memory, "
            "and safety constraints; ChatGPT should return decision support, not "
            "control the Mac or execute a trade."
        )
    if destination == "work":
        return (
            "ChatGPT Work is being used because this request benefits from deeper "
            "reasoning, workspace inspection, implementation, or verification. "
            "Jarvis remains responsible for local context and confirmation-gated "
            "Mac actions."
        )
    return (
        "ChatGPT is being used for richer reasoning or visual interpretation than "
        "the local command planner should attempt. The response should help the owner "
        "decide or understand; any consequential action returns to Jarvis for "
        "separate review."
    )


def expected_result(task: str, *, active_app: str, destination: str) -> str:
    if _is_trading_context(task, active_app):
        return (
            "A concise bias with supporting and opposing evidence, key levels, "
            "invalidation, missing context, and the review ID for later outcome "
            "journaling."
        )
    if destination == "work":
        return (
            "A completed, tested result with exact verification evidence and any "
            "remaining user-only action stated plainly."
        )
    return (
        "A context-aware answer that distinguishes observations, interpretation, "
        "and the most useful next step."
    )


def _memory_lines(
    task: str,
    *,
    active_app: str = "",
    limit: int = 12,
) -> list[str]:
    query = (
        task
        + " "
        + active_app
        + " goal purpose strategy workflow safety preference"
    )
    rows = search_memories(query, limit=limit, include_private=False)
    if _is_trading_context(task, active_app):
        strategy_rows = search_memories(
            "MGC gold DXY Asia New York range Fibonacci fair value gap "
            "invalidation journal strategy",
            limit=12,
            include_private=False,
        )
        seen = {int(row["id"]) for row in rows}
        rows.extend(row for row in strategy_rows if int(row["id"]) not in seen)
    priority = {
        "mission": 0,
        "goal": 1,
        "strategy": 2,
        "routine": 3,
        "safety": 4,
        "preference": 5,
    }
    rows.sort(
        key=lambda row: (
            priority.get(str(row["category"]).casefold(), 10),
            -float(row.get("confidence_score", 1.0)),
            -int(row["id"]),
        )
    )
    return [
        f"- [{row['category']}] {row['title']}: {_clean(row['body'], 700)}"
        for row in rows[:limit]
    ]


def record_conversation(
    user_text: str,
    assistant_text: str,
    *,
    turn_kind: str = "conversation",
    source: str = "jarvis",
    correlation_id: str = "",
) -> int:
    user = _clean(user_text, 4_000)
    assistant = _clean(assistant_text, 4_000)
    if not user and not assistant:
        raise ValueError("A conversation turn cannot be empty.")
    with database() as conn:
        cursor = conn.execute(
            """
            INSERT INTO conversation_turns(
                user_text, assistant_text, turn_kind, source, privacy,
                correlation_id, created_at
            ) VALUES (?, ?, ?, ?, 'local', ?, ?)
            """,
            (
                user,
                assistant,
                _clean(turn_kind, 40) or "conversation",
                _clean(source, 80) or "jarvis",
                _clean(correlation_id, 128),
                utc_now(),
            ),
        )
        cfg = load_config()
        # Conversation continuity is bounded, local, text-only operational
        # memory. It stays searchable without keeping a model resident.
        conn.execute(
            "DELETE FROM conversation_turns WHERE id NOT IN "
            "(SELECT id FROM conversation_turns ORDER BY id DESC LIMIT ?)",
            (max(40, min(int(cfg.conversation_memory_turns), 2_000)),),
        )
        conn.commit()
        turn_id = int(cursor.lastrowid)
    record_timeline(
        "conversation_turn_recorded",
        "Recorded local conversation continuity",
        {"turn_id": turn_id, "kind": turn_kind},
        privacy="local",
        correlation_id=correlation_id,
    )
    return turn_id


def recent_conversations(limit: int = 6) -> list[dict[str, Any]]:
    with database() as conn:
        rows = conn.execute(
            "SELECT * FROM conversation_turns ORDER BY id DESC LIMIT ?",
            (max(1, min(int(limit), 40)),),
        ).fetchall()
    return [dict(row) for row in reversed(rows)]


def relevant_conversations(query: str, limit: int = 8) -> list[dict[str, Any]]:
    clean_query = _clean(query, 2_000)
    if not clean_query:
        return []
    bounded_limit = max(1, min(int(limit), 20))
    tokens = re.findall(r"[\w@.+-]+", clean_query, flags=re.UNICODE)[:12]
    fts = " OR ".join(f'"{token.replace(chr(34), "")}"*' for token in tokens)
    with database() as conn:
        if fts:
            try:
                rows = conn.execute(
                    """
                    SELECT c.*, bm25(conversation_turns_fts, 2.0, 1.0, 0.2, 0.1)
                        AS rank
                    FROM conversation_turns_fts
                    JOIN conversation_turns c
                        ON c.id = conversation_turns_fts.rowid
                    WHERE conversation_turns_fts MATCH ?
                    ORDER BY rank, c.id DESC
                    LIMIT ?
                    """,
                    (fts, bounded_limit),
                ).fetchall()
                return [dict(row) for row in rows]
            except Exception:
                pass
        lowered = [token.casefold() for token in tokens]
        rows = conn.execute(
            "SELECT * FROM conversation_turns ORDER BY id DESC LIMIT 500"
        ).fetchall()
    ranked: list[tuple[int, Any]] = []
    for row in rows:
        text = f"{row['user_text']} {row['assistant_text']}".casefold()
        score = sum(token in text for token in lowered)
        if score:
            ranked.append((score, row))
    ranked.sort(key=lambda value: (value[0], int(value[1]["id"])), reverse=True)
    return [dict(row) for _, row in ranked[:bounded_limit]]


def clear_conversation_history() -> int:
    with database() as conn:
        count = int(
            conn.execute("SELECT COUNT(*) FROM conversation_turns").fetchone()[0]
        )
        conn.execute("DELETE FROM conversation_turns")
        conn.commit()
    record_timeline(
        "conversation_history_cleared",
        "Cleared local conversational continuity",
        {"turns_removed": count},
    )
    return count


def recent_intents(limit: int = 4) -> list[dict[str, Any]]:
    with database() as conn:
        rows = conn.execute(
            "SELECT * FROM intent_ledger ORDER BY updated_at DESC LIMIT ?",
            (max(1, min(int(limit), 20)),),
        ).fetchall()
    return [dict(row) for row in rows]


def local_awareness_context(task: str, *, local_context: str = "") -> str:
    cfg = load_config()
    active_match = re.search(
        r"(?im)^Active app:\s*([^\r\n]{1,80})",
        local_context,
    )
    active_app = active_match.group(1).strip() if active_match else ""
    lines = [
        "JARVIS OPERATIONAL AWARENESS",
        f"Current objective: {infer_goal(task, active_app=active_app)}",
        (
            "Operating rule: build on relevant prior dialogue without repeating "
            "yourself. Resolve only clear continuations; ask when multiple "
            "referents fit. Separate known facts, inference, and uncertainty."
        ),
    ]
    if local_context.strip():
        lines.extend(["Current Mac observations:", local_context.strip()[:3_500]])
    turns = recent_conversations(cfg.conversation_context_turns)
    if turns:
        lines.append("Recent local dialogue:")
        for turn in turns:
            lines.append(f"- the owner: {_clean(turn['user_text'], 500)}")
            if turn["assistant_text"]:
                lines.append(f"  Jarvis: {_clean(turn['assistant_text'], 650)}")
    recent_ids = {int(turn["id"]) for turn in turns}
    relevant = [
        turn
        for turn in relevant_conversations(
            task,
            cfg.conversation_relevant_turns,
        )
        if int(turn["id"]) not in recent_ids
    ]
    if relevant:
        lines.append("Relevant earlier dialogue:")
        for turn in relevant:
            lines.append(f"- the owner: {_clean(turn['user_text'], 500)}")
            if turn["assistant_text"]:
                lines.append(f"  Jarvis: {_clean(turn['assistant_text'], 650)}")
    lines.extend(
        [
            "Relevant durable memory:",
            *_memory_lines(task, active_app=active_app, limit=12),
        ]
    )
    return "\n".join(lines)[:14_000]


def prepare_handoff(
    task: str,
    *,
    active_app: str,
    destination: str,
    model: str,
) -> IntentAwareness:
    intent = IntentAwareness(
        correlation_id=str(uuid.uuid4()),
        user_request=_clean(task, 4_000),
        inferred_goal=infer_goal(task, active_app=active_app),
        purpose=handoff_purpose(
            task,
            active_app=active_app,
            destination=destination,
        ),
        destination=_clean(destination, 20),
        model=_clean(model, 80),
        expected_result=expected_result(
            task,
            active_app=active_app,
            destination=destination,
        ),
    )
    now = utc_now()
    with database() as conn:
        conn.execute(
            """
            INSERT INTO intent_ledger(
                correlation_id, user_request, inferred_goal, purpose,
                destination, model, expected_result, status, created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'prepared', ?, ?)
            """,
            (
                intent.correlation_id,
                intent.user_request,
                intent.inferred_goal,
                intent.purpose,
                intent.destination,
                intent.model,
                intent.expected_result,
                now,
                now,
            ),
        )
        conn.execute(
            "DELETE FROM intent_ledger WHERE correlation_id NOT IN "
            "(SELECT correlation_id FROM intent_ledger "
            "ORDER BY updated_at DESC LIMIT 100)"
        )
        conn.commit()
    record_timeline(
        "intent_prepared",
        f"Prepared a reasoned {intent.destination} handoff",
        {
            "goal": intent.inferred_goal,
            "purpose": intent.purpose,
            "expected_result": intent.expected_result,
        },
        correlation_id=intent.correlation_id,
    )
    return intent


def update_handoff(
    correlation_id: str,
    *,
    status: str,
    thread_id: str = "",
    review_id: str = "",
    result_summary: str = "",
) -> None:
    clean_status = _clean(status, 40) or "unknown"
    with database() as conn:
        conn.execute(
            """
            UPDATE intent_ledger SET status = ?,
                thread_id = COALESCE(NULLIF(?, ''), thread_id),
                review_id = COALESCE(NULLIF(?, ''), review_id),
                result_summary = COALESCE(NULLIF(?, ''), result_summary),
                updated_at = ?
            WHERE correlation_id = ?
            """,
            (
                clean_status,
                _clean(thread_id, 128),
                _clean(review_id, 128),
                _clean(result_summary, 1_000),
                utc_now(),
                correlation_id,
            ),
        )
        conn.commit()
    record_timeline(
        "intent_status",
        f"Jarvis handoff is {clean_status}",
        {"thread_id": thread_id, "review_id": review_id},
        correlation_id=correlation_id,
    )


def handoff_context(
    intent: IntentAwareness,
    *,
    active_app: str,
) -> str:
    lines = [
        "JARVIS INTENT AND CONTINUITY",
        f"Correlation ID: {intent.correlation_id}",
        f"the owner's intended outcome: {intent.inferred_goal}",
        f"Why Jarvis is using ChatGPT: {intent.purpose}",
        f"Expected deliverable: {intent.expected_result}",
        (
            "Responsibility boundary: ChatGPT reasons from the supplied evidence. "
            "Jarvis handles local execution separately and never treats a proposal "
            "as a completed action."
        ),
        "Relevant durable memory:",
        *_memory_lines(intent.user_request, active_app=active_app, limit=12),
    ]
    prior = recent_intents(4)
    prior = [
        value
        for value in prior
        if value["correlation_id"] != intent.correlation_id
    ][:3]
    if prior:
        lines.append("Recent ChatGPT handoff continuity:")
        for value in prior:
            lines.append(
                "- "
                + _clean(value["user_request"], 350)
                + f" [{value['destination']}; {value['status']}]"
            )
    return "\n".join(lines)[:12_000]


def awareness_status() -> dict[str, Any]:
    cfg = load_config()
    with database() as conn:
        conversation_count = int(
            conn.execute("SELECT COUNT(*) FROM conversation_turns").fetchone()[0]
        )
        intent_count = int(
            conn.execute("SELECT COUNT(*) FROM intent_ledger").fetchone()[0]
        )
        latest = conn.execute(
            "SELECT inferred_goal, destination, status, updated_at "
            "FROM intent_ledger ORDER BY updated_at DESC LIMIT 1"
        ).fetchone()
        latest_turn = conn.execute(
            "SELECT user_text, assistant_text, created_at "
            "FROM conversation_turns ORDER BY id DESC LIMIT 1"
        ).fetchone()
        strategy_count = int(
            conn.execute(
                "SELECT COUNT(*) FROM memories "
                "WHERE active = 1 AND category = 'strategy'"
            ).fetchone()[0]
        )
    return {
        "enabled": True,
        "durable_memory": "SQLite FTS5",
        "short_term_conversation_turns": conversation_count,
        "tracked_intents": intent_count,
        "conversation_retention_turns": cfg.conversation_memory_turns,
        "intent_retention": 100,
        "latest_intent": dict(latest) if latest else None,
        "latest_conversation": dict(latest_turn) if latest_turn else None,
        "purpose": (
            "Track objective, handoff reason, expected result, and verified status "
            "without claiming sentience."
        ),
        "strategy_memory_ready": bool(
            search_memories(
                "MGC DXY Asia New York Fibonacci strategy",
                limit=1,
                include_private=False,
            )
        ),
        "strategy_memory_count": strategy_count,
        "deep_conversation_enabled": cfg.deep_conversation_enabled,
        "conversation_engine": "Qwen3.5 4B on demand",
        "complex_planning_engine": "Qwen3.5 9B on demand",
        "active_memory_budget_gb": cfg.local_ai_active_memory_budget_gb,
        "idle_heavy_model_residency": "unloaded after 60 seconds or sooner",
    }
