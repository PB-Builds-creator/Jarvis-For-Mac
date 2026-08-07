from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from datetime import datetime, time as clock_time
from typing import Any

from .config import load_config
from .memory import database, record_timeline, utc_now
from .routines import run_routine


SUPPORTED_TRIGGERS = {
    "login",
    "wake",
    "schedule",
    "calendar",
    "microphone_connected",
    "microphone_disconnected",
    "battery",
    "thermal",
    "app_launched",
    "file_added",
    "screenshot_created",
    "wifi_changed",
    "tradingview_opened",
    "task_completed",
}
RISK_POLICIES = {"notify", "propose", "queue_low_risk"}
DEFAULT_RULES = (
    {
        "name": "Razer microphone disconnected",
        "trigger_type": "microphone_disconnected",
        "trigger": {"device": "Razer"},
        "notification_text": (
            "Razer Seiren V3 Mini disconnected. Jarvis is using the available fallback input."
        ),
        "cooldown_seconds": 300,
    },
    {
        "name": "Thermal pressure",
        "trigger_type": "thermal",
        "trigger": {"state": "serious"},
        "notification_text": (
            "Mac thermal pressure is serious. Jarvis will avoid large local models."
        ),
        "cooldown_seconds": 900,
    },
    {
        "name": "Jarvis task completed",
        "trigger_type": "task_completed",
        "trigger": {},
        "notification_text": "Jarvis finished the requested task.",
        "cooldown_seconds": 30,
    },
)


@dataclass(frozen=True)
class EventOutcome:
    event_type: str
    matched_rules: tuple[str, ...]
    notifications: tuple[str, ...]
    queued_routines: tuple[dict[str, Any], ...]
    suppressed: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "event_type": self.event_type,
            "matched_rules": list(self.matched_rules),
            "notifications": list(self.notifications),
            "queued_routines": list(self.queued_routines),
            "suppressed": list(self.suppressed),
        }


def save_event_rule(
    name: str,
    trigger_type: str,
    *,
    trigger: dict[str, Any] | None = None,
    routine_name: str = "",
    notification_text: str = "",
    risk_policy: str = "notify",
    cooldown_seconds: int = 3600,
    quiet_hours_exempt: bool = False,
) -> int:
    trigger_type = trigger_type.strip().casefold()
    if trigger_type not in SUPPORTED_TRIGGERS:
        raise ValueError("Unsupported proactive trigger.")
    risk_policy = risk_policy.strip().casefold()
    if risk_policy not in RISK_POLICIES:
        raise ValueError("Unsupported proactive risk policy.")
    if not notification_text.strip() and not routine_name.strip():
        raise ValueError("An event rule needs a notification or a routine.")
    now = utc_now()
    with database() as conn:
        existing = conn.execute(
            "SELECT id FROM proactive_rules WHERE name = ? COLLATE NOCASE",
            (name.strip(),),
        ).fetchone()
        values = (
            trigger_type,
            json.dumps(trigger or {}, sort_keys=True),
            routine_name.strip(),
            notification_text.strip()[:500],
            risk_policy,
            int(quiet_hours_exempt),
            max(30, min(int(cooldown_seconds), 604800)),
            now,
        )
        if existing:
            rule_id = int(existing["id"])
            conn.execute(
                "UPDATE proactive_rules SET trigger_type = ?, trigger_json = ?, "
                "routine_name = ?, notification_text = ?, risk_policy = ?, "
                "quiet_hours_exempt = ?, cooldown_seconds = ?, updated_at = ? "
                "WHERE id = ?",
                (*values, rule_id),
            )
        else:
            cur = conn.execute(
                "INSERT INTO proactive_rules(name, trigger_type, trigger_json, "
                "routine_name, notification_text, risk_policy, quiet_hours_exempt, "
                "cooldown_seconds, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (name.strip()[:120], *values[:-1], now, now),
            )
            rule_id = int(cur.lastrowid)
        conn.commit()
    record_timeline(
        "event_rule_saved",
        f"Saved event rule {name.strip()}",
        {"rule_id": rule_id, "trigger_type": trigger_type},
    )
    return rule_id


def list_event_rules() -> list[dict[str, Any]]:
    with database() as conn:
        rows = conn.execute(
            "SELECT * FROM proactive_rules ORDER BY name COLLATE NOCASE"
        ).fetchall()
    return [dict(row) for row in rows]


