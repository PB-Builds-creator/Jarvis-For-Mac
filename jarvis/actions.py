from __future__ import annotations

import json
import os
import subprocess
import time
import uuid
from typing import Any

from .memory import database, record_timeline, utc_now


RISKY_TYPES = {
    "delete_file", "trash_file", "send_message", "install_software",
    "security_change", "financial_action", "shell", "run_shortcut",
}
ALLOWED_TYPES = {
    "open_app", "open_url", "copy_to_clipboard", "type_text", "key_combo",
}


def classify_risk(action_type: str, payload: dict[str, Any]) -> str:
    if action_type in RISKY_TYPES:
        return "blocked"
    if action_type == "type_text":
        return "high"
    if action_type == "key_combo":
        return "medium"
    if action_type in {"open_app", "open_url", "copy_to_clipboard"}:
        return "low"
    return "blocked"


def queue_action(
    action_type: str,
    payload: dict[str, Any],
    reason: str = "",
    *,
    idempotency_key: str = "",
    plan_id: str = "",
    max_attempts: int = 1,
    preconditions: list[dict[str, Any]] | None = None,
    postconditions: list[dict[str, Any]] | None = None,
    undo_steps: list[dict[str, Any]] | None = None,
) -> int:
    risk = classify_risk(action_type, payload)
    now = utc_now()
    stable_key = idempotency_key.strip()[:160] or f"action:{uuid.uuid4()}"
    with database() as conn:
        existing = conn.execute(
            "SELECT id FROM action_queue WHERE idempotency_key = ? "
            "AND status IN ('pending', 'approved', 'running', 'completed') "
            "ORDER BY id DESC LIMIT 1",
            (stable_key,),
        ).fetchone()
        if existing:
            return int(existing["id"])
        cur = conn.execute(
            "INSERT INTO action_queue(action_type, payload_json, risk_level, status, "
            "reason, idempotency_key, plan_id, max_attempts, preconditions_json, "
            "postconditions_json, undo_json, created_at, updated_at) "
            "VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                action_type,
                json.dumps(payload, sort_keys=True),
                risk,
                reason,
                stable_key,
                plan_id.strip()[:160],
                max(1, min(int(max_attempts), 3)),
                json.dumps(preconditions or [], sort_keys=True),
                json.dumps(postconditions or [], sort_keys=True),
                json.dumps(undo_steps or [], sort_keys=True),
                now,
                now,
            ),
        )
        conn.commit()
        action_id = int(cur.lastrowid)
    record_timeline(
        "action_queued",
        f"Queued {action_type}",
        {"action_id": action_id, "risk": risk, "plan_id": plan_id},
        correlation_id=plan_id,
    )
    return action_id


def list_actions(status: str | None = None) -> list[dict]:
    with database() as conn:
        if status:
            rows = conn.execute("SELECT * FROM action_queue WHERE status = ? ORDER BY id DESC", (status,)).fetchall()
        else:
            rows = conn.execute("SELECT * FROM action_queue ORDER BY id DESC").fetchall()
    return [dict(row) for row in rows]


def approve_action(action_id: int) -> bool:
    now = utc_now()
    with database() as conn:
        row = conn.execute("SELECT * FROM action_queue WHERE id = ?", (action_id,)).fetchone()
        if not row or row["risk_level"] == "blocked":
            return False
        conn.execute(
            "UPDATE action_queue SET status = ?, updated_at = ? WHERE id = ?",
            ("approved", now, action_id),
        )
        conn.commit()
    record_timeline(
        "action_approved",
        f"Approved action {action_id}",
        {"action_id": action_id},
    )
    return True


def _osascript(script: str) -> None:
    subprocess.run(["/usr/bin/osascript", "-e", script], check=True, text=True, capture_output=True, timeout=15)


def _copy_to_clipboard(text: str) -> None:
    proc = subprocess.run(["/usr/bin/pbcopy"], input=text, text=True, capture_output=True, timeout=10)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "pbcopy failed")


