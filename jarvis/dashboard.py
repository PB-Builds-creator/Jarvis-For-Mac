from __future__ import annotations

import html
import hmac
import ipaddress
import json
import os
import threading
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import __version__
from .actions import approve_action, execute_action, list_actions, queue_action
from .awareness import awareness_status
from .config import load_config, save_config
from .context import prepare_context
from .events import list_event_rules, seed_default_event_rules
from .health import health_snapshot
from .local_model import ENGINE
from .memory import (
    add_memory,
    consolidate_memories,
    export_memory,
    import_memory,
    list_timeline,
    memory_stats,
    search_memories,
)
from .project_index import index_projects, project_index_status
from .routines import list_routines
from .screen import read_active_window


DASHBOARD_TOKEN_ENV = "JARVIS_DASHBOARD_TOKEN"
SESSION_COOKIE_NAME = "jarvis_session"
MAX_FORM_BYTES = 65_536


STYLE = """
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;background:#101418;color:#eef2f5}
header{padding:18px 24px;background:#171d23;border-bottom:1px solid #29333d}
main{padding:20px;max-width:1120px;margin:0 auto}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
section{background:#171d23;border:1px solid #29333d;border-radius:8px;padding:16px}
button,input,textarea,select{font:inherit}
button{background:#2d7df0;color:white;border:0;border-radius:6px;padding:9px 12px;cursor:pointer;margin:4px 4px 4px 0}
button.secondary{background:#33404c}
button.warn{background:#a96b00}
input,textarea,select{width:100%;box-sizing:border-box;background:#0d1115;color:#eef2f5;border:1px solid #34414d;border-radius:6px;padding:9px;margin:6px 0 10px}
textarea{min-height:130px}
pre{white-space:pre-wrap;background:#0d1115;border:1px solid #2d3842;border-radius:6px;padding:12px;max-height:420px;overflow:auto}
.muted{color:#a7b2bd}.pill{display:inline-block;padding:3px 7px;border-radius:999px;background:#26313a;color:#cdd6df;font-size:12px}
@media(max-width:800px){.grid{grid-template-columns:1fr}}
"""


def page(content: str) -> bytes:
    return f"<!doctype html><html><head><meta charset='utf-8'><title>Jarvis</title><style>{STYLE}</style></head><body><header><h2>Jarvis <span class='pill'>No-API Bridge v{__version__}</span></h2><div class='muted'>ChatGPT is the brain. This Mac app is the eyes, hands, memory, and safety layer.</div></header><main>{content}</main></body></html>".encode()


