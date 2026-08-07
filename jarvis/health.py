from __future__ import annotations

import json
import subprocess
from typing import Any

from .adapters import adapter_status
from .awareness import awareness_status
from .backup import backup_status
from .config import JARVIS_APP_BINARY, load_config
from .foundation_planner import FOUNDATION_PLANNER
from .integrations import integration_status
from .memory import memory_stats
from .owner_voice import owner_voice_status
from .project_index import project_index_status
from .transcription import fallback_status
from .tts import speech_status
from .vision_fallback import status as visual_status
from .local_model import power_status, reclaimable_memory_gb
from .voice_health import voice_pipeline_health


def _native_status(command: str) -> dict[str, Any]:
    if not JARVIS_APP_BINARY.is_file():
        return {"available": False, "reason": "installed_app_missing"}
    try:
        result = subprocess.run(
            [str(JARVIS_APP_BINARY), command],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        value = json.loads(result.stdout)
        if isinstance(value, dict):
            value["command_ok"] = result.returncode == 0
            return value
    except Exception as exc:
        return {"available": False, "reason": str(exc)[:300]}
    return {"available": False, "reason": "invalid_native_response"}


def health_snapshot(*, include_adapters: bool = False) -> dict[str, Any]:
    cfg = load_config()
    snapshot: dict[str, Any] = {
        "private_mode": cfg.private_mode,
        "routing": {
            "order": [
                "deterministic_rules",
                "apple_foundation_model",
                "qwen_4b",
                "qwen_9b",
                "chatgpt_desktop",
            ],
            "cloud_handoff_allowed": not cfg.private_mode,
        },
        "foundation_model": FOUNDATION_PLANNER.status(),
        "memory": memory_stats(),
        "awareness": awareness_status(),
        "project_index": project_index_status(),
        "integrations": integration_status(),
        "transcription_fallback": fallback_status(),
        "visual_fallback": visual_status(),
        "encrypted_backup": backup_status(),
        "permissions": {
            "voice": _native_status("--voice-permission-status"),
            "screen": _native_status("--screen-permission-status"),
            "accessibility": _native_status("--accessibility-permission-status"),
        },
        "audio": _native_status("--audio-device-status"),
        "startup": _native_status("--login-item-status"),
        "voice_shortcut": _native_status("--voice-shortcut-status"),
        "voice_pipeline": voice_pipeline_health(),
        "owner_voice": owner_voice_status(),
        "spoken_voice": speech_status(),
        "resource_policy": {
            "minimum_reclaimable_gb": cfg.model_memory_headroom_gb,
            "qwen_small_idle_seconds": cfg.local_ai_idle_unload_seconds,
            "qwen_large_idle_seconds": cfg.local_ai_large_idle_unload_seconds,
            "heavy_specialists_resident": False,
            "power": power_status(),
            "reclaimable_memory_gb": reclaimable_memory_gb(),
            "large_model_min_battery_percent": cfg.large_model_min_battery_percent,
            "prompt_cache_max_tokens": cfg.prompt_cache_max_tokens,
        },
    }
    if include_adapters:
        snapshot["app_adapters"] = adapter_status()
    return snapshot
