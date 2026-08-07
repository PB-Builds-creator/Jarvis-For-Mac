from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .config import (
    JARVIS_APP_BINARY,
    NATIVE_HELPER,
    SCREENSHOT_DIR,
    TRADING_CHART_DIR,
    ensure_dirs,
)


@dataclass
class ScreenRead:
    active_app: str
    window_title: str
    text: str
    screenshot_path: str | None
    method: str
    additional_screenshot_paths: tuple[str, ...] = ()

    def all_screenshot_paths(self) -> tuple[str, ...]:
        paths: list[str] = []
        if self.screenshot_path:
            paths.append(self.screenshot_path)
        for path in self.additional_screenshot_paths:
            if path and path not in paths:
                paths.append(path)
        return tuple(paths)


def screenshot_directory_for(active_app: str) -> Path:
    if active_app.strip().lower() == "tradingview":
        return TRADING_CHART_DIR
    return SCREENSHOT_DIR


def _run(args: list[str], timeout: int = 20) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout)


def active_app_name() -> str:
    script = 'tell application "System Events" to get name of first application process whose frontmost is true'
    result = _run(["/usr/bin/osascript", "-e", script], timeout=5)
    return result.stdout.strip() or "Unknown"


def active_window_title() -> str:
    script = (
        'tell application "System Events"\n'
        'set frontApp to first application process whose frontmost is true\n'
        'try\n'
        'return name of front window of frontApp\n'
        'on error\n'
        'return ""\n'
        'end try\n'
        'end tell'
    )
    result = _run(["/usr/bin/osascript", "-e", script], timeout=5)
    return result.stdout.strip()


def capture_full_screenshot() -> Path:
    ensure_dirs()
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    path = SCREENSHOT_DIR / f"screenshot_{timestamp}.png"
    _run(["/usr/sbin/screencapture", "-x", str(path)], timeout=15)
    return path


def read_supplied_tradingview_screenshots(paths: list[str]) -> ScreenRead:
    """Read already-captured Jarvis chart images without taking another screenshot."""
    ensure_dirs()
    chart_root = TRADING_CHART_DIR.resolve()
    resolved: list[Path] = []
    for raw_path in paths[:8]:
        candidate = Path(raw_path).expanduser().resolve()
        if (
            candidate.suffix.casefold() != ".png"
            or not candidate.is_file()
            or not candidate.is_relative_to(chart_root)
        ):
            raise ValueError(
                "Jarvis rejected a chart image outside its organized Trading Chart Reviews folder."
            )
        if candidate not in resolved:
            resolved.append(candidate)
    if not resolved:
        raise ValueError("Jarvis received no valid TradingView screenshots.")

    app = active_app_name()
    title = active_window_title()
    text = "The supplied TradingView screenshots contain no readable text."
    method = "supplied-tradingview-screenshots"
    if NATIVE_HELPER.exists():
        ocr = _run([str(NATIVE_HELPER), "ocr-image", str(resolved[0])], timeout=30)
        if ocr.returncode == 0:
            text = ocr.stdout.strip() or text
            method = "supplied-tradingview-screenshots-plus-vision-ocr"
        elif ocr.stderr.strip():
            text = f"Jarvis captured the chart set, but OCR failed: {ocr.stderr.strip()}"
            method = "supplied-tradingview-screenshots-ocr-error"
    return ScreenRead(
        active_app=app,
        window_title=title,
        text=text,
        screenshot_path=str(resolved[0]),
        method=method,
        additional_screenshot_paths=tuple(str(path) for path in resolved[1:]),
    )


