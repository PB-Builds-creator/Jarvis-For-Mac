from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from typing import Iterable

from .config import KEYCHAIN_HELPER, load_config


KEYCHAIN_SERVICE_PREFIX = "dev.pbbuilds.jarvis"
_SECRET_NAME_RE = re.compile(r"^[a-z][a-z0-9_.-]{0,63}$")


def _secret_service(name: str) -> str:
    cleaned = name.strip().casefold()
    if not _SECRET_NAME_RE.fullmatch(cleaned):
        raise ValueError("Secret names use lowercase letters, digits, dots, dashes, or underscores.")
    return f"{KEYCHAIN_SERVICE_PREFIX}.{cleaned}"


def set_keychain_secret(name: str, value: str) -> None:
    """Store a secret in the login Keychain without putting it in process arguments."""
    if not value:
        raise ValueError("Secret value cannot be empty.")
    if not KEYCHAIN_HELPER.is_file():
        raise RuntimeError("Jarvis Keychain helper is not installed.")
    result = subprocess.run(
        [str(KEYCHAIN_HELPER), "set", _secret_service(name)],
        input=value,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or result.stdout.strip()
            or "Keychain rejected the secret."
        )


def set_touch_id_secret(name: str, value: str) -> None:
    """Store a secret that macOS releases only after current-set Touch ID."""
    if not value:
        raise ValueError("Secret value cannot be empty.")
    if not KEYCHAIN_HELPER.is_file():
        raise RuntimeError("Jarvis Keychain helper is not installed.")
    result = subprocess.run(
        [str(KEYCHAIN_HELPER), "set-biometric", _secret_service(name)],
        input=value,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or result.stdout.strip()
            or "Touch ID Keychain storage failed."
        )


def get_touch_id_secret(name: str) -> str | None:
    """Request Touch ID before returning a protected credential."""
    if not KEYCHAIN_HELPER.is_file():
        return None
    result = subprocess.run(
        [str(KEYCHAIN_HELPER), "get-biometric", _secret_service(name)],
        text=True,
        capture_output=True,
        timeout=60,
        check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout.rstrip("\r\n")


def get_keychain_secret(name: str) -> str | None:
    if not KEYCHAIN_HELPER.is_file():
        return None
    result = subprocess.run(
        [str(KEYCHAIN_HELPER), "get", _secret_service(name)],
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout.rstrip("\r\n")


def delete_keychain_secret(name: str) -> bool:
    if not KEYCHAIN_HELPER.is_file():
        return False
    result = subprocess.run(
        [str(KEYCHAIN_HELPER), "delete", _secret_service(name)],
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    return result.returncode == 0


def keychain_status(name: str = "backup-key") -> dict[str, object]:
    if not KEYCHAIN_HELPER.is_file():
        return {
            "available": False,
            "configured": False,
            "service": _secret_service(name),
        }
    result = subprocess.run(
        [str(KEYCHAIN_HELPER), "status", _secret_service(name)],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    try:
        value = json.loads(result.stdout)
    except Exception:
        value = {}
    return {
        "available": True,
        "configured": result.returncode == 0 and bool(value.get("found")),
        "service": _secret_service(name),
    }


SECRET_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "private_key",
        re.compile(
            r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----.*?"
            r"-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
            re.DOTALL,
        ),
    ),
    (
        "bearer_token",
        re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{20,}", re.IGNORECASE),
    ),
    (
        "common_secret",
        re.compile(
            r"(?i)\b(api[_ -]?key|access[_ -]?token|client[_ -]?secret|password)"
            r"\s*[:=]\s*['\"]?([^\s'\";,]{8,})"
        ),
    ),
)


@dataclass(frozen=True)
class RedactionResult:
    text: str
    labels: tuple[str, ...]


def redact_for_cloud(text: str) -> RedactionResult:
    """Remove only high-confidence secrets; preserve ordinary task context."""
    cleaned = text
    labels: list[str] = []
    for label, pattern in SECRET_PATTERNS:
        if pattern.search(cleaned):
            labels.append(label)
            if label == "common_secret":
                cleaned = pattern.sub(lambda match: f"{match.group(1)}=[REDACTED]", cleaned)
            else:
                cleaned = pattern.sub(f"[REDACTED {label}]", cleaned)
    return RedactionResult(cleaned, tuple(dict.fromkeys(labels)))


def require_cloud_handoff_allowed() -> None:
    if load_config().private_mode:
        raise RuntimeError(
            "Jarvis Private Mode is active. ChatGPT handoff is disabled until "
            "Private Mode is turned off."
        )


def filter_shareable_memories(
    memories: Iterable[dict],
) -> list[dict]:
    return [memory for memory in memories if memory.get("privacy") != "private"]