def _check_conditions(conditions: list[dict[str, Any]], *, phase: str) -> None:
    for condition in conditions:
        kind = str(condition.get("type", "")).strip()
        value = str(condition.get("value", "")).strip()
        if kind == "path_exists":
            passed = bool(value and os.path.exists(os.path.expanduser(value)))
        elif kind == "path_absent":
            passed = bool(value and not os.path.exists(os.path.expanduser(value)))
        elif kind == "executable_exists":
            passed = bool(value and os.path.isfile(value) and os.access(value, os.X_OK))
        elif kind == "url_prefix":
            actual = str(condition.get("actual", ""))
            passed = bool(value and actual.startswith(value))
        elif kind == "clipboard_equals":
            result = subprocess.run(
                ["/usr/bin/pbpaste"],
                text=True,
                capture_output=True,
                timeout=5,
                check=False,
            )
            passed = result.returncode == 0 and result.stdout == value
        else:
            raise ValueError(f"Unsupported {phase} condition: {kind or 'missing type'}.")
        if not passed:
            raise RuntimeError(f"{phase.capitalize()} failed: {kind}.")


def _perform_action(
    action_type: str,
    payload: dict[str, Any],
) -> tuple[str, list[dict[str, Any]]]:
    reversible: list[dict[str, Any]] = []
    if action_type == "open_app":
        app = str(payload.get("name", "")).strip()
        if not app:
            raise ValueError("Missing app name.")
        subprocess.run(["/usr/bin/open", "-a", app], check=True, timeout=15)
        result = f"Opened app: {app}"
        reversible.append(
            {
                "type": "quit_app",
                "payload": {"name": app},
                "automatic": False,
                "description": f"Quit {app} after explicit approval.",
            }
        )
    elif action_type == "open_url":
        url = str(payload.get("url", "")).strip()
        if not (url.startswith("https://") or url.startswith("http://")):
            raise ValueError("Only http and https URLs are allowed.")
        subprocess.run(["/usr/bin/open", url], check=True, timeout=15)
        result = f"Opened URL: {url}"
    elif action_type == "copy_to_clipboard":
        text = str(payload.get("text", ""))
        _copy_to_clipboard(text)
        result = "Copied text to clipboard."
    elif action_type == "type_text":
        text = str(payload.get("text", ""))
        escaped = text.replace("\\", "\\\\").replace('"', '\\"')
        _osascript(f'tell application "System Events" to keystroke "{escaped}"')
        result = "Typed approved text into the focused app."
    elif action_type == "key_combo":
        key = str(payload.get("key", "")).strip()
        modifiers = [
            str(m).strip().lower() for m in payload.get("modifiers", [])
        ]
        allowed_mods = {
            "command": "command down",
            "shift": "shift down",
            "option": "option down",
            "control": "control down",
        }
        mod_text = ", ".join(
            allowed_mods[m] for m in modifiers if m in allowed_mods
        )
        if not key:
            raise ValueError("Missing key.")
        if mod_text:
            _osascript(
                f'tell application "System Events" to keystroke "{key}" '
                f"using {{{mod_text}}}"
            )
        else:
            _osascript(f'tell application "System Events" to keystroke "{key}"')
        result = "Sent approved keyboard shortcut."
    else:
        raise ValueError("Unsupported action type.")
    return result, reversible


