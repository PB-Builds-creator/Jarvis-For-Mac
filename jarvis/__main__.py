from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

os.umask(0o077)

from .actions import approve_action, execute_action, list_actions, queue_action
from .awareness import (
    awareness_status,
    clear_conversation_history,
    record_conversation,
)
from .backup import backup_status, create_encrypted_backup, verify_encrypted_backup
from .adapters import adapter_status
from .config import load_config, save_config
from .context import prepare_context
from .dashboard import serve
from .desktop_bridge import ask_jarvis, ask_named_app_window, notify
from .diagnostics import create_diagnostics_pack
from .events import emit_event, list_event_rules, save_event_rule
from .integrations import (
    agenda,
    contacts,
    create_calendar_event,
    create_note,
    create_reminder,
    draft_mail,
    integration_status,
    reminders,
)
from .health import health_snapshot
from .mcp_server import main as mcp_main
from .memory import (
    add_memory,
    consolidate_memories,
    correct_memory,
    export_memory,
    forget_memory,
    import_memory,
    list_timeline,
    memory_stats,
    search_memories,
)
from .project_index import index_projects, project_index_status, search_projects
from .owner_voice import (
    disable_owner_voice,
    enroll_owner_voice,
    owner_voice_status,
    verify_owner_voice,
)
from .routines import list_routines, run_routine, save_routine
from .screen import read_active_window
from .trading_journal import list_reviews, update_review_analysis
from .tts import speech_status, synthesize_speech
from .transcription import (
    add_vocabulary,
    fallback_status,
    list_vocabulary,
    transcribe_fallback,
)
from .vision_fallback import analyze_image, status as visual_fallback_status
from .voice import (
    VoiceConfirmationRequired,
    cleanup_stale_voice_artifacts,
    dispatch_voice_intent,
    parse_voice_command,
)
from .voice_health import voice_pipeline_health


