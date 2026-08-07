from __future__ import annotations

import json
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from .config import FOUNDATION_PLANNER_HELPER, load_config
from .local_ai import (
    LocalDecision,
    compile_local_decision,
    local_model_instructions,
    normalize_local_decision,
)


class FoundationPlannerUnavailable(RuntimeError):
    """The Apple on-device model cannot be used on the current system."""


class FoundationPlanner:
    """Small process boundary around Apple's Foundation Models framework."""

    def __init__(self, helper: Path = FOUNDATION_PLANNER_HELPER) -> None:
        self.helper = helper
        self._lock = threading.RLock()
        self._status_checked_at = 0.0
        self._status_cache: dict[str, Any] = {
            "available": False,
            "reason": "not_checked",
        }
        self._last_error = ""
        self._last_seconds = 0.0
        self._last_used_at = ""

    def _run(
        self,
        arguments: list[str],
        *,
        request: dict[str, Any] | None = None,
        timeout: int,
    ) -> tuple[dict[str, Any], int]:
        if not self.helper.is_file():
            raise FoundationPlannerUnavailable(
                "Apple Foundation Models helper is not installed."
            )
        try:
            result = subprocess.run(
                [str(self.helper), *arguments],
                input=json.dumps(request) if request is not None else None,
                text=True,
                capture_output=True,
                timeout=max(2, timeout),
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise FoundationPlannerUnavailable(str(exc)) from exc
        try:
            value = json.loads(result.stdout)
        except (json.JSONDecodeError, TypeError) as exc:
            detail = (result.stderr or result.stdout or "invalid helper response").strip()
            raise FoundationPlannerUnavailable(detail[:500]) from exc
        if not isinstance(value, dict):
            raise FoundationPlannerUnavailable("Invalid Foundation Models response.")
        return value, result.returncode

    def status(self, *, force: bool = False) -> dict[str, Any]:
        cfg = load_config()
        with self._lock:
            age = time.monotonic() - self._status_checked_at
            if not force and age < 60:
                status = dict(self._status_cache)
            elif not cfg.apple_foundation_models_enabled:
                status = {"available": False, "reason": "disabled"}
                self._status_cache = status
                self._status_checked_at = time.monotonic()
            else:
                try:
                    status, _ = self._run(
                        ["--status"],
                        timeout=min(cfg.apple_foundation_model_timeout_seconds, 10),
                    )
                except FoundationPlannerUnavailable as exc:
                    status = {
                        "available": False,
                        "reason": "helper_unavailable",
                        "error": str(exc)[:300],
                    }
                self._status_cache = status
                self._status_checked_at = time.monotonic()
            return {
                "enabled": cfg.apple_foundation_models_enabled,
                "helper_installed": self.helper.is_file(),
                "available": bool(status.get("available")),
                "reason": str(status.get("reason", "unknown")),
                "last_error": self._last_error,
                "last_generation_seconds": round(self._last_seconds, 3),
                "last_used_at": self._last_used_at,
            }

    def decide(self, transcript: str, *, context: str = "") -> LocalDecision:
        cfg = load_config()
        if not cfg.apple_foundation_models_enabled:
            raise FoundationPlannerUnavailable("Apple Foundation Models is disabled.")
        status = self.status()
        if not status["available"]:
            raise FoundationPlannerUnavailable(
                f"Apple Foundation Models unavailable: {status['reason']}."
            )
        request = {
            "instructions": local_model_instructions("large"),
            "transcript": transcript[:4_000],
            "context": context[:8_000],
            "maximumResponseTokens": 448,
        }
        started = time.monotonic()
        with self._lock:
            value, return_code = self._run(
                [],
                request=request,
                timeout=cfg.apple_foundation_model_timeout_seconds,
            )
            self._last_seconds = time.monotonic() - started
            self._last_used_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            if return_code != 0 or not value.get("ok"):
                self._last_error = str(value.get("error", "generation_failed"))[:300]
                availability = value.get("availability")
                if isinstance(availability, dict):
                    self._status_cache = availability
                    self._status_checked_at = time.monotonic()
                raise FoundationPlannerUnavailable(self._last_error)
            try:
                decision = normalize_local_decision(
                    value.get("decision"),
                    transcript,
                    source="apple_foundation_model",
                )
            except Exception as exc:
                self._last_error = f"{type(exc).__name__}: {exc}"[:300]
                raise
            self._last_error = ""
            return compile_local_decision(decision, transcript)


FOUNDATION_PLANNER = FoundationPlanner()
