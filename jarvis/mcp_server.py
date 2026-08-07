from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from .actions import approve_action, execute_action, list_actions, queue_action
from .context import prepare_context
from .events import emit_event, list_event_rules
from .health import health_snapshot
from .integrations import agenda, contacts, integration_status, reminders
from .memory import (
    add_memory,
    correct_memory,
    export_memory,
    forget_memory,
    import_memory,
    list_timeline,
    search_memories,
)
from .project_index import index_projects, search_projects
from .routines import list_routines, run_routine, save_routine
from .screen import read_active_window
from .trading_journal import list_reviews, update_review_analysis


EMPTY_SCHEMA = {"type": "object", "properties": {}, "additionalProperties": False}


TOOLS = [
    {"name": "read_active_window", "description": "Read the frontmost Mac window using local Jarvis screen tools.", "inputSchema": EMPTY_SCHEMA},
    {
        "name": "prepare_chatgpt_context",
        "description": "Prepare active-window context, copy it to clipboard, and open ChatGPT.",
        "inputSchema": {"type": "object", "properties": {"task": {"type": "string"}}, "additionalProperties": False},
    },
    {
        "name": "search_memory",
        "description": "Search local Jarvis memory.",
        "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}, "limit": {"type": "integer"}}, "additionalProperties": False},
    },
    {"name": "export_memory", "description": "Export local Jarvis memory to a JSON file.", "inputSchema": EMPTY_SCHEMA},
    {
        "name": "import_memory",
        "description": "Import local Jarvis memory from a JSON file.",
        "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"], "additionalProperties": False},
    },
    {
        "name": "queue_action",
        "description": "Queue a local Mac action for the owner approval.",
        "inputSchema": {
            "type": "object",
            "properties": {"action_type": {"type": "string"}, "payload": {"type": "object"}, "reason": {"type": "string"}},
            "required": ["action_type"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_actions",
        "description": "List queued local actions.",
        "inputSchema": {"type": "object", "properties": {"status": {"type": "string"}}, "additionalProperties": False},
    },
    {
        "name": "approve_action",
        "description": "Approve a queued local action.",
        "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"], "additionalProperties": False},
    },
    {
        "name": "execute_action",
        "description": "Execute an approved local action.",
        "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"], "additionalProperties": False},
    },
    {
        "name": "remember",
        "description": "Store a structured local Jarvis memory.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string"},
                "title": {"type": "string"},
                "category": {"type": "string"},
                "kind": {"type": "string"},
                "scope": {"type": "string"},
                "privacy": {"type": "string"},
                "expires_at": {"type": "string"},
            },
            "required": ["text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "forget_memory",
        "description": "Deactivate one local memory by ID.",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "integer"}},
            "required": ["id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "correct_memory",
        "description": "Supersede one local memory with a user-confirmed correction.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "integer"},
                "text": {"type": "string"},
                "reason": {"type": "string"},
            },
            "required": ["id", "text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_timeline",
        "description": "Read Jarvis's local action and system timeline.",
        "inputSchema": {
            "type": "object",
            "properties": {"limit": {"type": "integer"}},
            "additionalProperties": False,
        },
    },
    {
        "name": "save_routine",
        "description": "Save a versioned routine made of validated Jarvis actions.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "description": {"type": "string"},
                "parameters": {"type": "object"},
                "steps": {"type": "array", "items": {"type": "object"}},
            },
            "required": ["name", "steps"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_routines",
        "description": "List enabled local Jarvis routines.",
        "inputSchema": EMPTY_SCHEMA,
    },
    {
        "name": "run_routine",
        "description": "Preview a routine or queue its steps for approval.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "parameters": {"type": "object"},
                "queue": {"type": "boolean"},
            },
            "required": ["name"],
            "additionalProperties": False,
        },
    },
    {
        "name": "emit_event",
        "description": "Submit one local system event to the proactive rules engine.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "event_type": {"type": "string"},
                "payload": {"type": "object"},
            },
            "required": ["event_type"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_event_rules",
        "description": "List proactive local event rules.",
        "inputSchema": EMPTY_SCHEMA,
    },
    {
        "name": "health",
        "description": "Read local Jarvis health, permissions, audio, routing, and resource policy.",
        "inputSchema": EMPTY_SCHEMA,
    },
    {
        "name": "index_projects",
        "description": "Update the local index for user-approved project roots.",
        "inputSchema": EMPTY_SCHEMA,
    },
    {
        "name": "search_projects",
        "description": "Search the local approved project index.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer"},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "personal_integration_status",
        "description": "Read Calendar, Reminders, Contacts, Notes, and Mail capability status.",
        "inputSchema": EMPTY_SCHEMA,
    },
    {
        "name": "agenda",
        "description": "Read the local Calendar agenda.",
        "inputSchema": {
            "type": "object",
            "properties": {"days": {"type": "integer"}},
            "additionalProperties": False,
        },
    },
    {
        "name": "reminders",
        "description": "Read incomplete local reminders.",
        "inputSchema": EMPTY_SCHEMA,
    },
    {
        "name": "contacts",
        "description": "Search local Contacts without sending anything.",
        "inputSchema": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "additionalProperties": False,
        },
    },
    {
        "name": "list_trading_reviews",
        "description": "List analysis-only TradingView journal entries.",
        "inputSchema": {
            "type": "object",
            "properties": {"limit": {"type": "integer"}},
            "additionalProperties": False,
        },
    },
    {
        "name": "update_trading_review",
        "description": "Add analysis or outcome notes to an existing trading review; never executes trades.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "review_id": {"type": "string"},
                "analysis": {"type": "string"},
                "bias": {"type": "string"},
                "key_levels": {"type": "string"},
                "invalidation": {"type": "string"},
                "outcome": {"type": "string"},
            },
            "required": ["review_id"],
            "additionalProperties": False,
        },
    },
]