def main() -> None:
    parser = argparse.ArgumentParser(prog="jarvis", description="Jarvis No-API Bridge")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("dashboard")
    prep = sub.add_parser("prepare")
    prep.add_argument("task", nargs="?", default="Analyze the active window and recommend next steps.")
    send = sub.add_parser("send")
    send.add_argument("task", nargs="?", default="Analyze the active window and recommend next steps.")
    send.add_argument("--route", choices=("auto", "chat", "work"), default="auto")
    send.add_argument("--screenshots", nargs="*", default=[])
    sub.add_parser("read-active-window")
    sub.add_parser("export-memory")
    imp = sub.add_parser("import-memory")
    imp.add_argument("path")
    q = sub.add_parser("queue-action")
    q.add_argument("action_type")
    q.add_argument("payload_json")
    q.add_argument("--reason", default="")
    sub.add_parser("list-actions")
    app = sub.add_parser("approve-action")
    app.add_argument("id", type=int)
    run = sub.add_parser("run-action")
    run.add_argument("id", type=int)
    mem = sub.add_parser("search-memory")
    mem.add_argument("query", nargs="?", default="")
    remember = sub.add_parser("remember")
    remember.add_argument("text")
    remember.add_argument("--category", default="note")
    remember.add_argument("--title", default="")
    remember.add_argument("--kind", default="fact")
    remember.add_argument("--scope", default="global")
    remember.add_argument("--privacy", default="local")
    remember.add_argument("--expires-at", default=None)
    forget = sub.add_parser("forget-memory")
    forget.add_argument("id", type=int)
    correct = sub.add_parser("correct-memory")
    correct.add_argument("id", type=int)
    correct.add_argument("text")
    correct.add_argument("--reason", default="")
    sub.add_parser("consolidate-memory")
    sub.add_parser("memory-status")
    conversation = sub.add_parser("record-conversation")
    conversation.add_argument("user_text")
    conversation.add_argument("--reply", default="")
    conversation.add_argument("--kind", default="conversation")
    conversation.add_argument("--source", default="jarvis")
    conversation.add_argument("--correlation-id", default="")
    sub.add_parser("awareness-status")
    sub.add_parser("clear-conversation-history")
    deep_conversation = sub.add_parser("deep-conversation")
    deep_conversation.add_argument(
        "state",
        choices=("on", "off", "toggle", "status"),
    )
    synthesis = sub.add_parser("synthesize-speech")
    synthesis.add_argument("text")
    sub.add_parser("speech-status")
    timeline = sub.add_parser("timeline")
    timeline.add_argument("--limit", type=int, default=100)
    routine_save = sub.add_parser("save-routine")
    routine_save.add_argument("name")
    routine_save.add_argument("steps_json")
    routine_save.add_argument("--description", default="")
    routine_save.add_argument("--parameters-json", default="{}")
    sub.add_parser("list-routines")
    routine_run = sub.add_parser("run-routine")
    routine_run.add_argument("name")
    routine_run.add_argument("--parameters-json", default="{}")
    routine_run.add_argument("--queue", action="store_true")
    event_emit = sub.add_parser("emit-event")
    event_emit.add_argument("event_type")
    event_emit.add_argument("--payload-json", default="{}")
    sub.add_parser("list-event-rules")
    event_rule = sub.add_parser("save-event-rule")
    event_rule.add_argument("name")
    event_rule.add_argument("trigger_type")
    event_rule.add_argument("--trigger-json", default="{}")
    event_rule.add_argument("--routine", default="")
    event_rule.add_argument("--notification", default="")
    event_rule.add_argument("--risk-policy", default="notify")
    private = sub.add_parser("private-mode")
    private.add_argument("state", choices=("on", "off", "status"))
    sub.add_parser("index-projects")
    project_search = sub.add_parser("search-projects")
    project_search.add_argument("query")
    sub.add_parser("project-index-status")
    vocabulary = sub.add_parser("add-vocabulary")
    vocabulary.add_argument("phrase")
    vocabulary.add_argument("--replacement", default="")
    vocabulary.add_argument("--category", default="general")
    sub.add_parser("list-vocabulary")
    sub.add_parser("integration-status")
    agenda_parser = sub.add_parser("agenda")
    agenda_parser.add_argument("--days", type=int, default=1)
    sub.add_parser("reminders")
    contact_parser = sub.add_parser("contacts")
    contact_parser.add_argument("query", nargs="?", default="")
    event_create = sub.add_parser("create-calendar-event")
    event_create.add_argument("title")
    event_create.add_argument("start")
    event_create.add_argument("end")
    event_create.add_argument("--notes", default="")
    event_create.add_argument("--location", default="")
    event_create.add_argument("--confirmed", action="store_true")
    reminder_create = sub.add_parser("create-reminder")
    reminder_create.add_argument("title")
    reminder_create.add_argument("--due", default="")
    reminder_create.add_argument("--notes", default="")
    reminder_create.add_argument("--confirmed", action="store_true")
    note_create = sub.add_parser("create-note")
    note_create.add_argument("title")
    note_create.add_argument("body")
    note_create.add_argument("--confirmed", action="store_true")
    mail_draft = sub.add_parser("draft-mail")
    mail_draft.add_argument("recipient")
    mail_draft.add_argument("subject")
    mail_draft.add_argument("body")
    mail_draft.add_argument("--confirmed", action="store_true")
    sub.add_parser("adapter-status")
    sub.add_parser("specialist-status")
    transcription_run = sub.add_parser("transcribe-fallback")
    transcription_run.add_argument("audio")
    visual_run = sub.add_parser("visual-analyze")
    visual_run.add_argument("image")
    visual_run.add_argument("prompt")
    sub.add_parser("health")
    sub.add_parser("voice-health")
    sub.add_parser("diagnostics")
    encrypted_backup = sub.add_parser("encrypted-backup")
    encrypted_backup.add_argument("--destination", default="")
    verify_backup = sub.add_parser("verify-backup")
    verify_backup.add_argument("path")
    sub.add_parser("backup-status")
    sub.add_parser("list-trading-reviews")
    review_update = sub.add_parser("update-trading-review")
    review_update.add_argument("review_id")
    review_update.add_argument("--analysis", default="")
    review_update.add_argument("--bias", default="")
    review_update.add_argument("--key-levels", default="")
    review_update.add_argument("--invalidation", default="")
    review_update.add_argument("--outcome", default="")
    voice_intent = sub.add_parser("voice-intent")
    voice_intent.add_argument("transcript")
    voice_intent.add_argument("--local-context", default="")
    voice_dispatch = sub.add_parser("voice-dispatch")
    voice_dispatch.add_argument("transcript")
    voice_dispatch.add_argument("--confirmed", action="store_true")
    sub.add_parser("owner-voice-status")
    owner_enroll = sub.add_parser("owner-voice-enroll")
    owner_enroll.add_argument("audio", nargs="+")
    owner_verify = sub.add_parser("owner-voice-verify")
    owner_verify.add_argument("audio")
    sub.add_parser("owner-voice-disable")
    sub.add_parser("mcp")
    args = parser.parse_args()

    if args.cmd == "dashboard":
        serve()
    elif args.cmd == "prepare":
        print(prepare_context(args.task))
    elif args.cmd == "send":
        result = ask_jarvis(args.task, args.route, screenshot_paths=args.screenshots)
        print(f"Sent to Jarvis task {result.thread_id} in {result.route.destination} mode.")
    elif args.cmd == "read-active-window":
        screen = read_active_window()
        print(screen)
        notify(f"Captured and read {screen.active_app or 'the active window'} successfully.")
    elif args.cmd == "export-memory":
        print(export_memory())
    elif args.cmd == "import-memory":
        print(f"Imported {import_memory(Path(args.path))} memories.")
    elif args.cmd == "queue-action":
        print(queue_action(args.action_type, json.loads(args.payload_json), args.reason))
    elif args.cmd == "list-actions":
        for action in list_actions():
            print(action)
    elif args.cmd == "approve-action":
        print("approved" if approve_action(args.id) else "not approved")
    elif args.cmd == "run-action":
        print(execute_action(args.id))
    elif args.cmd == "search-memory":
        for item in search_memories(args.query):
            print(f"[{item['category']}] {item['title']}: {item['body']}")
    elif args.cmd == "remember":
        print(add_memory(
            args.category,
            args.title or args.text[:80],
            args.text,
            kind=args.kind,
            scope=args.scope,
            privacy=args.privacy,
            expires_at=args.expires_at,
        ))
    elif args.cmd == "forget-memory":
        print("forgotten" if forget_memory(args.id) else "not found")
    elif args.cmd == "correct-memory":
        print(correct_memory(args.id, args.text, reason=args.reason))
    elif args.cmd == "consolidate-memory":
        print(json.dumps(consolidate_memories(), sort_keys=True))
    elif args.cmd == "memory-status":
        print(json.dumps(memory_stats(), sort_keys=True))
    elif args.cmd == "record-conversation":
        print(record_conversation(
            args.user_text,
            args.reply,
            turn_kind=args.kind,
            source=args.source,
            correlation_id=args.correlation_id,
        ))
    elif args.cmd == "awareness-status":
        print(json.dumps(awareness_status(), indent=2, sort_keys=True))
    elif args.cmd == "clear-conversation-history":
        print(json.dumps(
            {"turns_removed": clear_conversation_history()},
            sort_keys=True,
        ))
    elif args.cmd == "deep-conversation":
        cfg = load_config()
        if args.state == "toggle":
            cfg.deep_conversation_enabled = not cfg.deep_conversation_enabled
            save_config(cfg)
        elif args.state != "status":
            cfg.deep_conversation_enabled = args.state == "on"
            save_config(cfg)
        print(json.dumps(
            {
                "enabled": cfg.deep_conversation_enabled,
                "engine": "Qwen3.5 4B on demand",
                "idle_unload_seconds": cfg.local_ai_idle_unload_seconds,
            },
            sort_keys=True,
        ))
    elif args.cmd == "synthesize-speech":
        print(json.dumps(synthesize_speech(args.text), sort_keys=True))
    elif args.cmd == "speech-status":
        print(json.dumps(speech_status(), sort_keys=True))
    elif args.cmd == "timeline":
        print(json.dumps(list_timeline(args.limit), indent=2, sort_keys=True))
    elif args.cmd == "save-routine":
        print(save_routine(
            args.name,
            json.loads(args.steps_json),
            description=args.description,
            parameters=json.loads(args.parameters_json),
        ))
    elif args.cmd == "list-routines":
        print(json.dumps(list_routines(), indent=2, sort_keys=True))
    elif args.cmd == "run-routine":
        print(json.dumps(
            run_routine(
                args.name,
                parameters=json.loads(args.parameters_json),
                dry_run=not args.queue,
            ).to_dict(),
            indent=2,
            sort_keys=True,
        ))
    elif args.cmd == "emit-event":
        print(json.dumps(
            emit_event(
                args.event_type,
                json.loads(args.payload_json),
            ).to_dict(),
            indent=2,
            sort_keys=True,
        ))
    elif args.cmd == "list-event-rules":
        print(json.dumps(list_event_rules(), indent=2, sort_keys=True))
    elif args.cmd == "save-event-rule":
        print(save_event_rule(
            args.name,
            args.trigger_type,
            trigger=json.loads(args.trigger_json),
            routine_name=args.routine,
            notification_text=args.notification,
            risk_policy=args.risk_policy,
        ))
    elif args.cmd == "private-mode":
        cfg = load_config()
        if args.state != "status":
            cfg.private_mode = args.state == "on"
            save_config(cfg)
        print("on" if cfg.private_mode else "off")
    elif args.cmd == "index-projects":
        print(json.dumps(index_projects(), sort_keys=True))
    elif args.cmd == "search-projects":
        print(json.dumps(search_projects(args.query), indent=2, sort_keys=True))
    elif args.cmd == "project-index-status":
        print(json.dumps(project_index_status(), indent=2, sort_keys=True))
    elif args.cmd == "add-vocabulary":
        print(add_vocabulary(
            args.phrase,
            replacement=args.replacement,
            category=args.category,
        ))
    elif args.cmd == "list-vocabulary":
        print(json.dumps(list_vocabulary(), indent=2, sort_keys=True))
    elif args.cmd == "integration-status":
        print(json.dumps(integration_status(), indent=2, sort_keys=True))
    elif args.cmd == "agenda":
        print(json.dumps(agenda(args.days), indent=2, sort_keys=True))
    elif args.cmd == "reminders":
        print(json.dumps(reminders(), indent=2, sort_keys=True))
    elif args.cmd == "contacts":
        print(json.dumps(contacts(args.query), indent=2, sort_keys=True))
    elif args.cmd == "create-calendar-event":
        print(json.dumps(
            create_calendar_event(
                args.title,
                args.start,
                args.end,
                notes=args.notes,
                location=args.location,
                confirmed=args.confirmed,
            ),
            indent=2,
            sort_keys=True,
        ))
    elif args.cmd == "create-reminder":
        print(json.dumps(
            create_reminder(
                args.title,
                due=args.due,
                notes=args.notes,
                confirmed=args.confirmed,
            ),
            indent=2,
            sort_keys=True,
        ))
    elif args.cmd == "create-note":
        print(create_note(args.title, args.body, confirmed=args.confirmed))
    elif args.cmd == "draft-mail":
        print(draft_mail(
            args.recipient,
            args.subject,
            args.body,
            confirmed=args.confirmed,
        ))
    elif args.cmd == "adapter-status":
        print(json.dumps(adapter_status(), indent=2, sort_keys=True))
    elif args.cmd == "specialist-status":
        print(json.dumps(
            {
                "transcription": fallback_status(),
                "vision": visual_fallback_status(),
            },
            indent=2,
            sort_keys=True,
        ))
    elif args.cmd == "transcribe-fallback":
        print(transcribe_fallback(Path(args.audio)))
    elif args.cmd == "visual-analyze":
        print(json.dumps(
            analyze_image(Path(args.image), args.prompt),
            indent=2,
            sort_keys=True,
        ))
    elif args.cmd == "health":
        print(json.dumps(
            health_snapshot(include_adapters=True),
            indent=2,
            sort_keys=True,
        ))
    elif args.cmd == "voice-health":
        print(json.dumps(voice_pipeline_health(), indent=2, sort_keys=True))
    elif args.cmd == "diagnostics":
        print(create_diagnostics_pack())
    elif args.cmd == "encrypted-backup":
        destination = Path(args.destination) if args.destination else None
        print(create_encrypted_backup(destination))
    elif args.cmd == "verify-backup":
        print(json.dumps(
            verify_encrypted_backup(Path(args.path)),
            indent=2,
            sort_keys=True,
        ))
    elif args.cmd == "backup-status":
        print(json.dumps(backup_status(), indent=2, sort_keys=True))
    elif args.cmd == "list-trading-reviews":
        print(json.dumps(list_reviews(), indent=2, sort_keys=True))
    elif args.cmd == "update-trading-review":
        print("updated" if update_review_analysis(
            args.review_id,
            analysis=args.analysis,
            bias=args.bias,
            key_levels=args.key_levels,
            invalidation=args.invalidation,
            outcome=args.outcome,
        ) else "not found")
    elif args.cmd == "voice-intent":
        cleanup_stale_voice_artifacts()
        print(json.dumps(
            parse_voice_command(args.transcript, local_context=args.local_context).to_dict(),
            sort_keys=True,
        ))
    elif args.cmd == "voice-dispatch":
        cleanup_stale_voice_artifacts()
        intent = parse_voice_command(args.transcript)
        try:
            result = dispatch_voice_intent(
                intent,
                confirmed=args.confirmed,
                sender=ask_jarvis,
                window_sender=ask_named_app_window,
            )
        except VoiceConfirmationRequired as exc:
            raise SystemExit(str(exc)) from None
        except Exception as exc:
            raise SystemExit(f"Jarvis could not send the confirmed voice request: {exc}") from None
        if result is intent:
            print(json.dumps(result.to_dict(), sort_keys=True))
        else:
            print(f"Sent confirmed voice request to {result.route.destination} task {result.thread_id}.")
    elif args.cmd == "owner-voice-status":
        print(json.dumps(owner_voice_status(), sort_keys=True))
    elif args.cmd == "owner-voice-enroll":
        print(json.dumps(
            enroll_owner_voice(Path(path) for path in args.audio),
            sort_keys=True,
        ))
    elif args.cmd == "owner-voice-verify":
        print(json.dumps(verify_owner_voice(Path(args.audio)), sort_keys=True))
    elif args.cmd == "owner-voice-disable":
        print(json.dumps(disable_owner_voice(), sort_keys=True))
    elif args.cmd == "mcp":
        mcp_main()


if __name__ == "__main__":
    main()