def seed_default_event_rules() -> int:
    created = 0
    with database() as conn:
        existing = {
            str(row["name"]).casefold()
            for row in conn.execute("SELECT name FROM proactive_rules").fetchall()
        }
    for rule in DEFAULT_RULES:
        if str(rule["name"]).casefold() in existing:
            continue
        save_event_rule(**rule)
        created += 1
    return created


def _parse_clock(value: str, fallback: clock_time) -> clock_time:
    try:
        hour, minute = value.split(":", 1)
        return clock_time(int(hour), int(minute))
    except (ValueError, TypeError):
        return fallback


def quiet_hours_active(now: datetime | None = None) -> bool:
    cfg = load_config()
    current = (now or datetime.now()).time()
    start = _parse_clock(cfg.quiet_hours_start, clock_time(22, 0))
    end = _parse_clock(cfg.quiet_hours_end, clock_time(7, 0))
    if start == end:
        return False
    if start < end:
        return start <= current < end
    return current >= start or current < end


def _matches(rule_trigger: dict[str, Any], payload: dict[str, Any]) -> bool:
    for key, expected in rule_trigger.items():
        actual = payload.get(key)
        if isinstance(expected, str) and isinstance(actual, str):
            if expected.casefold() not in actual.casefold():
                return False
        elif actual != expected:
            return False
    return True


def _notify(message: str) -> None:
    script = (
        "on run argv\n"
        'display notification (item 1 of argv) with title "Jarvis"\n'
        "end run"
    )
    subprocess.run(
        ["/usr/bin/osascript", "-e", script, message],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )


def emit_event(
    event_type: str,
    payload: dict[str, Any] | None = None,
    *,
    deliver_notifications: bool = True,
) -> EventOutcome:
    cfg = load_config()
    event_type = event_type.strip().casefold()
    if event_type not in SUPPORTED_TRIGGERS:
        raise ValueError("Unsupported event type.")
    event_payload = payload or {}
    record_timeline(
        "system_event",
        f"Observed {event_type.replace('_', ' ')}",
        event_payload,
    )
    if not cfg.event_engine_enabled:
        return EventOutcome(event_type, (), (), (), ("event engine disabled",))

    matched: list[str] = []
    notifications: list[str] = []
    queued: list[dict[str, Any]] = []
    suppressed: list[str] = []
    now = datetime.now().astimezone()
    now_iso = utc_now()
    with database() as conn:
        rules = conn.execute(
            "SELECT * FROM proactive_rules WHERE enabled = 1 AND trigger_type = ? "
            "ORDER BY id",
            (event_type,),
        ).fetchall()
        for rule in rules:
            rule_name = str(rule["name"])
            trigger = json.loads(rule["trigger_json"])
            if not _matches(trigger, event_payload):
                continue
            matched.append(rule_name)
            if rule["last_fired_at"]:
                try:
                    last = datetime.fromisoformat(str(rule["last_fired_at"]))
                    if last.tzinfo is None:
                        last = last.replace(tzinfo=now.tzinfo)
                    if (now - last.astimezone(now.tzinfo)).total_seconds() < int(
                        rule["cooldown_seconds"]
                    ):
                        suppressed.append(f"{rule_name}: cooldown")
                        continue
                except ValueError:
                    pass
            if quiet_hours_active(now) and not bool(rule["quiet_hours_exempt"]):
                suppressed.append(f"{rule_name}: quiet hours")
                continue
            message = str(rule["notification_text"]).strip()
            if message:
                notifications.append(message)
                if deliver_notifications:
                    _notify(message)
            routine_name = str(rule["routine_name"]).strip()
            policy = str(rule["risk_policy"])
            if routine_name:
                if policy == "queue_low_risk" and cfg.proactive_actions_enabled:
                    run = run_routine(routine_name, dry_run=False)
                else:
                    run = run_routine(routine_name, dry_run=True)
                queued.append(run.to_dict())
            conn.execute(
                "UPDATE proactive_rules SET last_fired_at = ?, updated_at = ? "
                "WHERE id = ?",
                (now_iso, now_iso, rule["id"]),
            )
        conn.commit()
    outcome = EventOutcome(
        event_type,
        tuple(matched),
        tuple(notifications),
        tuple(queued),
        tuple(suppressed),
    )
    record_timeline(
        "event_processed",
        f"Processed {event_type.replace('_', ' ')}",
        outcome.to_dict(),
    )
    return outcome