class Handler(BaseHTTPRequestHandler):
    server_version = "Jarvis"
    sys_version = ""

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(10.0)

    def _send(
        self,
        body: bytes,
        status: int = 200,
        content_type: str = "text/html; charset=utf-8",
        *,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; "
            "frame-ancestors 'none'; base-uri 'none'",
        )
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, value: object, status: int = 200) -> None:
        self._send(
            json.dumps(value, sort_keys=True).encode("utf-8"),
            status,
            "application/json; charset=utf-8",
        )

    @property
    def _token(self) -> str:
        return str(getattr(self.server, "jarvis_token", ""))

    def _token_matches(self, candidate: str) -> bool:
        return bool(candidate) and hmac.compare_digest(candidate, self._token)

    def _is_loopback_client(self) -> bool:
        try:
            return ipaddress.ip_address(self.client_address[0]).is_loopback
        except ValueError:
            return False

    def _host_is_allowed(self) -> bool:
        port = int(self.server.server_address[1])
        expected = {f"127.0.0.1:{port}", f"localhost:{port}"}
        return self.headers.get("Host", "").casefold() in expected

    def _cookie_token(self) -> str:
        raw = self.headers.get("Cookie", "")
        if not raw:
            return ""
        cookie = SimpleCookie()
        try:
            cookie.load(raw)
        except Exception:
            return ""
        morsel = cookie.get(SESSION_COOKIE_NAME)
        return morsel.value if morsel is not None else ""

    def _header_is_authorized(self) -> bool:
        return self._token_matches(self.headers.get("X-Jarvis-Token", ""))

    def _cookie_is_authorized(self) -> bool:
        return self._token_matches(self._cookie_token())

    def _origin_is_local(self) -> bool:
        port = int(self.server.server_address[1])
        allowed = {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}
        origin = self.headers.get("Origin", "").rstrip("/").casefold()
        if origin:
            return origin in allowed
        referer = self.headers.get("Referer", "").casefold()
        return any(referer.startswith(value + "/") for value in allowed)

    def _bootstrap_session(self, parsed) -> bool:
        if parsed.path != "/":
            return False
        supplied = parse_qs(parsed.query).get("token", [""])[0]
        if not self._token_matches(supplied):
            return False
        self._send(
            b"",
            303,
            headers={
                "Location": "/",
                "Set-Cookie": (
                    f"{SESSION_COOKIE_NAME}={self._token}; Path=/; "
                    "HttpOnly; SameSite=Strict"
                ),
            },
        )
        return True

    def _require_access(self, parsed, *, mutation: bool = False) -> bool:
        if not self._is_loopback_client():
            self._send(b"Forbidden", 403, "text/plain; charset=utf-8")
            return False
        if not self._host_is_allowed():
            self._send(b"Misdirected request", 421, "text/plain; charset=utf-8")
            return False
        if self._bootstrap_session(parsed):
            return False
        header_authorized = self._header_is_authorized()
        cookie_authorized = self._cookie_is_authorized()
        if not header_authorized and not cookie_authorized:
            self._send(b"Unauthorized", 401, "text/plain; charset=utf-8")
            return False
        if mutation and not header_authorized and not self._origin_is_local():
            self._send(b"Forbidden", 403, "text/plain; charset=utf-8")
            return False
        return True

    def _content_length(
        self,
        maximum: int = MAX_FORM_BYTES,
        *,
        allow_empty: bool = False,
    ) -> int | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(b"Invalid Content-Length", 400, "text/plain; charset=utf-8")
            return None
        if length < 0 or length > maximum or (length == 0 and not allow_empty):
            self._send(b"Invalid request size", 413, "text/plain; charset=utf-8")
            return None
        return length

    def _redirect_home(self) -> None:
        self._send(b"", 303, headers={"Location": "/"})

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if not self._require_access(parsed):
            return
        if parsed.path == "/":
            self._send(page(home()))
            return
        if parsed.path == "/api/local-ai/status":
            self._send_json(ENGINE.status())
            return
        if parsed.path == "/api/health":
            self._send_json(health_snapshot(include_adapters=True))
            return
        if parsed.path == "/api/timeline":
            self._send_json(list_timeline(200))
            return
        if parsed.path == "/read":
            read = read_active_window()
            body = f"<h3>Active Window</h3><pre>{html.escape(json.dumps(read.__dict__, indent=2))}</pre><p><a href='/'>Back</a></p>"
            self._send(page(body))
            return
        self._send(b"Not found", 404, "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if not self._require_access(parsed, mutation=True):
            return
        maximum = 32_768 if parsed.path == "/api/local-ai" else MAX_FORM_BYTES
        empty_allowed = {
            "/export",
            "/consolidate",
            "/index-projects",
        }
        length = self._content_length(
            maximum,
            allow_empty=parsed.path in empty_allowed,
        )
        if length is None:
            return
        if parsed.path == "/api/local-ai":
            try:
                value = json.loads(self.rfile.read(length).decode("utf-8"))
                transcript = str(value.get("transcript", "")).strip()
                context = str(value.get("context", "")).strip()[:14_000]
                if not transcript:
                    raise ValueError("A transcript is required.")
                self._send_json(ENGINE.decide(transcript, context=context).to_dict())
            except Exception as exc:
                self._send_json({"error": str(exc)[:1000]}, 503)
            return
        data = self.rfile.read(length).decode("utf-8") if length else ""
        form = {key: values[0] for key, values in parse_qs(data).items()}
        if parsed.path == "/prepare":
            task = form.get("task", "Analyze the active window and recommend next steps.")
            context = prepare_context(task)
            body = "<h3>Prepared For ChatGPT</h3><p>The context was copied to your clipboard and ChatGPT was opened.</p>"
            body += f"<pre>{html.escape(context)}</pre><p><a href='/'>Back</a></p>"
            self._send(page(body))
            return
        if parsed.path == "/export":
            out = export_memory()
            self._send(page(f"<h3>Memory Exported</h3><p>{html.escape(str(out))}</p><p><a href='/'>Back</a></p>"))
            return
        if parsed.path == "/consolidate":
            result = consolidate_memories()
            self._send(page(
                "<h3>Memory Consolidated</h3>"
                f"<pre>{html.escape(json.dumps(result, indent=2))}</pre>"
                "<p><a href='/'>Back</a></p>"
            ))
            return
        if parsed.path == "/index-projects":
            result = index_projects()
            self._send(page(
                "<h3>Project Index Updated</h3>"
                f"<pre>{html.escape(json.dumps(result, indent=2))}</pre>"
                "<p><a href='/'>Back</a></p>"
            ))
            return
        if parsed.path in {"/approve", "/run"}:
            try:
                action_id = int(form.get("id", "0"))
            except ValueError:
                self._send(b"Invalid action id", 400, "text/plain; charset=utf-8")
                return
            if parsed.path == "/approve":
                ok = approve_action(action_id)
                self._send(page(f"<p>{'Approved' if ok else 'Could not approve'} action {action_id}.</p><p><a href='/'>Back</a></p>"))
                return
            try:
                result = execute_action(action_id)
            except Exception as exc:
                result = f"Could not run action: {exc}"
            self._send(page(f"<pre>{html.escape(result)}</pre><p><a href='/'>Back</a></p>"))
            return
        if parsed.path == "/memory":
            add_memory(form.get("category", "note"), form.get("title", "Untitled"), form.get("body", ""))
        elif parsed.path == "/config":
            cfg = load_config()
            cfg.project_url = form.get("project_url", cfg.project_url)
            if "private_mode" in form:
                cfg.private_mode = form["private_mode"] == "on"
            save_config(cfg)
        elif parsed.path == "/import":
            import_memory(Path(form.get("path", "")))
        elif parsed.path == "/queue":
            payload = {}
            raw_payload = form.get("payload", "{}")
            try:
                payload = json.loads(raw_payload)
            except Exception:
                payload = {"text": raw_payload}
            queue_action(form.get("action_type", "copy_to_clipboard"), payload, form.get("reason", ""))
        else:
            self._send(b"Not found", 404, "text/plain; charset=utf-8")
            return
        self._redirect_home()

    def log_message(self, format: str, *args) -> None:
        return


def home() -> str:
    cfg = load_config()
    local_status = ENGINE.status()
    if local_status["loaded"]:
        local_state = f"{str(local_status['loaded_tier']).upper()} loaded"
    elif local_status["small_installed"] and local_status["large_installed"]:
        local_state = "4B + 9B ready"
    elif local_status["small_installed"]:
        local_state = "4B ready"
    else:
        local_state = "Not installed"
    memories = search_memories("", 8)
    actions = list_actions()
    stats = memory_stats()
    timeline = list_timeline(18)
    routines = list_routines()
    rules = list_event_rules()
    project_status = project_index_status()
    awareness = awareness_status()
    latest_intent = awareness.get("latest_intent") or {}
    latest_goal = html.escape(
        str(latest_intent.get("inferred_goal") or "Ready for the next objective.")
    )
    action_rows = "".join(
        f"<tr><td>{a['id']}</td><td>{html.escape(a['action_type'])}</td>"
        f"<td>{html.escape(a['risk_level'])}</td><td>{html.escape(a['status'])}</td>"
        f"<td><form action='/approve' method='post' style='display:inline'>"
        f"<input type='hidden' name='id' value='{a['id']}'><button type='submit'>Approve</button>"
        f"</form><form action='/run' method='post' style='display:inline'>"
        f"<input type='hidden' name='id' value='{a['id']}'><button type='submit'>Run</button>"
        f"</form></td></tr>"
        for a in actions[:20]
    )
    mem_rows = "".join(f"<li><b>{html.escape(m['title'])}</b> <span class='muted'>{html.escape(m['category'])}</span><br>{html.escape(m['body'])}</li>" for m in memories)
    timeline_rows = "".join(
        f"<li><b>{html.escape(item['summary'])}</b> "
        f"<span class='muted'>{html.escape(item['event_type'])} • "
        f"{html.escape(item['created_at'])}</span></li>"
        for item in timeline
    )
    routine_rows = "".join(
        f"<li><b>{html.escape(item['name'])}</b> "
        f"<span class='muted'>v{item['current_version']}</span><br>"
        f"{html.escape(item['description'])}</li>"
        for item in routines
    )
    rule_rows = "".join(
        f"<li><b>{html.escape(item['name'])}</b> "
        f"<span class='muted'>{html.escape(item['trigger_type'])} → "
        f"{html.escape(item['risk_policy'])}</span></li>"
        for item in rules
    )
    return f"""
    <div class="grid">
      <section>
        <h3>ChatGPT Bridge</h3>
        <form action="/prepare" method="post">
          <label>Task for Jarvis Project</label>
          <textarea name="task">Analyze the active window and recommend next steps.</textarea>
          <button type="submit">Prepare For ChatGPT</button>
          <a href="/read"><button type="button" class="secondary">Read Active Window</button></a>
        </form>
      </section>
      <section>
        <h3>Settings</h3>
        <p><b>Local navigation AI:</b> {html.escape(local_state)}</p>
        <p class="muted">Instant rules handle common commands. Qwen3.5 4B handles light requests, and 9B is selected locally for dependent multi-step navigation. Models load on demand and release memory after inactivity.</p>
        <form action="/config" method="post">
          <label>ChatGPT Project URL</label>
          <input name="project_url" value="{html.escape(cfg.project_url)}">
          <label>Private Mode</label>
          <select name="private_mode">
            <option value="off" {'selected' if not cfg.private_mode else ''}>Off — desktop handoff available</option>
            <option value="on" {'selected' if cfg.private_mode else ''}>On — fully local</option>
          </select>
          <button type="submit">Save</button>
        </form>
        <p><a href="/api/health">Open complete machine-readable health report</a></p>
      </section>
      <section>
        <h3>Operational Awareness</h3>
        <p><b>Current objective:</b> {latest_goal}</p>
        <p><b>Strategy:</b> {awareness['strategy_memory_count']} saved strategy memories</p>
        <p><b>Conversation:</b> {awareness['short_term_conversation_turns']} locally searchable turns of {awareness['conversation_retention_turns']}</p>
        <p><b>Deep reasoning:</b> {'On' if awareness['deep_conversation_enabled'] else 'Off'} • {html.escape(str(awareness['conversation_engine']))}</p>
        <p class="muted">Relevant earlier dialogue and durable memory are retrieved on demand. Heavy models unload after inactivity and local conversation text is not automatically included in cloud handoffs.</p>
      </section>
      <section>
        <h3>Memory</h3>
        <form action="/export" method="post">
          <button type="submit" class="secondary">Export Memory</button>
        </form>
        <form action="/consolidate" method="post">
          <button type="submit" class="secondary">Consolidate Memory</button>
        </form>
        <p class="muted">{stats['active']} active memories • {stats['private']} private</p>
        <form action="/import" method="post">
          <input name="path" placeholder="~/Jarvis/Information/Memory Exports/file.json">
          <button type="submit" class="secondary">Import Memory</button>
        </form>
        <form action="/memory" method="post">
          <input name="category" placeholder="category">
          <input name="title" placeholder="title">
          <textarea name="body" placeholder="memory text"></textarea>
          <button type="submit">Add Memory</button>
        </form>
        <ul>{mem_rows}</ul>
      </section>
      <section>
        <h3>Activity Timeline</h3>
        <p class="muted">What Jarvis heard, planned, changed, verified, or could not complete.</p>
        <ul>{timeline_rows or '<li>No recorded activity yet.</li>'}</ul>
      </section>
      <section>
        <h3>Routines and Proactive Rules</h3>
        <h4>Routines</h4>
        <ul>{routine_rows or '<li>No saved routines yet.</li>'}</ul>
        <h4>Rules</h4>
        <ul>{rule_rows or '<li>No proactive rules yet.</li>'}</ul>
      </section>
      <section>
        <h3>Local Project Index</h3>
        <p><b>{project_status['documents']}</b> indexed documents</p>
        <p class="muted">Last updated: {html.escape(str(project_status['last_indexed_at'] or 'Never'))}</p>
        <form action="/index-projects" method="post">
          <button type="submit" class="secondary">Update Index</button>
        </form>
      </section>
      <section>
        <h3>Action Queue</h3>
        <form action="/queue" method="post">
          <select name="action_type">
            <option>copy_to_clipboard</option><option>open_app</option><option>open_url</option><option>type_text</option><option>key_combo</option><option>financial_action</option>
          </select>
          <textarea name="payload">{{"text":"hello"}}</textarea>
          <input name="reason" placeholder="reason">
          <button type="submit">Queue Action</button>
        </form>
        <table><tr><th>ID</th><th>Type</th><th>Risk</th><th>Status</th><th></th></tr>{action_rows}</table>
      </section>
    </div>
    """


def parent_process_is_current(parent_pid: int) -> bool:
    """Return true only while this dashboard still belongs to its Jarvis app."""
    return parent_pid > 1 and os.getppid() == parent_pid


def watch_parent(server: ThreadingHTTPServer, parent_pid: int) -> None:
    while parent_process_is_current(parent_pid):
        threading.Event().wait(0.5)
    server.shutdown()


def serve(host: str = "127.0.0.1", port: int = 8765) -> None:
    if host != "127.0.0.1":
        raise RuntimeError("Jarvis dashboard may bind only to IPv4 loopback.")
    token = os.environ.get(DASHBOARD_TOKEN_ENV, "")
    if len(token) < 43:
        raise RuntimeError("Jarvis dashboard refused to start without a strong session token.")
    seed_default_event_rules()
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    server.jarvis_token = token  # type: ignore[attr-defined]
    raw_parent_pid = os.environ.get("JARVIS_PARENT_PID", "")
    if raw_parent_pid.isdigit():
        threading.Thread(
            target=watch_parent,
            args=(server, int(raw_parent_pid)),
            name="jarvis-parent-watch",
            daemon=True,
        ).start()
    print(f"Jarvis dashboard: http://{host}:{port}")
    server.serve_forever()
