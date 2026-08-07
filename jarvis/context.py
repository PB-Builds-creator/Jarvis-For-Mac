from __future__ import annotations

import subprocess
import textwrap

from .awareness import handoff_purpose, infer_goal
from .config import load_config, safe_owner_name
from .memory import search_memories, utc_now
from .privacy import redact_for_cloud, require_cloud_handoff_allowed
from .screen import (
    ScreenRead,
    read_active_window,
    read_named_app_window,
    read_supplied_tradingview_screenshots,
)


def copy_to_clipboard(text: str) -> None:
    proc = subprocess.run(["/usr/bin/pbcopy"], input=text, text=True, capture_output=True, timeout=10)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "Could not copy context to clipboard.")


def open_chatgpt_project() -> None:
    cfg = load_config()
    subprocess.run(["/usr/bin/open", cfg.project_url], check=False, timeout=10)


def build_context(
    task: str = "Analyze the active window and recommend next steps.",
    *,
    screenshot_paths: list[str] | None = None,
    target_app: str | None = None,
) -> tuple[str, ScreenRead]:
    cfg = load_config()
    owner = safe_owner_name(cfg.owner_name)
    owner_possessive = owner + ("'" if owner.casefold().endswith("s") else "'s")
    require_cloud_handoff_allowed()
    if screenshot_paths and target_app:
        raise ValueError("A named-app scan cannot also use supplied screenshots.")
    if screenshot_paths:
        screen = read_supplied_tradingview_screenshots(screenshot_paths)
    elif target_app:
        screen = read_named_app_window(target_app)
    else:
        screen = read_active_window()
    named_scope = bool(target_app)
    app_label = "Captured app" if named_scope else "Active app"
    window_label = "Captured window" if named_scope else "Active window"
    scope_text = (
        "One requested app window, captured directly without activating that app."
        if named_scope
        else "The active window."
    )
    memory_query = f"{task} {screen.active_app} {screen.window_title} {screen.text[:1000]}"
    memories = search_memories(memory_query, limit=10, include_private=False)
    memory_text = "\n".join(
        f"- [{item['category']}] {item['title']}: {item['body']}" for item in memories
    )
    inferred_goal = infer_goal(task, active_app=screen.active_app)
    purpose = handoff_purpose(
        task,
        active_app=screen.active_app,
        destination="auto",
    )
    package = f"""
    JARVIS LOCAL CONTEXT PACKAGE
    Created: {utc_now()}

    Current task:
    {task}

    {owner_possessive} intended outcome:
    {inferred_goal}

    Why this is being sent to ChatGPT:
    {purpose}

    Role:
    You are Jarvis, {owner_possessive} persistent personal AI. Be calm, direct, observant,
    and practical. Use the supplied screen evidence and memory before answering.

    Capture scope:
    {scope_text}

    {app_label}:
    {screen.active_app}

    {window_label}:
    {screen.window_title or "Unknown"}

    Screen reading method:
    {screen.method}

    Captured screenshot files:
    {chr(10).join(screen.all_screenshot_paths()) or "No screenshot was captured."}

    Visible captured-window text:
    {screen.text}

    Relevant local memory:
    {memory_text or "No local memories found."}

    Restrictions:
    - Do not claim actions succeeded unless verified.
    - Do not place, modify, or close financial trades.
    - Never send messages, delete files, install software, change security settings,
      expose private information, or perform difficult-to-reverse actions without
      {owner_possessive} explicit confirmation at that moment.
    - File edits inside the selected Work workspace are allowed when the task clearly
      requests implementation. Preserve unrelated user changes and verify your work.
    - If other Mac control is needed, return a short action queue plan for local Jarvis.

    Suggested response format:
    1. Observed facts
    2. Interpretation
    3. Recommended next step
    4. Optional Jarvis action queue items
    """
    cleaned = textwrap.dedent(package).strip()
    if len(cleaned) > cfg.max_context_chars:
        cleaned = cleaned[: cfg.max_context_chars] + "\n\n[Context trimmed by Jarvis local limit.]"
    if cfg.redact_cloud_handoffs:
        cleaned = redact_for_cloud(cleaned).text
    return cleaned, screen


def prepare_context(task: str = "Analyze the active window and recommend next steps.") -> str:
    cleaned, _ = build_context(task)
    copy_to_clipboard(cleaned)
    open_chatgpt_project()
    return cleaned
