from __future__ import annotations

from difflib import SequenceMatcher
import re
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Callable, TypeVar

from .config import DATA_DIR
from .local_ai import (
    APP_NAME_ALIASES,
    BROWSER_NAMES,
    is_backtest_review_request,
    is_local_control_request,
    is_tradingview_workflow_request,
    request_local_decision,
)


VOICE_RUNTIME_DIR = DATA_DIR / "runtime" / "voice"
VOICE_ARTIFACT_SUFFIXES = {".m4a", ".txt", ".wav"}


class VoiceConfirmationRequired(RuntimeError):
    """Raised when a voice request has not been confirmed in Jarvis's preview."""


@dataclass(frozen=True)
class VoiceIntent:
    transcript: str
    kind: str
    title: str
    task: str
    route: str
    requires_confirmation: bool = True
    reply: str = ""
    actions: tuple[dict[str, object], ...] = ()
    source: str = "rules"
    confirmation_level: str = "standard"
    scan_target: str = ""
    heard_transcript: str = ""
    interpretation_reason: str = "exact"
    interpretation_confidence: float = 1.0

    def to_dict(self) -> dict[str, object]:
        return {
            "transcript": self.transcript,
            "heard_transcript": self.heard_transcript or self.transcript,
            "kind": self.kind,
            "title": self.title,
            "task": self.task,
            "route": self.route,
            "requires_confirmation": self.requires_confirmation,
            "reply": self.reply,
            "actions": list(self.actions),
            "source": self.source,
            "confirmation_level": self.confirmation_level,
            "scan_target": self.scan_target,
            "interpretation_reason": self.interpretation_reason,
            "interpretation_confidence": round(self.interpretation_confidence, 3),
        }


def _normalized(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip()).casefold()


_SCAN_ACTION_WORDS = (
    "scan", "scanned", "scanning", "capture", "captured", "screenshot",
    "snapshot", "snap", "review", "analyze", "analyse", "check", "inspect",
)
_ACTION_FUZZY_STOPWORDS = {
    "a", "an", "and", "can", "could", "current", "do", "for", "i", "it",
    "jarvis", "me", "my", "of", "once", "one", "please", "the", "this",
    "time", "to", "view", "would", "you",
}
_SINGLE_SCAN_RE = re.compile(
    r"\b(?:once|ones|wants|won|single|one[ -]time|1[ -]time|one[ -]shot|"
    r"just[ -]once|only[ -]once|just[ -]one|only[ -]one|a[ -]single[ -]time)\b",
    flags=re.IGNORECASE,
)
_DEICTIC_SCAN_RE = re.compile(
    r"\b(?:this|current|active|front|frontmost)\s+(?:app|application|window|screen|chart)\b",
    flags=re.IGNORECASE,
)
_KNOWN_SCAN_TARGETS = {
    "arc": "Arc",
    "chat gpt": "ChatGPT",
    "chatgpt": "ChatGPT",
    "chrome": "Google Chrome",
    "codex": "Codex",
    "discord": "Discord",
    "finder": "Finder",
    "firefox": "Firefox",
    "google chrome": "Google Chrome",
    "mail": "Mail",
    "microsoft edge": "Microsoft Edge",
    "notes": "Notes",
    "safari": "Safari",
    "settings": "System Settings",
    "system settings": "System Settings",
    "terminal": "Terminal",
    "trading few": "TradingView",
    "trading review": "TradingView",
    "trading view": "TradingView",
    "trading vue": "TradingView",
    "trading you": "TradingView",
    "tradingview": "TradingView",
    "train view": "TradingView",
    "training view": "TradingView",
    "treating view": "TradingView",
    "treating you": "TradingView",
}


def _spoken_words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", text.casefold())


def _phrase_similarity(left: str, right: str) -> float:
    return SequenceMatcher(None, left.replace(" ", ""), right.replace(" ", "")).ratio()


def _best_phrase_match(
    words: list[str],
    choices: dict[str, str],
    *,
    maximum_words: int = 3,
) -> tuple[str, float]:
    best_target = ""
    best_score = 0.0
    for width in range(1, min(maximum_words, len(words)) + 1):
        for start in range(0, len(words) - width + 1):
            phrase = " ".join(words[start:start + width])
            for alias, target in choices.items():
                score = _phrase_similarity(phrase, alias)
                if score > best_score:
                    best_target, best_score = target, score
    return best_target, best_score


def _best_action_score(words: list[str]) -> float:
    return max(
        (
            _phrase_similarity(word, action)
            for word in words
            if word not in _ACTION_FUZZY_STOPWORDS
            for action in _SCAN_ACTION_WORDS
        ),
        default=0.0,
    )


