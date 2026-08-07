from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import Any

from .memory import database, record_timeline, utc_now


def create_review(
    screenshots: list[str],
    *,
    symbol: str = "MGC+DXY",
    timeframes: list[int] | None = None,
    metadata: dict[str, Any] | None = None,
) -> str:
    existing = [str(Path(path).expanduser().resolve()) for path in screenshots]
    review_id = str(uuid.uuid4())
    now = utc_now()
    with database() as conn:
        conn.execute(
            "INSERT INTO trading_journal(review_id, symbol, timeframes_json, "
            "screenshots_json, metadata_json, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                review_id,
                symbol.strip()[:80] or "MGC+DXY",
                json.dumps(timeframes or [5, 15, 60, 240]),
                json.dumps(existing),
                json.dumps(metadata or {}, sort_keys=True),
                now,
                now,
            ),
        )
        conn.commit()
    record_timeline(
        "trading_review_created",
        "Created analysis-only TradingView review",
        {"review_id": review_id, "screenshots": len(existing)},
    )
    return review_id


def update_review_analysis(
    review_id: str,
    *,
    analysis: str = "",
    bias: str = "",
    key_levels: str = "",
    invalidation: str = "",
    outcome: str = "",
) -> bool:
    now = utc_now()
    with database() as conn:
        changed = conn.execute(
            "UPDATE trading_journal SET analysis = COALESCE(NULLIF(?, ''), analysis), "
            "bias = COALESCE(NULLIF(?, ''), bias), "
            "key_levels = COALESCE(NULLIF(?, ''), key_levels), "
            "invalidation = COALESCE(NULLIF(?, ''), invalidation), "
            "outcome = COALESCE(NULLIF(?, ''), outcome), updated_at = ? "
            "WHERE review_id = ?",
            (
                analysis.strip(),
                bias.strip(),
                key_levels.strip(),
                invalidation.strip(),
                outcome.strip(),
                now,
                review_id,
            ),
        ).rowcount
        conn.commit()
    return bool(changed)


def list_reviews(limit: int = 50) -> list[dict[str, Any]]:
    with database() as conn:
        rows = conn.execute(
            "SELECT * FROM trading_journal ORDER BY created_at DESC LIMIT ?",
            (max(1, min(int(limit), 500)),),
        ).fetchall()
    return [dict(row) for row in rows]
