from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class AppAdapter:
    name: str
    bundle_ids: tuple[str, ...]
    capabilities: tuple[str, ...]
    preferred_read_order: tuple[str, ...]
    mutating_control: str

    def to_dict(self) -> dict[str, object]:
        return {
            "name": self.name,
            "bundle_ids": list(self.bundle_ids),
            "capabilities": list(self.capabilities),
            "preferred_read_order": list(self.preferred_read_order),
            "mutating_control": self.mutating_control,
        }


ADAPTERS = {
    "tradingview": AppAdapter(
        "TradingView",
        ("com.tradingview.tradingviewapp.desktop",),
        (
            "named_window_capture",
            "accessibility_chart_state",
            "four_timeframe_review",
            "state_restoration",
            "journal",
        ),
        ("accessibility", "screen_capture", "ocr", "visual_fallback"),
        "guarded_native_workflow",
    ),
    "google chrome": AppAdapter(
        "Google Chrome",
        ("com.google.Chrome",),
        ("named_window_capture", "approved_profile_urls", "tab_control"),
        ("accessibility", "screen_capture", "ocr", "visual_fallback"),
        "approved_profile_adapter",
    ),
    "finder": AppAdapter(
        "Finder",
        ("com.apple.finder",),
        ("reveal", "open", "move", "trash", "project_scope"),
        ("native_api", "accessibility", "ocr"),
        "confirmed_filesystem",
    ),
    "system settings": AppAdapter(
        "System Settings",
        ("com.apple.systempreferences",),
        ("open_pane", "permission_status"),
        ("native_url", "accessibility", "ocr"),
        "confirmed_settings",
    ),
    "notes": AppAdapter(
        "Notes",
        ("com.apple.Notes",),
        ("search", "quick_capture", "append"),
        ("app_intent", "shortcut", "accessibility"),
        "confirmed_native_intent",
    ),
    "mail": AppAdapter(
        "Mail",
        ("com.apple.mail",),
        ("search", "summarize", "draft"),
        ("native_store", "app_intent", "accessibility"),
        "draft_only_until_send_confirmation",
    ),
    "calendar": AppAdapter(
        "Calendar",
        ("com.apple.iCal",),
        ("agenda", "conflict_check", "event_proposal"),
        ("eventkit", "app_intent", "accessibility"),
        "proposal_until_confirmation",
    ),
    "terminal": AppAdapter(
        "Terminal",
        ("com.apple.Terminal",),
        ("read_visible_output", "work_handoff"),
        ("accessibility", "screen_capture", "ocr"),
        "work_handoff",
    ),
    "codex": AppAdapter(
        "Codex",
        ("com.openai.codex",),
        ("task_handoff", "read_visible_output"),
        ("connected_task", "accessibility", "screen_capture"),
        "connected_task",
    ),
    "chatgpt": AppAdapter(
        "ChatGPT",
        ("com.openai.chat",),
        ("chat_handoff", "work_handoff"),
        ("connected_task", "accessibility"),
        "connected_task",
    ),
}


def adapter_for_app(name: str) -> AppAdapter | None:
    cleaned = name.strip().casefold()
    return ADAPTERS.get(cleaned)


def adapter_status() -> list[dict[str, object]]:
    return [adapter.to_dict() for adapter in ADAPTERS.values()]