def _active_app_from_context(local_context: str) -> str:
    match = re.search(r"(?im)^Active app:\s*([^\r\n]{1,80})", local_context)
    if match is None:
        return ""
    raw = match.group(1).strip()
    normalized = re.sub(r"[^a-z0-9]+", " ", raw.casefold()).strip()
    return _KNOWN_SCAN_TARGETS.get(
        normalized,
        BROWSER_NAMES.get(
            normalized,
            APP_NAME_ALIASES.get(normalized, raw),
        ),
    )


def _contextualize_known_voice_command(
    transcript: str,
    *,
    local_context: str,
) -> tuple[str, str, float]:
    """Correct a likely command from its words, command catalog, and active app.

    This deliberately handles only bounded, confirmation-gated scan commands.
    Ordinary conversation and consequential command arguments are never fuzzily
    rewritten.
    """
    body = re.sub(
        r"^(?:(?:hey|hi)\s+)?jarvis\s*[,;:\-]?\s*",
        "",
        transcript.strip(),
        flags=re.IGNORECASE,
    ).strip(" .!?\t\r\n")
    words = _spoken_words(body)
    if not words or len(words) > 14:
        return transcript, "exact", 1.0

    action_score = _best_action_score(words)
    target, target_score = _best_phrase_match(words, _KNOWN_SCAN_TARGETS)
    active_app = _active_app_from_context(local_context)
    explicit_single = _SINGLE_SCAN_RE.search(body) is not None
    deictic = _DEICTIC_SCAN_RE.search(body) is not None
    has_timeframe_detail = re.search(
        r"\b(?:one|two|three|four|five|ten|fifteen|thirty|1|2|3|4|5|10|15|30|"
        r"60|240)\s*(?:-| )?(?:minute|minutes|min|hour|hours|hr|timeframe|"
        r"time frame)\b",
        body,
        flags=re.IGNORECASE,
    ) is not None

    # Bare "one" at the end is a common recognition of "once", but never treat
    # "one minute/hour/timeframe" as a one-shot request.
    if (
        not explicit_single
        and re.search(r"\b(?:one|1)\s*(?:please)?$", body, flags=re.IGNORECASE)
        and re.search(
            r"\b(?:one|1)\s+(?:minute|minutes|min|hour|hours|timeframe|time frame)\b",
            body,
            flags=re.IGNORECASE,
        ) is None
    ):
        explicit_single = True

    if explicit_single and action_score >= 0.60:
        if active_app and deictic:
            confidence = min(0.95, 0.55 * action_score + 0.35)
            return (
                f"scan {active_app} once",
                "active_app_command_context",
                confidence,
            )
        if target_score >= 0.78:
            confidence = min(0.99, 0.50 * action_score + 0.50 * target_score)
            return f"scan {target} once", "fuzzy_known_command", confidence
        if active_app and (deictic or len(words) <= 5):
            confidence = min(0.95, 0.55 * action_score + 0.35)
            return (
                f"scan {active_app} once",
                "active_app_command_context",
                confidence,
            )

    # Non-TradingView named-app scans are one-shot by definition. Preserve the
    # established short "scan TradingView" command as the four-timeframe review.
    if (
        not has_timeframe_detail
        and action_score >= 0.72
        and target_score >= 0.78
    ):
        confidence = min(0.98, 0.50 * action_score + 0.50 * target_score)
        command = (
            "scan TradingView"
            if target == "TradingView"
            else f"scan {target}"
        )
        return command, "fuzzy_known_command", confidence

    return transcript, "exact", 1.0


