from __future__ import annotations

import contextlib
import json
import os
import sqlite3
import time
from pathlib import Path

from .models import AgentError, EnqueueRequest, NoteRef, Profile, Source, canonical, digest


class Store:
    def __init__(self, directory: Path):
        self.directory = directory.expanduser().resolve()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.directory, 0o700)
        self.db = sqlite3.connect(self.directory / "agent.sqlite", isolation_level=None, timeout=10)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS profiles(id TEXT PRIMARY KEY, payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY, payload TEXT NOT NULL, revision TEXT NOT NULL,
                vault TEXT NOT NULL, note_key TEXT, request TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS event_bindings(occurrence TEXT PRIMARY KEY, note TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, source_id TEXT NOT NULL, request TEXT NOT NULL,
                profile TEXT NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                available_at REAL NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
                error TEXT, details TEXT, note TEXT, prepared TEXT, result TEXT);
            CREATE INDEX IF NOT EXISTS jobs_queue ON jobs(state, available_at);
            CREATE TABLE IF NOT EXISTS note_state(key TEXT PRIMARY KEY, ref TEXT NOT NULL, blocks TEXT NOT NULL,
                source_ids TEXT NOT NULL, stale INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS stale_updates(key TEXT PRIMARY KEY, payload TEXT NOT NULL);
            PRAGMA user_version=1;
        """)
        # Upgrade development state without discarding queued work.
        if "revision" not in {r[1] for r in self.db.execute("PRAGMA table_info(event_bindings)")}:
            self.db.execute("ALTER TABLE event_bindings ADD COLUMN revision INTEGER NOT NULL DEFAULT 1")
        os.chmod(self.directory / "agent.sqlite", 0o600)

    @contextlib.contextmanager
    def transaction(self):
        nested = self.db.in_transaction
        self.db.execute("SAVEPOINT agent_write" if nested else "BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.execute("ROLLBACK TO agent_write" if nested else "ROLLBACK")
            if nested:
                self.db.execute("RELEASE agent_write")
            raise
        else:
            self.db.execute("RELEASE agent_write" if nested else "COMMIT")

    def profiles(self):
        default = self.db.execute("SELECT value FROM settings WHERE key='default_profile'").fetchone()
        profiles = [json.loads(row[0]) for row in self.db.execute("SELECT payload FROM profiles ORDER BY id")]
        return {"profiles": profiles, "fingerprints": {p["id"]: digest(Profile.model_validate(p)) for p in profiles}, "default_profile": default[0] if default else None}

    def profile(self, id: str | None) -> Profile:
        if not id:
            row = self.db.execute("SELECT value FROM settings WHERE key='default_profile'").fetchone()
            id = row[0] if row else None
        row = self.db.execute("SELECT payload FROM profiles WHERE id=?", (id,)).fetchone()
        if not row:
            raise AgentError("profile_required", "Configure and test a connection profile first")
        return Profile.model_validate_json(row[0])

    def save_profile(self, profile: Profile, default: bool = False):
        with self.transaction():
            self.db.execute("INSERT OR REPLACE INTO profiles VALUES (?,?)", (profile.id, canonical(profile)))
            if default:
                self.db.execute("INSERT OR REPLACE INTO settings VALUES ('default_profile',?)", (profile.id,))
        return self.profiles()

    def enqueue(self, request: EnqueueRequest):
        profile = self.profile(request.profile_id)
        if request.expected_profile_fingerprint is not None and request.expected_profile_fingerprint != digest(profile):
            raise AgentError("profile_changed", "The selected profile changed. Review the connection and explicitly reprocess this meeting.")
        request.profile_id = profile.id
        request.vault = str(Path(request.vault).expanduser().resolve())
        for note in (request.source.note, request.source.event_note):
            if note and Path(note.vault).resolve() != Path(request.vault):
                raise AgentError("vault_mismatch", "Selected note and configured vault differ")
        payload = canonical(request)
        revision = digest(request.source)
        id = digest([json.loads(payload), profile.model_dump(mode="json")])
        now = time.time()
        with self.transaction():
            duplicate = self.db.execute("SELECT * FROM jobs WHERE id=?", (id,)).fetchone()
            if duplicate:
                return self.job_dict(duplicate)
            if request.source.calendar and request.source.event_note:
                # Offline app hint seeds a missing association only. It is never an
                # explicit per-source note and cannot override a newer CLI binding.
                self.db.execute("INSERT OR IGNORE INTO event_bindings(occurrence,note,revision) VALUES (?,?,1)", (request.source.calendar.occurrence_key, canonical(request.source.event_note)))
            previous = self.db.execute("SELECT * FROM sources WHERE id=?", (request.source.id,)).fetchone()
            note_key = previous["note_key"] if previous else None
            if previous:
                old = Source.model_validate_json(previous["payload"])
                if request.source.binding_version < old.binding_version:
                    raise AgentError("stale_binding", "An older binding cannot replace the current selection")
                if request.source.updated_at and old.updated_at and request.source.updated_at < old.updated_at:
                    raise AgentError("stale_source", "An older transcript cannot replace the current version")
                if old.note != request.source.note or old.calendar != request.source.calendar or previous["vault"] != request.vault:
                    if note_key:
                        self.db.execute("UPDATE note_state SET stale=1 WHERE key=?", (note_key,))
                    note_key = None
            self.db.execute("INSERT OR REPLACE INTO sources VALUES (?,?,?,?,?,?)", (request.source.id, canonical(request.source), revision, request.vault, note_key, payload))
            self.db.execute("UPDATE jobs SET state='cancelled', error='Superseded by a newer source or binding', updated_at=? WHERE source_id=? AND state IN ('queued','processing','needs_action','error')", (now, request.source.id))
            self.db.execute("INSERT INTO jobs(id,source_id,request,profile,state,available_at,created_at,updated_at) VALUES (?,?,?,?,'queued',?,?,?)", (id, request.source.id, payload, canonical(profile), now, now, now))
        return self.job(id)

    def bind(self, source_id: str, note: NoteRef | None, calendar, binding_version: int | None = None):
        with self.transaction():
            row = self.db.execute("SELECT request FROM sources WHERE id=?", (source_id,)).fetchone()
            if not row:
                raise AgentError("source_missing", "Enqueue the transcript before binding it")
            request = EnqueueRequest.model_validate_json(row[0])
            if binding_version is not None and binding_version < request.source.binding_version:
                raise AgentError("stale_binding", "An older binding cannot replace the current selection")
            request.source.note = note
            request.source.calendar = calendar
            request.source.binding_version = binding_version if binding_version is not None else request.source.binding_version + 1
            if calendar and note:
                self.bind_event(calendar.occurrence_key, note)
            return self.enqueue(request)

    def bind_event(self, occurrence: str, note: NoteRef):
        with self.transaction():
            self.db.execute("INSERT INTO event_bindings(occurrence,note,revision) VALUES (?,?,1) ON CONFLICT(occurrence) DO UPDATE SET note=excluded.note,revision=event_bindings.revision+1", (occurrence, canonical(note)))
            # Explicit per-recording notes retain priority over event bindings.
            for row in self.db.execute("SELECT * FROM sources").fetchall():
                source = Source.model_validate_json(row["payload"])
                if source.calendar and source.calendar.occurrence_key == occurrence and source.note is None:
                    if row["note_key"]:
                        self.db.execute("UPDATE note_state SET stale=1 WHERE key=?", (row["note_key"],))
                    self.db.execute("UPDATE sources SET note_key=NULL WHERE id=?", (source.id,))

    def event_revisions(self, sources: list[Source]) -> dict[str, int]:
        result = {}
        for source in sources:
            if source.calendar and not source.note:
                key = source.calendar.occurrence_key
                row = self.db.execute("SELECT revision FROM event_bindings WHERE occurrence=?", (key,)).fetchone()
                result[key] = row[0] if row else 0
        return result

    def event_note(self, source: Source) -> NoteRef | None:
        if not source.calendar:
            return None
        row = self.db.execute("SELECT note FROM event_bindings WHERE occurrence=?", (source.calendar.occurrence_key,)).fetchone()
        return NoteRef.model_validate_json(row[0]) if row else None

    def merge_saved_binding(self, source: Source) -> Source:
        row = self.db.execute("SELECT payload FROM sources WHERE id=?", (source.id,)).fetchone()
        if row:
            old = Source.model_validate_json(row[0])
            source.note = old.note
            source.calendar = old.calendar
            source.binding_version = old.binding_version
        return source

    def job(self, id: str):
        row = self.db.execute("SELECT * FROM jobs WHERE id=?", (id,)).fetchone()
        if not row:
            raise AgentError("job_missing", "Job does not exist")
        return self.job_dict(row)

    @staticmethod
    def job_dict(row):
        value = {k: row[k] for k in ("id", "source_id", "state", "attempts", "created_at", "updated_at", "error")}
        for key in ("details", "note", "result"):
            value[key] = json.loads(row[key]) if row[key] else None
        return value

    def jobs(self, source_id: str | None = None):
        rows = self.db.execute("SELECT * FROM jobs WHERE (? IS NULL OR source_id=?) ORDER BY created_at DESC LIMIT 200", (source_id, source_id))
        return {"jobs": [self.job_dict(row) for row in rows]}

    def cancel(self, id: str):
        with self.transaction():
            self.db.execute("UPDATE jobs SET state='cancelled', updated_at=? WHERE id=? AND state!='done'", (time.time(), id))
        return self.job(id)

    def retry(self, id: str):
        with self.transaction():
            row = self.db.execute("SELECT * FROM jobs WHERE id=?", (id,)).fetchone()
            if not row:
                raise AgentError("job_missing", "Job does not exist")
            request = EnqueueRequest.model_validate_json(row["request"])
            current = self.db.execute("SELECT revision FROM sources WHERE id=?", (request.source.id,)).fetchone()
            if not current or current[0] != digest(request.source) or self.profile(request.profile_id) != Profile.model_validate_json(row["profile"]):
                raise AgentError("stale_job", "Re-enqueue with the current binding, transcript and profile")
            if row["state"] == "processing":
                raise AgentError("job_busy", "Job is already processing")
            if row["state"] == "done":
                return self.job_dict(row)
            if row["details"] and json.loads(row["details"]).get("code") in {"note_conflict", "stale_job"}:
                self.db.execute("UPDATE jobs SET prepared=NULL WHERE id=?", (id,))
            self.db.execute("UPDATE jobs SET state='queued', attempts=0, error=NULL, details=NULL, available_at=?, updated_at=? WHERE id=?", (time.time(), time.time(), id))
        return self.job(id)

    def recover(self):
        # Called only while holding the exclusive lifetime worker lock.
        self.db.execute("UPDATE jobs SET state='queued', available_at=? WHERE state='processing'", (time.time(),))

    def claim(self):
        with self.transaction():
            row = self.db.execute("SELECT * FROM jobs WHERE state='queued' AND available_at<=? ORDER BY created_at LIMIT 1", (time.time(),)).fetchone()
            if row:
                self.db.execute("UPDATE jobs SET state='processing', attempts=attempts+1, updated_at=? WHERE id=?", (time.time(), row["id"]))
                return dict(row)
        return None

    def check_current(self, job: dict, revisions: dict[str, str] | None = None, note_key: str | None = None, event_revisions: dict[str, int] | None = None):
        state = self.db.execute("SELECT state FROM jobs WHERE id=?", (job["id"],)).fetchone()
        request = EnqueueRequest.model_validate_json(job["request"])
        if not state or state[0] != "processing" or self.profile(request.profile_id) != Profile.model_validate_json(job["profile"]):
            raise AgentError("stale_job", "Job was cancelled or its provider profile changed")
        revisions = revisions or {request.source.id: digest(request.source)}
        for id, revision in revisions.items():
            row = self.db.execute("SELECT revision FROM sources WHERE id=?", (id,)).fetchone()
            if not row or row[0] != revision:
                raise AgentError("stale_job", "Transcript or binding changed during analysis")
        for occurrence, revision in (event_revisions or {}).items():
            row = self.db.execute("SELECT revision FROM event_bindings WHERE occurrence=?", (occurrence,)).fetchone()
            if (row[0] if row else 0) != revision:
                raise AgentError("stale_job", "Calendar event binding changed during analysis")
        if note_key:
            ids = {r[0] for r in self.db.execute("SELECT id FROM sources WHERE note_key=?", (note_key,))}
            if ids != set(revisions):
                raise AgentError("stale_job", "Meeting parts changed during analysis")

    def fail(self, job: dict, error: AgentError):
        current = self.job(job["id"])
        if current["state"] == "cancelled":
            return
        state = "cancelled" if error.code == "stale_job" else "needs_action"
        if error.retryable:
            state = "queued" if current["attempts"] < 4 else "error"
        elif error.code in {"invalid_output", "provider_error", "cli_error"}:
            state = "error"
        delay = min(300, 5 * 2 ** current["attempts"])
        self.db.execute("UPDATE jobs SET state=?,error=?,details=?,available_at=?,updated_at=? WHERE id=?", (state, str(error), canonical({"code": error.code, "detail": error.details}), time.time() + delay, time.time(), job["id"]))
