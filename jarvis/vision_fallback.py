from __future__ import annotations

import json
import shlex
import subprocess
from pathlib import Path
from typing import Any

from .config import DATA_DIR, load_config
from .local_model import reclaimable_memory_gb
from .memory import record_timeline


def status() -> dict[str, Any]:
    cfg = load_config()
    command = shlex.split(cfg.visual_fallback_command)
    executable = command[0] if command else ""
    return {
        "enabled": cfg.visual_fallback_enabled,
        "configured": bool(command),
        "available": bool(executable and Path(executable).is_file()),
        "resident": False,
        "policy": "accessibility_then_ocr_then_on_demand_visual",
    }


def analyze_image(image_path: Path, prompt: str) -> dict[str, Any]:
    cfg = load_config()
    if not cfg.visual_fallback_enabled:
        raise RuntimeError("Jarvis visual fallback is disabled.")
    command = shlex.split(cfg.visual_fallback_command)
    if not command or not Path(command[0]).is_file():
        raise RuntimeError("No local visual fallback is installed.")
    available = reclaimable_memory_gb()
    if (
        available is not None
        and available < cfg.model_memory_headroom_gb
    ):
        raise RuntimeError("Jarvis preserved memory headroom and skipped visual inference.")
    image = image_path.expanduser().resolve()
    if not image.is_file():
        raise ValueError("Image not found.")
    arguments = [
        part.replace("{image}", str(image)).replace("{prompt}", prompt)
        for part in command
    ]
    result = subprocess.run(
        arguments,
        text=True,
        capture_output=True,
        timeout=180,
        check=True,
    )
    raw = result.stdout.strip()
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        value = {"text": raw}
    record_timeline(
        "visual_fallback",
        "Used on-demand local visual fallback",
        {"image": image.name, "characters": len(raw)},
        privacy="private",
    )
    return value