def result(request_id: Any, value: Any) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "result": value}


def error(request_id: Any, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": message}}


def call_tool(name: str, args: dict) -> Any:
    if name == "read_active_window":
        return read_active_window().__dict__
    if name == "prepare_chatgpt_context":
        return {"context": prepare_context(args.get("task", "Analyze the active window."))}
    if name == "search_memory":
        return search_memories(args.get("query", ""), int(args.get("limit", 10)))
    if name == "export_memory":
        return {"path": str(export_memory())}
    if name == "import_memory":
        return {"imported": import_memory(Path(args["path"]))}
    if name == "queue_action":
        return {"id": queue_action(args["action_type"], args.get("payload", {}), args.get("reason", ""))}
    if name == "list_actions":
        return list_actions(args.get("status"))
    if name == "approve_action":
        return {"approved": approve_action(int(args["id"]))}
    if name == "execute_action":
        return {"result": execute_action(int(args["id"]))}
    if name == "remember":
        text = str(args["text"])
        return {"id": add_memory(
            str(args.get("category", "note")),
            str(args.get("title", "")) or text[:80],
            text,
            kind=str(args.get("kind", "fact")),
            scope=str(args.get("scope", "global")),
            privacy=str(args.get("privacy", "local")),
            expires_at=args.get("expires_at"),
        )}
    if name == "forget_memory":
        return {"forgotten": forget_memory(int(args["id"]))}
    if name == "correct_memory":
        return {"id": correct_memory(
            int(args["id"]),
            str(args["text"]),
            reason=str(args.get("reason", "")),
        )}
    if name == "list_timeline":
        return list_timeline(int(args.get("limit", 100)))
    if name == "save_routine":
        return {"id": save_routine(
            str(args["name"]),
            list(args["steps"]),
            description=str(args.get("description", "")),
            parameters=dict(args.get("parameters", {})),
        )}
    if name == "list_routines":
        return list_routines()
    if name == "run_routine":
        return run_routine(
            str(args["name"]),
            parameters=dict(args.get("parameters", {})),
            dry_run=not bool(args.get("queue", False)),
        ).to_dict()
    if name == "emit_event":
        return emit_event(
            str(args["event_type"]),
            dict(args.get("payload", {})),
        ).to_dict()
    if name == "list_event_rules":
        return list_event_rules()
    if name == "health":
        return health_snapshot(include_adapters=True)
    if name == "index_projects":
        return index_projects()
    if name == "search_projects":
        return search_projects(str(args["query"]), int(args.get("limit", 20)))
    if name == "personal_integration_status":
        return integration_status()
    if name == "agenda":
        return agenda(int(args.get("days", 1)))
    if name == "reminders":
        return reminders()
    if name == "contacts":
        return contacts(str(args.get("query", "")))
    if name == "list_trading_reviews":
        return list_reviews(int(args.get("limit", 50)))
    if name == "update_trading_review":
        return {"updated": update_review_analysis(
            str(args["review_id"]),
            analysis=str(args.get("analysis", "")),
            bias=str(args.get("bias", "")),
            key_levels=str(args.get("key_levels", "")),
            invalidation=str(args.get("invalidation", "")),
            outcome=str(args.get("outcome", "")),
        )}
    raise ValueError("Unknown tool.")


def main() -> None:
    for line in sys.stdin:
        try:
            req = json.loads(line)
            method = req.get("method")
            request_id = req.get("id")
            if method == "initialize":
                response = result(request_id, {"protocolVersion": "2024-11-05", "serverInfo": {"name": "jarvis-local", "version": "1.0.0"}})
            elif method == "tools/list":
                response = result(request_id, {"tools": TOOLS})
            elif method == "tools/call":
                params = req.get("params", {})
                response = result(request_id, {"content": [{"type": "text", "text": json.dumps(call_tool(params.get("name"), params.get("arguments", {})), indent=2)}]})
            else:
                response = result(request_id, {})
        except Exception as exc:
            response = error(req.get("id") if "req" in locals() else None, str(exc))
        print(json.dumps(response), flush=True)


if __name__ == "__main__":
    main()