def _named_window_scan_target(transcript: str) -> str | None:
    """Return a safe named app for an explicit one-shot window scan."""
    body = re.sub(
        r"^(?:(?:hey|hi)\s+)?jarvis\s*[,;:\-]?\s*",
        "",
        transcript.strip(),
        flags=re.IGNORECASE,
    ).strip(" .!?\t\r\n")
    match = re.fullmatch(
        r"(?:please\s+)?(?:(?:do|run|take)\s+)?"
        r"(?:(?:a\s+)?(?P<prefix>single|one[ -]time)\s+)?"
        r"(?:scan|capture)(?:\s+(?:of))?\s+(?P<target>.+)",
        body,
        flags=re.IGNORECASE,
    )
    if match is None:
        return None

    raw_target = match.group("target").strip()
    explicit_single = match.group("prefix") is not None
    suffix = re.search(
        r"\s+(?:once|one[ -]time|a\s+single\s+time|just\s+once)$",
        raw_target,
        flags=re.IGNORECASE,
    )
    if suffix is not None:
        explicit_single = True
        raw_target = raw_target[: suffix.start()].strip()

    wrapper = re.search(
        r"\s+(?:window|app|application)$",
        raw_target,
        flags=re.IGNORECASE,
    )
    if wrapper is not None:
        explicit_single = True
        raw_target = raw_target[: wrapper.start()].strip()
    raw_target = re.sub(
        r"^(?:the|a|an)\s+", "", raw_target, flags=re.IGNORECASE
    ).strip()

    normalized = re.sub(r"[^a-z0-9]+", " ", raw_target.casefold()).strip()
    if (
        not normalized
        or len(raw_target) > 80
        or re.search(r"[/\\\r\n]", raw_target)
        or re.search(r"\b(?:and|then|send)\b", normalized)
        or normalized in {
            "active", "active window", "current", "current window", "desktop",
            "frontmost", "market", "markets", "screen", "this", "this window",
            "today", "todays market", "window",
        }
        or re.search(
            r"\b(?:back\s*test(?:ing)?|browser|chart|market|screen|technical analysis)\b",
            normalized,
        )
        or re.search(r"\b(?:four|4)\s+time\s*frames?\b", normalized)
        or re.search(
            r"\b(?:one|two|three|four|five|ten|fifteen|thirty|1|2|3|4|5|"
            r"10|15|30|60|240)\s*(?:minute|minutes|min|hour|hours|hr|"
            r"timeframe|time frame)\b",
            normalized,
        )
    ):
        return None

    target = BROWSER_NAMES.get(
        normalized,
        APP_NAME_ALIASES.get(normalized, raw_target.title()),
    )
    # Preserve the established short TradingView scan as the four-timeframe
    # review. "Once", "single", or an explicit app/window wrapper opts into
    # this new one-screenshot path.
    if target == "TradingView" and not explicit_single:
        return None
    return target


def parse_voice_command(transcript: str, *, local_context: str = "") -> VoiceIntent:
    """Map a transcript to a safe Jarvis request without executing it."""
    heard = re.sub(r"\s+", " ", transcript.strip())
    if not heard:
        raise ValueError("No speech was recognized.")
    cleaned, interpretation_reason, interpretation_confidence = (
        _contextualize_known_voice_command(heard, local_context=local_context)
    )
    intent_metadata = {
        "heard_transcript": heard,
        "interpretation_reason": interpretation_reason,
        "interpretation_confidence": interpretation_confidence,
    }

    lowered = _normalized(cleaned)
    scan_target = _named_window_scan_target(cleaned)
    if scan_target:
        destination = "work" if scan_target == "TradingView" else "chat"
        destination_title = destination.title()
        task = (
            f"Analyze this single captured {scan_target} window only. Treat the attached "
            "screenshot as primary evidence, summarize what is visible, identify anything "
            "important or unusual, and give the most useful next step. Do not claim to have "
            "scanned any other window."
        )
        if scan_target == "TradingView":
            task += (
                " State the visible chart bias, evidence, key levels, and invalidation. "
                "Decision support only; do not place, modify, or close a trade."
            )
        return VoiceIntent(
            transcript=cleaned,
            kind="scan_app_window",
            title=f"Scan {scan_target} once in Jarvis {destination_title}",
            task=task,
            route=destination,
            source="named_window_scan_rule",
            scan_target=scan_target,
            **intent_metadata,
        )
    tradingview_workflow = (
        is_tradingview_workflow_request(cleaned)
        or is_backtest_review_request(cleaned)
    )
    if not tradingview_workflow and "send" in lowered and "work" in lowered:
        return VoiceIntent(
            transcript=cleaned,
            kind="send_to_work",
            title="Send the active window to Jarvis Work",
            task="Analyze the active window and complete the requested work safely.",
            route="work",
            **intent_metadata,
        )
    if not tradingview_workflow and "analy" in lowered and "chart" in lowered:
        return VoiceIntent(
            transcript=cleaned,
            kind="analyze_chart",
            title="Analyze the active chart",
            task=(
                "Analyze the active chart. State the directional bias, evidence for and "
                "against it, key levels, and a clear invalidation. This is decision support "
                "only; do not place, modify, or close a trade."
            ),
            route="work",
            **intent_metadata,
        )
    if not tradingview_workflow and "summar" in lowered and ("window" in lowered or "screen" in lowered):
        return VoiceIntent(
            transcript=cleaned,
            kind="summarize_window",
            title="Summarize the active window",
            task="Summarize the active window and identify the most useful next step.",
            route="chat",
            **intent_metadata,
        )
    local = request_local_decision(cleaned, context=local_context)
    if local.mode == "action":
        return VoiceIntent(
            transcript=cleaned,
            kind="local_action",
            title=local.summary,
            task=cleaned,
            route="local",
            actions=local.actions,
            source=local.source,
            confirmation_level=local.confirmation_level,
            **intent_metadata,
        )
    if local.mode == "conversation":
        return VoiceIntent(
            transcript=cleaned,
            kind="local_conversation",
            title=local.summary,
            task=cleaned,
            route="local",
            reply=local.reply,
            source=local.source,
            requires_confirmation=False,
            **intent_metadata,
        )
    if is_local_control_request(cleaned):
        return VoiceIntent(
            transcript=cleaned,
            kind="local_conversation",
            title="Clarify the local Mac control request",
            task=cleaned,
            route="local",
            reply=(
                "I understood this as a local window, app, or Chrome-tab command, "
                "but I could not identify a safe complete target and layout. Nothing "
                "was sent to ChatGPT and no screen scan was attempted."
            ),
            source=f"{local.source}_voice_guard",
            requires_confirmation=False,
            **intent_metadata,
        )
    return VoiceIntent(
        transcript=cleaned,
        kind="jarvis_request",
        title="Send this request to Jarvis",
        task=cleaned,
        route="auto",
        source=local.source,
        **intent_metadata,
    )


