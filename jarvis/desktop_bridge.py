from __future__ import annotations

import errno
import json
import select
import shutil
import socket
import struct
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from .config import (
    DATA_DIR,
    DESKTOP_THREADS_PATH,
    PRIVATE_FILE_MODE,
    ensure_dirs,
    installed_root,
    load_config,
)
from .awareness import handoff_context, prepare_handoff, update_handoff
from .context import build_context
from .screen import ScreenRead
from .trading_journal import create_review


WORK_APPS = {
    "Terminal",
    "Xcode",
    "Visual Studio Code",
    "Cursor",
    "PyCharm",
    "IntelliJ IDEA",
}

WORK_TERMS = {
    "build",
    "code",
    "debug",
    "develop",
    "edit file",
    "fix",
    "implement",
    "install",
    "project",
    "refactor",
    "repository",
    "script",
    "test",
    "update",
}

ROUTE_TITLES = {
    "chat": "Jarvis Chat — Screen Analysis",
    "work": "Jarvis Work — Build & Fix",
}


@dataclass(frozen=True)
class RouteDecision:
    destination: str
    workspace: Path
    model: str
    reasoning: str
    sandbox: str
    reason: str


@dataclass(frozen=True)
class DesktopResult:
    thread_id: str
    answer: str
    route: RouteDecision


IPC_SOCKET_PATH = Path.home() / ".codex" / "ipc" / "ipc.sock"
IPC_MAX_FRAME_BYTES = 256 * 1024 * 1024
IPC_CONNECT_RETRY_DELAYS = (0.10, 0.20, 0.35, 0.50, 0.75, 1.00, 1.00)


def _connect_live_desktop_ipc(
    retry_delays: tuple[float, ...] = IPC_CONNECT_RETRY_DELAYS,
) -> socket.socket:
    """Connect to ChatGPT, tolerating its short renderer-startup window."""
    retryable_errnos = {
        errno.EAGAIN,
        errno.ECONNREFUSED,
        errno.EINTR,
        errno.ENOENT,
        errno.ETIMEDOUT,
    }
    last_error: OSError | None = None
    for attempt in range(len(retry_delays) + 1):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(5)
        try:
            connection.connect(str(IPC_SOCKET_PATH))
            return connection
        except OSError as exc:
            connection.close()
            if not isinstance(exc, socket.timeout) and exc.errno not in retryable_errnos:
                raise
            last_error = exc
            if attempt < len(retry_delays):
                time.sleep(retry_delays[attempt])

    raise RuntimeError(
        "ChatGPT's live task connection is still starting or unavailable. "
        "Keep ChatGPT open and run the scan again."
    ) from last_error


def _send_ipc_message(connection: socket.socket, message: dict[str, object]) -> None:
    payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
    if len(payload) > IPC_MAX_FRAME_BYTES:
        raise RuntimeError("The Jarvis handoff is too large for ChatGPT.")
    connection.sendall(struct.pack("<I", len(payload)) + payload)


