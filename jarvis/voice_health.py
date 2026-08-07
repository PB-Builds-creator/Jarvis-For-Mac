from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from .config import DATA_DIR


VOICE_DIAGNOSTICS_LOG = DATA_DIR / "logs" / "voice-diagnostics.log"
_TIMESTAMP_RE = re.compile(r"^\[([^\]]+)\]\s+(.*)$")


def _recent_log_lines(
    path: Path,
    *,
    maximum_bytes: int = 750_000,
) -> list[tuple[datetime, str]]:
    if not path.is_file():
        return []
    with path.open("rb") as handle:
        handle.seek(0, 2)
        size = handle.tell()
        handle.seek(max(0, size - maximum_bytes))
        data = handle.read()
    if size > maximum_bytes:
        data = data.split(b"\n", 1)[-1]
    records: list[tuple[datetime, str]] = []
    for raw in data.decode("utf-8", errors="replace").splitlines():
        match = _TIMESTAMP_RE.match(raw)
        if match is None:
            continue
        try:
            timestamp = datetime.fromisoformat(
                match.group(1).replace("Z", "+00:00")
            ).astimezone(timezone.utc)
        except ValueError:
            continue
        records.append((timestamp, match.group(2)))
    return records


def voice_pipeline_health(
    path: Path = VOICE_DIAGNOSTICS_LOG,
    *,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Summarize voice quality without exposing private transcript contents."""
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    cutoff = current - timedelta(hours=24)
    records = [
        (timestamp, event)
        for timestamp, event in _recent_log_lines(path)
        if timestamp >= cutoff
    ]
    counts = {
        "wake_audio_started": 0,
        "wake_start_failures": 0,
        "recognized_commands": 0,
        "transcription_failures": 0,
        "no_speech": 0,
        "intent_matches": 0,
        "generic_fallbacks": 0,
        "contextual_interpretations": 0,
        "whisper_recoveries": 0,
        "owner_voice_accepted": 0,
        "owner_voice_rejected": 0,
    }
    last_wake_started: datetime | None = None
    last_wake_failure: datetime | None = None
    last_command_at: datetime | None = None
    last_engine = ""
    last_device = ""
    for timestamp, event in records:
        if event.startswith("wake_audio_started "):
            counts["wake_audio_started"] += 1
            last_wake_started = timestamp
            device_match = re.search(r"\bdevice=(.+?)\s+rate=", event)
            if device_match:
                last_device = device_match.group(1)
        elif event.startswith("wake_restart_failed "):
            counts["wake_start_failures"] += 1
            last_wake_failure = timestamp
        elif event.startswith(("command_transcript ", "wake_inline_command ")):
            counts["recognized_commands"] += 1
            last_command_at = timestamp
            engine_match = re.search(r"\bengine=([a-z0-9_-]+)", event)
            if engine_match:
                last_engine = engine_match.group(1)
        elif event.startswith("command_transcription_error "):
            counts["transcription_failures"] += 1
        elif event.startswith("command_no_speech "):
            counts["no_speech"] += 1
        elif event.startswith("voice_intent "):
            if " kind=jarvis_request " in f" {event} ":
                counts["generic_fallbacks"] += 1
            else:
                counts["intent_matches"] += 1
            if " interpreted=true " in f" {event} ":
                counts["contextual_interpretations"] += 1
        elif event.startswith("whisper_fallback_completed"):
            counts["whisper_recoveries"] += 1
        elif event.startswith("owner_voice_verification "):
            if " accepted=true " in f" {event} ":
                counts["owner_voice_accepted"] += 1
            elif " accepted=false " in f" {event} ":
                counts["owner_voice_rejected"] += 1

    transcription_attempts = (
        counts["recognized_commands"]
        + counts["transcription_failures"]
        + counts["no_speech"]
    )
    intent_attempts = counts["intent_matches"] + counts["generic_fallbacks"]
    wake_recovered = (
        last_wake_started is not None
        and (
            last_wake_failure is None
            or last_wake_started > last_wake_failure
        )
    )
    status = "healthy"
    warnings: list[str] = []
    if last_wake_failure is not None and not wake_recovered:
        status = "degraded"
        warnings.append("The wake listener has not recovered from its latest start failure.")
    if counts["wake_start_failures"] >= 10:
        warnings.append(
            "The microphone was unavailable repeatedly during the last 24 hours; "
            "Jarvis later recovered." if wake_recovered else
            "The microphone has been unavailable repeatedly during the last 24 hours."
        )
    return {
        "status": status,
        "window_hours": 24,
        "wake_recovered": wake_recovered,
        "last_device": last_device,
        "last_engine": last_engine,
        "last_wake_started_at": (
            last_wake_started.isoformat() if last_wake_started else ""
        ),
        "last_command_at": last_command_at.isoformat() if last_command_at else "",
        "recognition_success_rate": (
            round(counts["recognized_commands"] / transcription_attempts, 3)
            if transcription_attempts else None
        ),
        "intent_match_rate": (
            round(counts["intent_matches"] / intent_attempts, 3)
            if intent_attempts else None
        ),
        "counts": counts,
        "warnings": warnings,
        "privacy": "No transcript text is included.",
    }
