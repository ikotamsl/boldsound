from __future__ import annotations

import argparse
import asyncio
import json
import os
import plistlib
import shutil
import sqlite3
import sys
from pathlib import Path

from pydantic import ValidationError

from .models import AgentError, CalendarSnapshot, EnqueueRequest, NoteRef, Profile, Source, canonical
from .providers import Provider, run_process, save_credential
from .store import Store
from .vault import Vault
from .worker import Worker

DEFAULT_STATE = Path.home() / "Library/Application Support/Boldsound/MeetingAgent"


def stdin_json():
    value = json.load(sys.stdin)
    if not isinstance(value, dict):
        raise AgentError("invalid_request", "stdin must contain a JSON object")
    return value


def from_artifact(path: str) -> Source:
    data = json.loads(Path(path).read_text())
    if data.get("sourceType") != "meeting" or data.get("status") != "completed":
        raise AgentError("not_completed_meeting", "Only completed meeting transcripts can be processed")
    return Source(id=data["id"], title=data["title"], created_at=data["createdAt"], updated_at=data.get("updatedAt"),
        text=data.get("cleanTranscript") or data.get("rawTranscript") or data.get("transcript") or "",
        artifact_path=str(Path(path).absolute()), calendar=data.get("calendarEventSnapshot"), original_calendar=data.get("calendarEventSnapshot"))


async def manual_source(target: str, executable: str, *, dry_run: bool = False) -> Source:
    if target == "latest":
        output, _ = await run_process([executable, "meetings", "list", "--json", "--limit", "200"], timeout=30)
        meetings = json.loads(output)
        meeting = next((m for m in meetings if m["status"] == "completed"), None)
        if not meeting:
            raise AgentError("source_missing", "No completed meeting found")
        target = meeting["id"]
    if dry_run:
        output, _ = await run_process([executable, "meetings", "show", target, "--json"], timeout=30)
        data = json.loads(output)
        if data.get("status") != "completed" or not data.get("artifactFolderPath"):
            raise AgentError("not_completed_meeting", "A completed meeting with a local artifact folder is required")
        return Source(id=data["id"], title=data["title"], created_at=data["createdAt"], updated_at=data.get("updatedAt"),
            text=data.get("transcript") or "", artifact_path=str(Path(data["artifactFolderPath"]) / "transcript.json"),
            calendar=data.get("calendarEventSnapshot"), original_calendar=data.get("calendarEventSnapshot"))
    output, _ = await run_process([executable, "meetings", "artifact", target, "--json"], timeout=30)
    artifact = json.loads(output)
    return from_artifact(artifact["transcriptPath"])