def read_active_window() -> ScreenRead:
    ensure_dirs()
    app = active_app_name()
    title = active_window_title()
    screenshot = None
    text = ""
    method = "metadata-only"

    if JARVIS_APP_BINARY.exists() and NATIVE_HELPER.exists():
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        capture_dir = screenshot_directory_for(app)
        capture_path = capture_dir / f"active_window_{timestamp}.png"
        try:
            capture = _run(
                [str(JARVIS_APP_BINARY), "--capture-active-window", str(capture_path)],
                timeout=70,
            )
        except subprocess.TimeoutExpired:
            text = (
                "Jarvis.app timed out while capturing the active window. "
                "Fully quit and reopen Jarvis, then verify Screen Recording permission."
            )
            method = "jarvis-app-capture-timeout"
        else:
            if capture.returncode == 0 and capture_path.exists():
                try:
                    capture_info = json.loads(capture.stdout.strip().splitlines()[-1])
                    app = str(capture_info.get("owner") or app)
                    title = str(capture_info.get("title") or title)
                except (IndexError, json.JSONDecodeError):
                    pass
                ocr = _run([str(NATIVE_HELPER), "ocr-image", str(capture_path)], timeout=30)
                screenshot = str(capture_path)
                if ocr.returncode == 0:
                    text = ocr.stdout.strip() or "The active window image contains no readable text."
                    method = "jarvis-app-capture-plus-vision-ocr"
                else:
                    text = f"Jarvis captured the window, but OCR failed: {ocr.stderr.strip()}"
                    method = "jarvis-app-capture-ocr-error"
            else:
                detail = capture.stderr.strip() or capture.stdout.strip()
                text = f"Jarvis.app could not capture the active window: {detail}"
                method = "jarvis-app-capture-error"
    elif NATIVE_HELPER.exists():
        result = _run([str(NATIVE_HELPER), "active-window-ocr"], timeout=30)
        if result.returncode == 0 and result.stdout.strip():
            text = result.stdout.strip()
            method = "native-active-window-ocr"
        elif result.stderr.strip():
            text = f"Native screen helper could not read text: {result.stderr.strip()}"
            method = "native-helper-error"

    if not text:
        screenshot = str(capture_full_screenshot())
        text = (
            "Active-window OCR was unavailable. Jarvis captured a screenshot instead. "
            "Use the screenshot plus active app metadata as context."
        )
        method = "screenshot-fallback"

    return ScreenRead(
        active_app=app,
        window_title=title,
        text=text,
        screenshot_path=screenshot,
        method=method,
    )


def read_named_app_window(target_app: str) -> ScreenRead:
    """Capture one visible window from a running app without activating it."""
    ensure_dirs()
    target = target_app.strip()
    if (
        not target
        or len(target) > 80
        or any(character in target for character in ("/", "\\", "\r", "\n"))
    ):
        raise ValueError("Jarvis rejected an invalid application name for window scanning.")

    safe_label = re.sub(r"[^A-Za-z0-9]+", "_", target).strip("_").lower() or "app"
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    capture_dir = screenshot_directory_for(target)
    capture_path = capture_dir / f"{safe_label}_window_{timestamp}.png"
    fallback_text = f"The captured {target} window contains no readable text."

    if not JARVIS_APP_BINARY.exists():
        return ScreenRead(
            active_app=target,
            window_title="",
            text="Jarvis.app is unavailable, so the requested app window was not captured.",
            screenshot_path=None,
            method="jarvis-app-named-capture-error",
        )

    try:
        capture = _run(
            [
                str(JARVIS_APP_BINARY),
                "--capture-app-window",
                target,
                str(capture_path),
            ],
            timeout=70,
        )
    except subprocess.TimeoutExpired:
        return ScreenRead(
            active_app=target,
            window_title="",
            text=(
                f"Jarvis.app timed out while capturing {target}. Fully quit and reopen "
                "Jarvis, then verify Screen Recording permission."
            ),
            screenshot_path=None,
            method="jarvis-app-named-capture-timeout",
        )

    if capture.returncode != 0 or not capture_path.is_file():
        detail = capture.stderr.strip() or capture.stdout.strip() or "Unknown capture failure."
        return ScreenRead(
            active_app=target,
            window_title="",
            text=f"Jarvis.app could not capture {target}: {detail}",
            screenshot_path=None,
            method="jarvis-app-named-capture-error",
        )

    owner = target
    title = ""
    try:
        capture_info = json.loads(capture.stdout.strip().splitlines()[-1])
        owner = str(capture_info.get("owner") or target)
        title = str(capture_info.get("title") or "")
    except (IndexError, json.JSONDecodeError):
        pass

    text = fallback_text
    method = "jarvis-app-named-capture"
    if NATIVE_HELPER.exists():
        ocr = _run([str(NATIVE_HELPER), "ocr-image", str(capture_path)], timeout=30)
        if ocr.returncode == 0:
            text = ocr.stdout.strip() or fallback_text
            method = "jarvis-app-named-capture-plus-vision-ocr"
        else:
            text = f"Jarvis captured {target}, but OCR failed: {ocr.stderr.strip()}"
            method = "jarvis-app-named-capture-ocr-error"

    return ScreenRead(
        active_app=owner,
        window_title=title,
        text=text,
        screenshot_path=str(capture_path),
        method=method,
    )
