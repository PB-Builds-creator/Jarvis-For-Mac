from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from .actions import queue_action
from .local_ai import ALLOWED_ACTION_TYPES
from .memory import database, record_timeline, utc_now


PARAMETER_RE = re.compile(r"\{\{\s*([a-zA-Z][a-zA-Z0-9_]*)\s*\}\}")


@dataclass(frozen=True)
class RoutineRun:
    name: str
    version: int
    steps: tuple[dict[str, Any], ...]
    queued_action_ids: tuple[int, ...] = ()
    dry_run: bool = True

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "version": self.version,
            "steps": list(self.steps),
            "queued_action_ids": list(self.queued_action_ids),
            "dry_run": self.dry_run,
        }


def _validate_steps(steps: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not steps or len(steps) > 32:
        raise ValueError("A routine must contain between 1 and 32 steps.")
    validated: list[dict[str, Any]] = []
    for index, step in enumerate(steps, 1):
        if not isinstance(step, dict):
            raise ValueError(f"Routine step {index} must be an object.")
        action_type = str(step.get("type", "")).strip()
        payload = step.get("payload", {})
        if action_type not in ALLOWED_ACTION_TYPES:
            raise ValueError(f"Routine step {index} uses an unsupported action type.")
        if not isinstance(payload, dict):
            raise ValueError(f"Routine step {index} payload must be an object.")
        validated.append({"type": action_type, "payload": payload})
    return validated


def save_routine(
    name: str,
    steps: list[dict[str, Any]],
    *,
    description: str = "",
    parameters: dict[str, Any] | None = None,
    requires_confirmation: bool = True,
) -> int:
    clean_name = re.sub(r"\s+", " ", name.strip())[:120]
    if not clean_name:
        raise ValueError("Routine name is required.")
    validated = _validate_steps(steps)
    now = utc_now()
    with database() as conn:
        routine = conn.execute(
            "SELECT * FROM routines WHERE name = ? COLLATE NOCASE",
            (clean_name,),
        ).fetchone()
        if routine:
            routine_id = int(routine["id"])
            version = int(routine["current_version"]) + 1
            conn.execute(
                "UPDATE routines SET description = ?, current_version = ?, "
                "requires_confirmation = ?, updated_at = ? WHERE id = ?",
                (
                    description.strip()[:500],
                    version,
                    int(requires_confirmation),
                    now,
                    routine_id,
                ),
            )
        else:
            cur = conn.execute(
                "INSERT INTO routines(name, description, enabled, current_version, "
                "requires_confirmation, created_at, updated_at) "
                "VALUES (?, ?, 1, 1, ?, ?, ?)",
                (
                    clean_name,
                    description.strip()[:500],
                    int(requires_confirmation),
                    now,
                    now,
                ),
            )
            routine_id = int(cur.lastrowid)
            version = 1
        conn.execute(
            "INSERT INTO routine_versions(routine_id, version, parameters_json, "
            "steps_json, created_at) VALUES (?, ?, ?, ?, ?)",
            (
                routine_id,
                version,
                json.dumps(parameters or {}, sort_keys=True),
                json.dumps(validated, sort_keys=True),
                now,
            ),
        )
        conn.commit()
    record_timeline(
        "routine_saved",
        f"Saved routine {clean_name} v{version}",
        {"routine_id": routine_id, "version": version},
    )
    return routine_id


def list_routines(*, include_disabled: bool = False) -> list[dict[str, Any]]:
    with database() as conn:
        rows = conn.execute(
            "SELECT * FROM routines "
            + ("" if include_disabled else "WHERE enabled = 1 ")
            + "ORDER BY name COLLATE NOCASE"
        ).fetchall()
    return [dict(row) for row in rows]


def get_routine(name: str, version: int | None = None) -> dict[str, Any] | None:
    with database() as conn:
        routine = conn.execute(
            "SELECT * FROM routines WHERE name = ? COLLATE NOCASE",
            (name.strip(),),
        ).fetchone()
        if not routine:
            return None
        selected_version = version or int(routine["current_version"])
        details = conn.execute(
            "SELECT * FROM routine_versions WHERE routine_id = ? AND version = ?",
            (routine["id"], selected_version),
        ).fetchone()
    if not details:
        return None
    result = dict(routine)
    result["version"] = selected_version
    result["parameters"] = json.loads(details["parameters_json"])
    result["steps"] = json.loads(details["steps_json"])
    return result


def _substitute(value: Any, parameters: dict[str, Any]) -> Any:
    if isinstance(value, dict):
        return {key: _substitute(item, parameters) for key, item in value.items()}
    if isinstance(value, list):
        return [_substitute(item, parameters) for item in value]
    if not isinstance(value, str):
        return value
    matches = list(PARAMETER_RE.finditer(value))
    if len(matches) == 1 and matches[0].span() == (0, len(value)):
        key = matches[0].group(1)
        if key not in parameters:
            raise ValueError(f"Routine parameter {key!r} is required.")
        return parameters[key]
    result = value
    for match in reversed(matches):
        key = match.group(1)
        if key not in parameters:
            raise ValueError(f"Routine parameter {key!r} is required.")
        result = result[: match.start()] + str(parameters[key]) + result[match.end() :]
    return result


def run_routine(
    name: str,
    *,
    parameters: dict[str, Any] | None = None,
    dry_run: bool = True,
) -> RoutineRun:
    routine = get_routine(name)
    if routine is None or not routine.get("enabled"):
        raise ValueError("Enabled routine not found.")
    supplied = dict(routine.get("parameters", {}))
    supplied.update(parameters or {})
    steps = tuple(_validate_steps(_substitute(routine["steps"], supplied)))
    action_ids: list[int] = []
    if not dry_run:
        for index, step in enumerate(steps, 1):
            action_ids.append(
                queue_action(
                    step["type"],
                    step["payload"],
                    f"Routine {routine['name']} v{routine['version']} step {index}",
                    plan_id=f"routine:{routine['id']}:{routine['version']}",
                )
            )
    run = RoutineRun(
        str(routine["name"]),
        int(routine["version"]),
        steps,
        tuple(action_ids),
        dry_run,
    )
    record_timeline(
        "routine_previewed" if dry_run else "routine_queued",
        f"{'Previewed' if dry_run else 'Queued'} routine {run.name}",
        run.to_dict(),
    )
    return run