def execute_action(action_id: int) -> str:
    started = utc_now()
    with database() as conn:
        row = conn.execute("SELECT * FROM action_queue WHERE id = ?", (action_id,)).fetchone()
        if not row:
            raise ValueError("Action not found.")
        if row["status"] != "approved":
            raise ValueError("Action must be approved before it can run.")
        if row["risk_level"] == "blocked":
            raise ValueError("Blocked actions cannot be executed by Jarvis.")
        payload = json.loads(row["payload_json"])
        action_type = row["action_type"]
        changed = conn.execute(
            "UPDATE action_queue SET status = 'running', attempts = attempts + 1, "
            "started_at = ?, updated_at = ? WHERE id = ? AND status = 'approved'",
            (started, started, action_id),
        )
        if changed.rowcount != 1:
            conn.rollback()
            raise RuntimeError("Action was already claimed by another Jarvis worker.")
        conn.commit()

    preconditions = json.loads(row["preconditions_json"] or "[]")
    postconditions = json.loads(row["postconditions_json"] or "[]")
    configured_undo = json.loads(row["undo_json"] or "[]")
    max_attempts = max(1, min(int(row["max_attempts"]), 3))
    checkpoints: list[dict[str, Any]] = []
    try:
        if action_type not in ALLOWED_TYPES:
            raise ValueError("Unsupported action type.")
        _check_conditions(preconditions, phase="precondition")
        result = ""
        inferred_undo: list[dict[str, Any]] = []
        for attempt in range(1, max_attempts + 1):
            try:
                result, inferred_undo = _perform_action(action_type, payload)
                _check_conditions(postconditions, phase="postcondition")
                checkpoints.append(
                    {"attempt": attempt, "status": "completed", "at": utc_now()}
                )
                break
            except Exception as exc:
                checkpoints.append(
                    {
                        "attempt": attempt,
                        "status": "failed",
                        "error": str(exc)[:500],
                        "at": utc_now(),
                    }
                )
                with database() as conn:
                    conn.execute(
                        "UPDATE action_queue SET attempts = ?, checkpoint_json = ?, "
                        "error = ?, updated_at = ? WHERE id = ?",
                        (
                            attempt,
                            json.dumps(checkpoints, sort_keys=True),
                            str(exc)[:1000],
                            utc_now(),
                            action_id,
                        ),
                    )
                    conn.commit()
                if attempt >= max_attempts:
                    raise
                time.sleep(0.20 * attempt)
    except Exception as exc:
        now = utc_now()
        with database() as conn:
            conn.execute(
                "UPDATE action_queue SET status = 'failed', error = ?, "
                "checkpoint_json = ?, completed_at = ?, updated_at = ? WHERE id = ?",
                (
                    str(exc)[:1000],
                    json.dumps(checkpoints, sort_keys=True),
                    now,
                    now,
                    action_id,
                ),
            )
            conn.commit()
        record_timeline(
            "action_failed",
            f"Action {action_id} failed",
            {"action_id": action_id, "error": str(exc)[:500]},
        )
        raise

    now = utc_now()
    receipt_id = f"receipt:{uuid.uuid4()}"
    reversible = configured_undo or inferred_undo
    with database() as conn:
        conn.execute(
            "UPDATE action_queue SET status = 'completed', result = ?, "
            "checkpoint_json = ?, undo_json = ?, completed_at = ?, updated_at = ? "
            "WHERE id = ?",
            (
                result,
                json.dumps(checkpoints, sort_keys=True),
                json.dumps(reversible, sort_keys=True),
                now,
                now,
                action_id,
            ),
        )
        conn.execute(
            "INSERT INTO action_receipts(receipt_id, plan_id, idempotency_key, "
            "status, steps_json, result_json, reversible_json, created_at, completed_at) "
            "VALUES (?, ?, ?, 'completed', ?, ?, ?, ?, ?)",
            (
                receipt_id,
                str(row["plan_id"]),
                str(row["idempotency_key"]),
                json.dumps([{"type": action_type, "payload": payload}], sort_keys=True),
                json.dumps({"result": result}, sort_keys=True),
                json.dumps(reversible, sort_keys=True),
                started,
                now,
            ),
        )
        conn.commit()
    record_timeline(
        "action_completed",
        result,
        {"action_id": action_id, "receipt_id": receipt_id},
        correlation_id=str(row["plan_id"]),
    )
    return result
