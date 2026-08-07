from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

from .config import PERSONAL_DATA_HELPER
from .memory import add_memory, record_timeline


def integration_status() -> dict[str, Any]:
    if not PERSONAL_DATA_HELPER.is_file():
        return {
            "helper_installed": False,
            "calendar": "helper_missing",
            "reminders": "helper_missing",
            "contacts": "helper_missing",
            "notes": "available_after_confirmation",
            "mail": "draft_only_after_confirmation",
        }
    result = subprocess.run(
        [str(PERSONAL_DATA_HELPER), "status"],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        value = {"error": result.stderr.strip() or "invalid helper response"}
    value["helper_installed"] = True
    return value


def _personal_data(command: str, *arguments: str) -> dict[str, Any]:
    if not PERSONAL_DATA_HELPER.is_file():
        raise RuntimeError("Jarvis personal-data helper is not installed.")
    result = subprocess.run(
        [str(PERSONAL_DATA_HELPER), command, *arguments],
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            result.stderr.strip() or "Invalid personal-data response."
        ) from exc
    if result.returncode != 0 or value.get("ok") is False:
        raise RuntimeError(str(value.get("error", "Personal-data request failed.")))
    return value


def agenda(days: int = 1) -> list[dict[str, Any]]:
    value = _personal_data("agenda", str(max(1, min(int(days), 31))))
    record_timeline(
        "calendar_read",
        "Read local calendar agenda",
        {"days": days, "events": len(value.get("events", []))},
        privacy="private",
    )
    return list(value.get("events", []))


def reminders() -> list[dict[str, Any]]:
    value = _personal_data("reminders")
    record_timeline(
        "reminders_read",
        "Read local reminders",
        {"reminders": len(value.get("reminders", []))},
        privacy="private",
    )
    return list(value.get("reminders", []))


def contacts(query: str) -> list[dict[str, Any]]:
    value = _personal_data("contacts", query[:120])
    record_timeline(
        "contacts_searched",
        "Searched local Contacts",
        {"query": query[:120], "matches": len(value.get("contacts", []))},
        privacy="private",
    )
    return list(value.get("contacts", []))


def create_calendar_event(
    title: str,
    start: str,
    end: str,
    *,
    notes: str = "",
    location: str = "",
    confirmed: bool = False,
) -> dict[str, Any]:
    if not confirmed:
        raise RuntimeError("Creating a Calendar event requires confirmation.")
    payload = {
        "title": title[:300],
        "start": start,
        "end": end,
        "notes": notes[:10_000],
        "location": location[:500],
    }
    value = _personal_data("create-event", json.dumps(payload, separators=(",", ":")))
    record_timeline(
        "calendar_event_created",
        f"Created Calendar event {title[:120]}",
        {"start": start, "end": end},
        privacy="private",
    )
    return value


def create_reminder(
    title: str,
    *,
    due: str = "",
    notes: str = "",
    confirmed: bool = False,
) -> dict[str, Any]:
    if not confirmed:
        raise RuntimeError("Creating a Reminder requires confirmation.")
    payload = {"title": title[:300], "due": due, "notes": notes[:10_000]}
    value = _personal_data(
        "create-reminder",
        json.dumps(payload, separators=(",", ":")),
    )
    record_timeline(
        "reminder_created",
        f"Created Reminder {title[:120]}",
        {"due": due},
        privacy="private",
    )
    return value


def create_note(title: str, body: str, *, confirmed: bool = False) -> str:
    if not confirmed:
        raise RuntimeError("Creating a Note requires confirmation.")
    script = """
    on run argv
      tell application "Notes"
        tell folder "Notes" of default account
          make new note with properties {name:item 1 of argv, body:item 2 of argv}
        end tell
      end tell
    end run
    """
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", script, title[:200], body[:20_000]],
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Notes rejected the new note.")
    record_timeline(
        "note_created",
        f"Created Note {title[:120]}",
        privacy="private",
    )
    return title


def draft_mail(
    recipient: str,
    subject: str,
    body: str,
    *,
    confirmed: bool = False,
) -> str:
    if not confirmed:
        raise RuntimeError("Creating a Mail draft requires confirmation.")
    script = """
    on run argv
      tell application "Mail"
        set draftMessage to make new outgoing message with properties ¬
          {subject:item 2 of argv, content:item 3 of argv, visible:true}
        tell draftMessage
          make new to recipient at end of to recipients with properties ¬
            {address:item 1 of argv}
        end tell
        activate
      end tell
    end run
    """
    result = subprocess.run(
        [
            "/usr/bin/osascript",
            "-e",
            script,
            recipient[:320],
            subject[:300],
            body[:30_000],
        ],
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Mail rejected the draft.")
    record_timeline(
        "mail_drafted",
        "Created an unsent Mail draft",
        {"recipient": recipient, "subject": subject[:300]},
        privacy="private",
    )
    return "Draft created; nothing was sent."


def remember_clipboard(
    text: str,
    *,
    expires_at: str | None = None,
) -> int:
    return add_memory(
        "clipboard",
        "Temporary clipboard capture",
        text[:20_000],
        kind="episode",
        source="clipboard",
        scope="session",
        privacy="private",
        expires_at=expires_at,
    )


def approved_file(path: Path, roots: list[Path]) -> Path:
    resolved = path.expanduser().resolve()
    approved = [root.expanduser().resolve() for root in roots]
    if not any(resolved == root or resolved.is_relative_to(root) for root in approved):
        raise ValueError("File is outside Jarvis's approved roots.")
    return resolved