ResultT = TypeVar("ResultT")


def dispatch_voice_intent(
    intent: VoiceIntent,
    *,
    confirmed: bool,
    sender: Callable[[str, str], ResultT],
    window_sender: Callable[[str, str, str], ResultT] | None = None,
) -> ResultT | VoiceIntent:
    """Dispatch only after the native transcript-preview dialog was confirmed."""
    if intent.requires_confirmation and not confirmed:
        raise VoiceConfirmationRequired(
            "Review and confirm the transcript in Jarvis before it can be sent."
        )
    if intent.kind in {"local_action", "local_conversation"}:
        return intent
    if intent.kind == "scan_app_window":
        if window_sender is None or not intent.scan_target:
            raise RuntimeError("Jarvis's named-window scanner is unavailable.")
        return window_sender(intent.task, intent.scan_target, intent.route)
    return sender(intent.task, intent.route)


class PushToTalkState(str, Enum):
    IDLE = "idle"
    AUTHORIZING = "authorizing"
    RECORDING = "recording"
    TRANSCRIBING = "transcribing"
    PREVIEW = "preview"


class PushToTalkStateMachine:
    """Small testable model of the native push-to-talk lifecycle."""

    def __init__(self) -> None:
        self.state = PushToTalkState.IDLE

    def request_start(self) -> None:
        if self.state is not PushToTalkState.IDLE:
            raise RuntimeError(f"Cannot start voice input while {self.state.value}.")
        self.state = PushToTalkState.AUTHORIZING

    def permission_resolved(self, granted: bool) -> None:
        if self.state is not PushToTalkState.AUTHORIZING:
            raise RuntimeError("Voice permission was resolved outside authorization.")
        self.state = PushToTalkState.RECORDING if granted else PushToTalkState.IDLE

    def request_stop(self) -> None:
        if self.state is not PushToTalkState.RECORDING:
            raise RuntimeError("Voice input is not recording.")
        self.state = PushToTalkState.TRANSCRIBING

    def transcription_ready(self, transcript: str) -> None:
        if self.state is not PushToTalkState.TRANSCRIBING:
            raise RuntimeError("Voice input is not transcribing.")
        self.state = PushToTalkState.PREVIEW if transcript.strip() else PushToTalkState.IDLE

    def finish_preview(self) -> None:
        if self.state is not PushToTalkState.PREVIEW:
            raise RuntimeError("No voice preview is open.")
        self.state = PushToTalkState.IDLE

    def cancel(self) -> None:
        self.state = PushToTalkState.IDLE


def cleanup_stale_voice_artifacts(
    runtime_dir: Path = VOICE_RUNTIME_DIR,
    *,
    older_than_seconds: int = 3600,
    now: float | None = None,
) -> list[Path]:
    """Remove only old, known voice scratch files from Jarvis's voice directory."""
    if not runtime_dir.is_dir():
        return []
    cutoff = (time.time() if now is None else now) - max(0, older_than_seconds)
    removed: list[Path] = []
    for path in runtime_dir.iterdir():
        if (
            path.is_symlink()
            or not path.is_file()
            or not path.name.startswith("voice-")
            or path.suffix.casefold() not in VOICE_ARTIFACT_SUFFIXES
        ):
            continue
        try:
            if path.stat().st_mtime <= cutoff:
                path.unlink()
                removed.append(path)
        except FileNotFoundError:
            continue
    return removed