def _receive_exact(connection: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise RuntimeError("ChatGPT closed its live task connection.")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _receive_ipc_message(
    connection: socket.socket, deadline: float
) -> dict[str, object]:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("ChatGPT's live task connection did not respond in time.")
    connection.settimeout(remaining)
    try:
        header = _receive_exact(connection, 4)
        length = struct.unpack("<I", header)[0]
        if length > IPC_MAX_FRAME_BYTES:
            raise RuntimeError("ChatGPT returned an invalid live task response.")
        value = json.loads(_receive_exact(connection, length).decode("utf-8"))
    except socket.timeout as exc:
        raise TimeoutError(
            "ChatGPT's live task connection did not respond in time."
        ) from exc
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("ChatGPT returned an invalid live task response.") from exc
    if not isinstance(value, dict):
        raise RuntimeError("ChatGPT returned an invalid live task response.")
    return value


def _wait_for_ipc_response(
    connection: socket.socket, request_id: str, timeout: float
) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    while True:
        message = _receive_ipc_message(connection, deadline)
        if message.get("type") == "response" and message.get("requestId") == request_id:
            return message


def submit_to_live_desktop_thread(
    thread_id: str,
    package: str,
    screen: ScreenRead,
    route: RouteDecision,
) -> DesktopResult:
    """Submit through ChatGPT's live renderer so the open task updates immediately."""
    inputs: list[dict[str, object]] = [{"type": "text", "text": package}]
    for screenshot_path in screen.all_screenshot_paths():
        if not Path(screenshot_path).is_file():
            continue
        inputs.append({
            "type": "localImage",
            "path": str(Path(screenshot_path).resolve()),
        })

    with _connect_live_desktop_ipc() as connection:
        initialize_id = str(uuid.uuid4())
        _send_ipc_message(connection, {
            "type": "request",
            "requestId": initialize_id,
            "sourceClientId": "initializing-client",
            "version": 0,
            "method": "initialize",
            "params": {"clientType": "jarvis"},
        })
        initialized = _wait_for_ipc_response(connection, initialize_id, 5)
        if initialized.get("resultType") != "success":
            raise RuntimeError(
                f"ChatGPT rejected Jarvis's live connection: {initialized.get('error', 'unknown error')}"
            )
        initialize_result = initialized.get("result", {})
        client_id = (
            str(initialize_result.get("clientId", ""))
            if isinstance(initialize_result, dict)
            else ""
        )
        if not client_id:
            raise RuntimeError("ChatGPT did not identify Jarvis's live connection.")

        # The open task may need a moment to become the renderer's owner. A
        # no-client-found reply is safe to retry because no turn was started.
        for attempt in range(4):
            request_id = str(uuid.uuid4())
            _send_ipc_message(connection, {
                "type": "request",
                "requestId": request_id,
                "sourceClientId": client_id,
                "version": 1,
                "method": "thread-follower-start-turn",
                "params": {
                    "conversationId": thread_id,
                    "turnStartParams": {
                        "input": inputs,
                        "cwd": str(route.workspace),
                        "model": route.model,
                        "effort": route.reasoning,
                        "approvalPolicy": "on-request",
                        "clientUserMessageId": str(uuid.uuid4()),
                    },
                },
                "timeoutMs": 30000,
            })
            response = _wait_for_ipc_response(connection, request_id, 35)
            if response.get("resultType") == "success":
                return DesktopResult(
                    thread_id=thread_id,
                    answer="Submitted through ChatGPT's live task window.",
                    route=route,
                )
            error = str(response.get("error", "unknown error"))
            if error != "no-client-found" or attempt == 3:
                raise RuntimeError(f"ChatGPT rejected the visible Jarvis handoff: {error}")
            open_desktop_thread(thread_id)
            time.sleep(1.0)

    raise RuntimeError("ChatGPT did not accept the visible Jarvis handoff.")


def notify(message: str) -> None:
    script = (
        'on run argv\n'
        'display notification (item 1 of argv) with title "Jarvis"\n'
        'end run'
    )
    subprocess.run(
        ["/usr/bin/osascript", "-e", script, message],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )


def choose_route(task: str, screen: ScreenRead, requested: str = "auto") -> RouteDecision:
    cfg = load_config()
    lowered = task.lower()
    tradingview_active = screen.active_app.strip().lower() == "tradingview"
    work_score = sum(term in lowered for term in WORK_TERMS)
    if screen.active_app in WORK_APPS:
        work_score += 2

    if requested not in {"auto", "chat", "work"}:
        raise ValueError("Route must be auto, chat, or work.")
    destination = (
        requested
        if requested != "auto"
        else ("work" if tradingview_active or work_score else "chat")
    )

    if destination == "work":
        model = "gpt-5.6-sol"
        reasoning = "high"
    else:
        model = "gpt-5.6-terra"
        reasoning = "medium"

    workspace_value = cfg.work_workspace if destination == "work" else cfg.chat_workspace
    workspace = Path(workspace_value).expanduser()
    if not workspace.is_dir():
        workspace = installed_root() if destination == "work" else DATA_DIR
    if tradingview_active and destination == "work":
        reason = "TradingView detected; visual chart analysis routed to persistent Work task"
    elif destination == "work":
        reason = "coding app or implementation language detected"
    elif requested == "chat":
        reason = "explicit Chat route selected for conversation or one-shot app review"
    else:
        reason = "analysis, conversation, or screen-review task detected"
    return RouteDecision(
        destination=destination,
        workspace=workspace,
        model=model,
        reasoning=reasoning,
        sandbox="workspace-write" if destination == "work" else "read-only",
        reason=reason,
    )


def codex_binary() -> Path:
    candidates = [
        Path("/Applications/ChatGPT.app/Contents/Resources/codex"),
        Path("/Applications/Codex.app/Contents/Resources/codex"),
    ]
    found = shutil.which("codex")
    if found:
        candidates.append(Path(found))
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise RuntimeError("The ChatGPT desktop command service was not found.")


def _load_desktop_threads() -> dict[str, object]:
    if not DESKTOP_THREADS_PATH.exists():
        return {"version": 1, "routes": {}}
    try:
        value = json.loads(DESKTOP_THREADS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"version": 1, "routes": {}}
    if not isinstance(value, dict) or not isinstance(value.get("routes"), dict):
        return {"version": 1, "routes": {}}
    return value


def _saved_thread_id(route: RouteDecision) -> str:
    routes = _load_desktop_threads().get("routes", {})
    record = routes.get(route.destination, {}) if isinstance(routes, dict) else {}
    if not isinstance(record, dict):
        return ""
    if record.get("workspace") != str(route.workspace):
        return ""
    if record.get("sandbox") != route.sandbox:
        return ""
    value = record.get("thread_id", "")
    return value if isinstance(value, str) else ""


def _save_thread_id(route: RouteDecision, thread_id: str) -> None:
    ensure_dirs()
    value = _load_desktop_threads()
    routes = value.setdefault("routes", {})
    if not isinstance(routes, dict):
        routes = {}
        value["routes"] = routes
    routes[route.destination] = {
        "thread_id": thread_id,
        "workspace": str(route.workspace),
        "sandbox": route.sandbox,
    }
    temporary = DESKTOP_THREADS_PATH.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")
    temporary.chmod(PRIVATE_FILE_MODE)
    temporary.replace(DESKTOP_THREADS_PATH)
    DESKTOP_THREADS_PATH.chmod(PRIVATE_FILE_MODE)


def set_desktop_thread_name(thread_id: str, name: str) -> None:
    """Set a persisted ChatGPT task name through the bundled app service."""
    process = subprocess.Popen(
        [str(codex_binary()), "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    if process.stdin is None or process.stdout is None:
        raise RuntimeError("Could not connect to ChatGPT's local task service.")

    def send(message: dict[str, object]) -> None:
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()

    def wait_for(request_id: int) -> dict[str, object]:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            ready, _, _ = select.select(
                [process.stdout], [], [], max(0, deadline - time.monotonic())
            )
            if not ready:
                break
            line = process.stdout.readline()
            if not line:
                break
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if value.get("id") == request_id:
                return value
        raise RuntimeError("ChatGPT did not confirm the task name in time.")

    try:
        send({
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "jarvis-local",
                    "title": "Jarvis Local",
                    "version": "1.0.0",
                }
            },
        })
        initialized = wait_for(1)
        if initialized.get("error"):
            raise RuntimeError(str(initialized["error"])[-1000:])

        send({"method": "initialized", "params": {}})
        send({
            "id": 2,
            "method": "thread/name/set",
            "params": {"threadId": thread_id, "name": name},
        })
        renamed = wait_for(2)
        if renamed.get("error"):
            raise RuntimeError(str(renamed["error"])[-1000:])
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def _codex_command(
    screen: ScreenRead,
    route: RouteDecision,
    thread_id: str = "",
) -> list[str]:
    command = [
        str(codex_binary()),
        "exec",
        "--json",
        "--skip-git-repo-check",
        "-s",
        route.sandbox,
        "-C",
        str(route.workspace),
        "-m",
        route.model,
        "-c",
        f'model_reasoning_effort="{route.reasoning}"',
    ]
    if thread_id:
        command.append("resume")
    for screenshot_path in screen.all_screenshot_paths():
        if Path(screenshot_path).is_file():
            command.extend(["-i", screenshot_path])
    if thread_id:
        command.append(thread_id)
    command.append("-")
    return command


def _run_codex(
    command: list[str],
    package: str,
    timeout: int,
    existing_thread_id: str = "",
) -> tuple[subprocess.CompletedProcess[str], str, str, bool]:
    result = subprocess.run(
        command,
        input=package,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    thread_id = existing_thread_id
    answer = ""
    thread_started = False
    for line in result.stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "thread.started":
            thread_id = str(event.get("thread_id", ""))
            thread_started = bool(thread_id)
        item = event.get("item", {})
        if event.get("type") == "item.completed" and item.get("type") == "agent_message":
            answer = str(item.get("text", ""))
    return result, thread_id, answer, thread_started


def run_desktop_task(package: str, screen: ScreenRead, route: RouteDecision) -> DesktopResult:
    cfg = load_config()
    saved_thread_id = _saved_thread_id(route)
    result, thread_id, answer, thread_started = _run_codex(
        _codex_command(screen, route, saved_thread_id),
        package,
        cfg.desktop_task_timeout_seconds,
        saved_thread_id,
    )

    # A removed or unavailable saved thread is replaced once. If a resumed thread
    # actually started and then failed, preserve that error instead of duplicating
    # the user's request in a new conversation.
    if saved_thread_id and result.returncode != 0 and not thread_started:
        result, thread_id, answer, thread_started = _run_codex(
            _codex_command(screen, route),
            package,
            cfg.desktop_task_timeout_seconds,
        )

    if result.returncode != 0 or not thread_id:
        detail = result.stderr.strip() or result.stdout.strip() or "Unknown desktop task error."
        raise RuntimeError(detail[-2000:])
    _save_thread_id(route, thread_id)
    return DesktopResult(thread_id=thread_id, answer=answer, route=route)


def open_desktop_thread(thread_id: str) -> bool:
    cfg = load_config()
    app_path = Path(cfg.desktop_app_path).expanduser()
    if not app_path.exists():
        raise RuntimeError(f"ChatGPT desktop app was not found at {app_path}.")
    subprocess.run(
        ["/usr/bin/open", "-a", str(app_path), f"codex://threads/{thread_id}"],
        text=True,
        capture_output=True,
        timeout=15,
        check=True,
    )
    return True


def refresh_desktop_thread(thread_id: str) -> None:
    """Force ChatGPT to reload a task that was completed by the local command service."""
    routes = _load_desktop_threads().get("routes", {})
    other_thread_id = ""
    if isinstance(routes, dict):
        for record in routes.values():
            if not isinstance(record, dict):
                continue
            candidate = record.get("thread_id", "")
            if isinstance(candidate, str) and candidate and candidate != thread_id:
                other_thread_id = candidate
                break
    if other_thread_id:
        open_desktop_thread(other_thread_id)
        time.sleep(0.8)
    open_desktop_thread(thread_id)


def screen_capture_failure(screen: ScreenRead) -> str | None:
    if screen.all_screenshot_paths():
        return None
    method = screen.method.casefold()
    detail = screen.text.casefold()
    named_capture = "named-capture" in method
    permission_failure = any(
        phrase in detail
        for phrase in (
            "not authorized",
            "permission",
            "screen recording",
            "screen & system audio recording",
            "declined tcc",
        )
    )
    if named_capture and not permission_failure and (
        "capture-error" in method or "capture-timeout" in method
    ):
        return screen.text
    if "capture-error" in method or "capture-timeout" in method or "screen recording permission" in detail:
        scope = "the requested app window" if named_capture else "the active window"
        return (
            f"Jarvis could not scan {scope} because Screen Recording permission "
            "is unavailable. Enable Jarvis in System Settings → Privacy & Security → "
            "Screen & System Audio Recording, fully quit Jarvis, and reopen it."
        )
    return None


def ask_jarvis(
    task: str,
    requested_route: str = "auto",
    *,
    screenshot_paths: list[str] | None = None,
    target_app: str | None = None,
) -> DesktopResult:
    if target_app:
        notify(f"Reading one {target_app} window without bringing it forward.")
    else:
        notify("Reading the active window and gathering memory.")
    package, screen = build_context(
        task,
        screenshot_paths=screenshot_paths,
        target_app=target_app,
    )
    capture_failure = screen_capture_failure(screen)
    if capture_failure:
        notify(capture_failure)
        raise RuntimeError(capture_failure)
    route = choose_route(task, screen, requested_route)
    tradingview_active = screen.active_app.strip().lower() == "tradingview"
    captured_paths = screen.all_screenshot_paths()
    if tradingview_active and (
        not captured_paths or not all(Path(path).is_file() for path in captured_paths)
    ):
        message = "TradingView was detected, but its chart screenshot was not captured."
        notify(message)
        raise RuntimeError(message)
    trading_review_id = ""
    if tradingview_active and load_config().trading_journal_enabled:
        inferred_timeframes = (
            [5, 15, 60, 240] if len(captured_paths) == 4 else []
        )
        trading_review_id = create_review(
            captured_paths,
            timeframes=inferred_timeframes,
            metadata={
                "target_app": target_app or "",
                "requested_route": requested_route,
                "capture_method": screen.method,
                "analysis_only": True,
            },
        )
    intent = prepare_handoff(
        task,
        active_app=screen.active_app,
        destination=route.destination,
        model=route.model,
    )
    routing_note = (
        f"\n\nJARVIS ROUTING\n"
        f"Destination: {route.destination.title()}\n"
        f"Model: {route.model}\n"
        f"Reasoning: {route.reasoning}\n"
        f"Workspace: {route.workspace}\n"
        f"Reason: {route.reason}\n\n"
        f"{handoff_context(intent, active_app=screen.active_app)}"
    )
    if tradingview_active:
        screenshot_list = "\n".join(f"- {path}" for path in captured_paths)
        if target_app:
            routing_note += (
                "\n\nJARVIS ONE-SHOT TRADINGVIEW VISUAL ANALYSIS\n"
                "Use the attached single screenshot as primary evidence and OCR as secondary. "
                "Analyze only what is visible in this one window; do not imply that other "
                "timeframes were scanned. State the visible chart bias, supporting and opposing "
                "evidence, key levels, and invalidation. State missing context instead of "
                "guessing. Decision support only: do not place, modify, or close a trade.\n"
                f"Captured screenshot:\n{screenshot_list}"
            )
        else:
            routing_note += (
                "\n\nJARVIS TRADINGVIEW VISUAL ANALYSIS\n"
                "Before answering, use view_image on every exact screenshot below:\n"
                f"{screenshot_list}\n"
                "Treat the screenshots themselves as primary evidence and OCR as secondary. "
                "Analyze the visible candles and market structure, state the directional bias, "
                "identify the evidence for and against that bias, and give a clear invalidation. "
                "For a multi-timeframe MGC review, confirm both MGC and DXY are visible in each "
                "image; use DXY rejection or acceptance as confluence, use the 1-hour and 4-hour "
                "views for structure, and use the fitted 5-minute view for the full New York "
                "session through developing Asia. Use relevant saved Asia-gold confluences. "
                "State any missing timeframe or context instead of guessing. This is decision "
                "support only: do not place, modify, or close a trade."
            )
        if trading_review_id:
            routing_note += (
                "\n\nJARVIS ANALYSIS JOURNAL\n"
                f"Review ID: {trading_review_id}\n"
                "This local journal entry is analysis-only. Include the review ID in "
                "your answer so bias, levels, invalidation, and later outcome can be "
                "attached without any trading execution."
            )
    elif target_app:
        screenshot_list = "\n".join(f"- {path}" for path in captured_paths)
        routing_note += (
            "\n\nJARVIS ONE-SHOT NAMED-WINDOW ANALYSIS\n"
            "Use the attached single screenshot as primary evidence and OCR as secondary. "
            "Analyze only this captured app window and do not claim that any other window was "
            "scanned. State anything important that is obscured or unavailable instead of "
            "guessing.\n"
            f"Captured screenshot:\n{screenshot_list}"
        )
    notify(f"Jarvis is thinking in {route.destination.title()} mode.")
    try:
        prompt = package + routing_note
        thread_id = _saved_thread_id(route)
        if thread_id:
            open_desktop_thread(thread_id)
            # Send through ChatGPT's connected renderer. Starting a separate
            # app-server process persists turns but does not make them visible in
            # the already-open desktop task.
            result = submit_to_live_desktop_thread(thread_id, prompt, screen, route)
        else:
            # The first request creates the persistent route task. Later requests
            # use ChatGPT's live renderer so they never depend on UI scripting.
            result = run_desktop_task(prompt, screen, route)
            try:
                set_desktop_thread_name(result.thread_id, ROUTE_TITLES[route.destination])
            except Exception:
                # Naming is cosmetic and must never block answer delivery.
                pass
            open_desktop_thread(result.thread_id)
    except Exception as exc:
        update_handoff(
            intent.correlation_id,
            status="failed",
            review_id=trading_review_id,
            result_summary=str(exc),
        )
        notify(f"Jarvis could not finish: {str(exc)[:140]}")
        raise
    answer = result.answer.strip()
    result_status = (
        "submitted"
        if not answer or answer.casefold().startswith("submitted")
        else "completed"
    )
    update_handoff(
        intent.correlation_id,
        status=result_status,
        thread_id=result.thread_id,
        review_id=trading_review_id,
        result_summary=answer,
    )
    if thread_id:
        notify(f"Sent to the same Jarvis {route.destination.title()} task.")
    else:
        notify(f"Created the persistent Jarvis {route.destination.title()} task.")
    return result


def ask_named_app_window(
    task: str,
    target_app: str,
    requested_route: str = "auto",
) -> DesktopResult:
    """Scan one named running app and enforce the Chat/TradingView route policy."""
    target = target_app.strip()
    if not target:
        raise ValueError("A named-window scan requires an application name.")
    tradingview_aliases = {
        "trading few",
        "trading view",
        "trading you",
        "tradingview",
        "treating you",
    }
    if target.casefold() in tradingview_aliases:
        target = "TradingView"
    required_route = "work" if target == "TradingView" else "chat"
    if requested_route not in {"auto", required_route}:
        raise ValueError(
            f"{target or 'This app'} must route to Jarvis {required_route.title()} "
            "for a one-shot named-window scan."
        )
    return ask_jarvis(task, required_route, target_app=target)
