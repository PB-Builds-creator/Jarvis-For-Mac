from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from .config import DATA_DIR, load_config
from .memory import database, record_timeline, utc_now


VOICE_CONTEXT_PATH = DATA_DIR / "voice-context.json"


def write_voice_context_snapshot(
    destination: Path = VOICE_CONTEXT_PATH,
) -> Path:
    """Publish bounded, non-secret vocabulary for Apple's speech biasing."""
    items = list_vocabulary()[:200]
    phrases = [
        str(item["replacement"] or item["phrase"]).strip()
        for item in items
        if str(item["replacement"] or item["phrase"]).strip()
    ]
    replacements = [
        {
            "phrase": str(item["phrase"]).strip(),
            "replacement": str(item["replacement"]).strip(),
        }
        for item in items
        if str(item["phrase"]).strip() and str(item["replacement"]).strip()
    ]
    value = {
        "version": 1,
        "phrases": phrases,
        "replacements": replacements,
        "count": len(phrases),
        "updated_at": utc_now(),
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.chmod(0o600)
    temporary.replace(destination)
    destination.chmod(0o600)
    return destination


def add_vocabulary(
    phrase: str,
    *,
    replacement: str = "",
    category: str = "general",
) -> int:
    clean = re.sub(r"\s+", " ", phrase.strip())
    if not clean or len(clean) > 120:
        raise ValueError("Vocabulary phrase must be between 1 and 120 characters.")
    now = utc_now()
    with database() as conn:
        row = conn.execute(
            "SELECT id FROM vocabulary WHERE phrase = ? COLLATE NOCASE",
            (clean,),
        ).fetchone()
        if row:
            vocabulary_id = int(row["id"])
            conn.execute(
                "UPDATE vocabulary SET replacement = ?, category = ?, enabled = 1, "
                "updated_at = ? WHERE id = ?",
                (replacement.strip()[:120], category.strip()[:80], now, vocabulary_id),
            )
        else:
            cur = conn.execute(
                "INSERT INTO vocabulary(phrase, replacement, category, enabled, "
                "created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?)",
                (clean, replacement.strip()[:120], category.strip()[:80], now, now),
            )
            vocabulary_id = int(cur.lastrowid)
        conn.commit()
    # Tests and temporary databases must never alter the live recognizer.
    from . import memory as memory_module

    if memory_module.DB_PATH.parent.resolve() == DATA_DIR.resolve():
        write_voice_context_snapshot()
    return vocabulary_id


def list_vocabulary() -> list[dict[str, Any]]:
    with database() as conn:
        rows = conn.execute(
            "SELECT * FROM vocabulary WHERE enabled = 1 "
            "ORDER BY category, phrase COLLATE NOCASE"
        ).fetchall()
    return [dict(row) for row in rows]


def contextual_phrases(limit: int = 200) -> list[str]:
    return [
        str(item["replacement"] or item["phrase"])
        for item in list_vocabulary()[: max(1, min(limit, 500))]
    ]


def apply_vocabulary(transcript: str) -> str:
    corrected = transcript
    items = sorted(
        list_vocabulary(),
        key=lambda item: len(str(item["phrase"])),
        reverse=True,
    )
    for item in items:
        source = str(item["phrase"]).strip()
        replacement = str(item["replacement"]).strip() or source
        corrected = re.sub(
            rf"(?<!\w){re.escape(source)}(?!\w)",
            replacement,
            corrected,
            flags=re.IGNORECASE,
        )
    return corrected


def fallback_status() -> dict[str, Any]:
    cfg = load_config()
    command = cfg.transcription_fallback_command.strip()
    executable = shlex.split(command)[0] if command else ""
    return {
        "enabled": cfg.transcription_fallback_enabled,
        "configured": bool(command),
        "available": bool(executable and Path(executable).is_file()),
        "command": executable,
        "resident": False,
        "policy": "on_demand_low_confidence_only",
    }


def transcribe_fallback(audio_path: Path) -> str:
    """Run an explicitly configured local transcriber; never download or call an API."""
    cfg = load_config()
    if not cfg.transcription_fallback_enabled:
        raise RuntimeError("Local transcription fallback is disabled.")
    command = shlex.split(cfg.transcription_fallback_command)
    if not command or not Path(command[0]).is_file():
        raise RuntimeError(
            "No local transcription fallback is installed. Jarvis will continue "
            "using Apple's on-device recognizer."
        )
    audio = audio_path.expanduser().resolve()
    runtime = (DATA_DIR / "runtime" / "transcription").resolve()
    if not audio.is_file():
        raise ValueError("Audio file not found.")
    converted: Path | None = None
    source = audio
    if audio.suffix.lower() != ".wav":
        handle, converted_name = tempfile.mkstemp(
            prefix="jarvis-whisper-",
            suffix=".wav",
        )
        os.close(handle)
        Path(converted_name).unlink(missing_ok=True)
        converted = Path(converted_name)
        subprocess.run(
            [
                "/usr/bin/afconvert",
                str(audio),
                str(converted),
                "-f",
                "WAVE",
                "-d",
                "LEI16@16000",
                "-c",
                "1",
            ],
            text=True,
            capture_output=True,
            timeout=30,
            check=True,
        )
        source = converted
    arguments = [part.replace("{audio}", str(source)) for part in command]
    if all("{audio}" not in part for part in command):
        arguments.append(str(source))
    try:
        result = subprocess.run(
            arguments,
            text=True,
            capture_output=True,
            timeout=120,
            check=True,
        )
        transcript = apply_vocabulary(result.stdout.strip())
        if not transcript:
            raise RuntimeError("The local transcriber returned no speech.")
        record_timeline(
            "transcription_fallback",
            "Used local transcription fallback",
            {"audio_name": audio.name, "characters": len(transcript)},
            privacy="private",
        )
        return transcript
    finally:
        if converted is not None:
            converted.unlink(missing_ok=True)
        if (
            not cfg.retain_voice_recordings
            and runtime == audio.parent
            and audio.name.startswith("voice-")
        ):
            audio.unlink(missing_ok=True)