async def dispatch(args, store: Store):
    if args.command == "profiles":
        data = stdin_json() if args.stdin else {"action": "list"}
        if data.get("action", "list") == "list":
            return store.profiles()
        if data["action"] == "save":
            profile = Profile.model_validate(data["profile"])
            if data.get("api_key"):
                if profile.provider in {"codex", "gemini_cli"}:
                    raise AgentError("invalid_request", "Subscription profiles accept official saved login only")
                profile.key_ref = profile.key_ref or profile.id
                save_credential(profile.key_ref, data["api_key"])
            return store.save_profile(profile, data.get("default", False))
        raise AgentError("invalid_request", "Unknown profiles action")
    if args.command == "doctor":
        data = stdin_json() if args.stdin else {}
        result = {"schema_version": 1, "state_directory": str(store.directory), "profiles": store.profiles(),
            "stale_notes": [json.loads(r[0]) for r in store.db.execute("SELECT ref FROM note_state WHERE stale>0")],
            "codex_installed": shutil.which("codex") is not None, "gemini_installed": shutil.which("gemini") is not None}
        vault = data.get("vault", args.vault)
        result["vault_available"] = Path(vault).is_dir()
        result["template_available"] = (Path(vault) / "Templates/Meeting.md").is_file()
        if args.test or data.get("test"):
            profile = store.profile(data.get("profile_id", args.profile))
            probe = await Provider(profile, vault).generate("Тест подключения. Встречи и задач нет.")
            result["connection"] = {"ok": True, "model": probe.model, "execution": profile.execution}
        return result
    if args.command == "enqueue":
        return store.enqueue(EnqueueRequest.model_validate(stdin_json()))
    if args.command == "hook":
        event = stdin_json()
        if event.get("event") != "meeting.completed" or event.get("schemaVersion") != 1:
            raise AgentError("invalid_event", "Expected meeting.completed v1")
        source = store.merge_saved_binding(from_artifact(event["artifact"]["transcriptPath"]))
        if source.id.casefold() != str(event["meeting"]["id"]).casefold():
            raise AgentError("invalid_event", "Artifact does not belong to the event meeting")
        return store.enqueue(EnqueueRequest(source=source, profile_id=args.profile, vault=args.vault))
    if args.command == "jobs":
        data = stdin_json() if args.stdin else {}
        return store.jobs(data.get("source_id", args.source))
    if args.command in {"retry", "cancel"}:
        data = stdin_json() if args.stdin else {"id": args.id}
        return getattr(store, args.command)(data["id"])
    if args.command == "invalidate":
        data = stdin_json()
        with store.transaction():
            store.db.execute("UPDATE jobs SET state='cancelled',error='Binding is being changed' WHERE source_id=? AND state IN ('queued','processing')", (data["source_id"],))
        return {"invalidated": True}
    if args.command == "bind":
        data = stdin_json()
        note = NoteRef.model_validate(data["note"]) if data.get("note") else None
        calendar = CalendarSnapshot.model_validate(data["calendar"]) if data.get("calendar") else None
        if data.get("event_only"):
            if not calendar or not note:
                raise AgentError("invalid_request", "Event binding requires an event and a note")
            store.bind_event(calendar.occurrence_key, note)
            return {"bound": True}
        return store.bind(data["source_id"], note, calendar, data.get("binding_version"))
    if args.command == "notes":
        data = stdin_json() if args.stdin else {}
        vault = Vault(data.get("vault", args.vault))
        if data.get("path"):
            return {"note": vault.reference(vault.path(data["path"])).model_dump()}
        query = data.get("query", "").casefold()
        return {"notes": [vault.reference(path).model_dump() for path in vault.notes() if query in path.stem.casefold()]}
    if args.command == "worker":
        await Worker(store).run(args.once)
        return {"worker": "stopped"}
    if args.command == "process":
        source = store.merge_saved_binding(await manual_source(args.target, args.macparakeet_cli, dry_run=args.dry_run))
        if args.note:
            vault = Vault(args.vault)
            source.note = vault.reference(vault.path(args.note))
            source.binding_version += 1
        previous = store.db.execute("SELECT request FROM sources WHERE id=?", (source.id,)).fetchone()
        version = EnqueueRequest.model_validate_json(previous[0]).processing_version + 1 if previous else 1
        request = EnqueueRequest(source=source, vault=args.vault, profile_id=args.profile, force=args.force, processing_version=version)
        if args.dry_run:
            # An isolated temporary queue leaves the durable queue and vault unchanged.
            import tempfile
            with tempfile.TemporaryDirectory(prefix="boldsound-dry-run-") as directory:
                temporary = Store(Path(directory))
                store.db.backup(temporary.db)
                temporary.save_profile(store.profile(args.profile), True)
                temporary.db.execute("DELETE FROM jobs")
                temporary.enqueue(request)
                row = temporary.claim()
                prepared = await Worker(temporary).process(row, dry_run=True)
                return {"dry_run": True, "note": prepared["ref"], "proposed_markdown": prepared["text"]}
        return store.enqueue(request)
    if args.command == "launchd":
        executable = str(Path(sys.executable).absolute())
        plist = {"Label": "com.boldsound.meeting-agent", "ProgramArguments": [executable, "-m", "meeting_agent", "--state-dir", str(store.directory), "worker"],
            "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 15,
            "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"},
            "StandardOutPath": str(store.directory / "worker.stdout.log"), "StandardErrorPath": str(store.directory / "worker.stderr.log")}
        if args.install:
            directory = Path.home() / "Library/LaunchAgents"
            directory.mkdir(parents=True, exist_ok=True)
            path = directory / (plist["Label"] + ".plist")
            service = f"gui/{os.getuid()}/{plist['Label']}"
            try:
                await run_process(["/bin/launchctl", "print", service], timeout=15)
            except AgentError as exc:
                if exc.code != "cli_error":
                    raise
            else:
                await run_process(["/bin/launchctl", "bootout", service], timeout=15)
            path.write_bytes(plistlib.dumps(plist))
            await run_process(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(path)], timeout=15)
            return {"installed": str(path)}
        return {"plist": plist}
    if args.command == "login":
        profile = store.profile(args.profile)
        if profile.provider not in {"codex", "gemini_cli"}:
            raise AgentError("invalid_request", "API profiles use API keys, not subscription login")
        executable = profile.cli_path or shutil.which("codex" if profile.provider == "codex" else "gemini")
        if not executable:
            raise AgentError("cli_unavailable", "Install the official CLI first")
        argv = [executable, "login"] if profile.provider == "codex" else [executable]
        # JSON callers open an interactive terminal with these exact arguments.
        return {"executable": argv[0], "arguments": argv[1:]}
    raise AgentError("invalid_request", "Unknown command")


def parser():
    root = argparse.ArgumentParser(prog="meeting-agent")
    root.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
    root.add_argument("--vault", default="/Users/user/obsidian/gtd")
    root.add_argument("--profile")
    sub = root.add_subparsers(dest="command", required=True)
    for command in ("profiles", "doctor", "jobs", "notes", "retry", "cancel"):
        p = sub.add_parser(command)
        p.add_argument("--stdin", action="store_true")
        if command == "doctor":
            p.add_argument("--test", action="store_true")
        if command == "jobs":
            p.add_argument("--source")
        if command in {"retry", "cancel"}:
            p.add_argument("id", nargs="?")
    for command in ("enqueue", "hook", "bind", "invalidate", "login"):
        sub.add_parser(command)
    p = sub.add_parser("worker")
    p.add_argument("--once", action="store_true")
    p = sub.add_parser("launchd")
    p.add_argument("--install", action="store_true")
    p = sub.add_parser("process")
    p.add_argument("target")
    p.add_argument("--note")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--force", action="store_true")
    p.add_argument("--macparakeet-cli", default="macparakeet-cli")
    return root


def main():
    os.umask(0o077)
    args = parser().parse_args()
    try:
        result = asyncio.run(dispatch(args, Store(args.state_dir)))
        print(canonical({"ok": True, "schema_version": 1, "data": result}))
    except (AgentError, ValidationError, ValueError, OSError, KeyError, sqlite3.Error) as exc:
        if isinstance(exc, AgentError):
            error = {"code": exc.code, "message": str(exc), "details": exc.details}
        else:
            # Validation errors may contain transcript/key input; never echo them.
            error = {"code": "invalid_request", "message": "Invalid request or unavailable local resource"}
        print(canonical({"ok": False, "schema_version": 1, "error": error}))
        raise SystemExit(1)
