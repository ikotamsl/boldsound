from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path

from .models import AgentError, EnqueueRequest, NoteRef, Profile, Source, canonical, digest
from .providers import Provider, summarize
from .store import Store
from .vault import BLOCK, Vault, atomic_write, file_lock, replace_block, result_markdown, source_ids, text_hash, update_ids


class Worker:
    def __init__(self, store: Store, provider_factory=Provider):
        self.store, self.provider_factory = store, provider_factory

    async def once(self) -> bool:
        self.refresh_stale_notes()
        job = self.store.claim()
        if not job:
            return False
        try:
            await self.process(job)
        except AgentError as exc:
            self.store.fail(job, exc)
        except (OSError, ValueError) as exc:
            self.store.fail(job, AgentError("storage_error", "Local data could not be read or saved", details=type(exc).__name__))
        return True

    async def process(self, job: dict, *, dry_run: bool = False):
        store = self.store
        request = EnqueueRequest.model_validate_json(job["request"])
        vault = Vault(request.vault)
        store.check_current(job)
        if job["prepared"] and not dry_run:
            self.commit(job, json.loads(job["prepared"]), vault)
            return
        with store.transaction():
            store.check_current(job)
            selected_event_note = store.event_note(request.source)
            selected_event_revisions = store.event_revisions([request.source])
        path = vault.match(request.source, selected_event_note)
        ref = vault.reference(path) if path.exists() else NoteRef(vault=str(vault.root), path=str(path.relative_to(vault.root)))
        existed_at_start = path.exists()
        initial_text = path.read_text() if existed_at_start else vault.new_note(request.source)
        if not path.exists():
            from .vault import frontmatter
            data, _, _ = frontmatter(initial_text)
            ref.id = str(data["id"])
        known = next((r for r in store.db.execute("SELECT key,ref FROM note_state")
            if (lambda old: old.vault == ref.vault and ((ref.id and old.id == ref.id) or (not ref.id and old.path == ref.path)))(NoteRef.model_validate_json(r["ref"]))), None)
        key = known["key"] if known else digest([str(vault.root), ref.id or ref.path])
        with store.transaction():
            store.check_current(job, event_revisions=selected_event_revisions)
            previous = store.db.execute("SELECT note_key FROM sources WHERE id=?", (request.source.id,)).fetchone()[0]
            if previous and previous != key:
                store.db.execute("UPDATE note_state SET stale=1 WHERE key=?", (previous,))
            store.db.execute("UPDATE sources SET note_key=? WHERE id=?", (key, request.source.id))
            rows = store.db.execute("SELECT * FROM sources WHERE note_key=?", (key,)).fetchall()
            sources = sorted([Source.model_validate_json(r["payload"]) for r in rows], key=lambda s: (s.created_at, s.id))
            revisions = {r["id"]: r["revision"] for r in rows}
            event_revisions = store.event_revisions(sources)
        # A pre-existing multipart note must not lose unavailable parts.
        if path.exists():
            missing = set(source_ids(path.read_text())) - set(revisions)
            # IDs moved away explicitly are intentionally removed.
            missing = {id for id in missing if not store.db.execute("SELECT 1 FROM sources WHERE id=? AND note_key IS NOT ?", (id, key)).fetchone()}
            if missing:
                raise AgentError("missing_sources", "Enqueue all existing meeting parts before recomputing this note", details=sorted(missing))
        profile = Profile.model_validate_json(job["profile"])
        provider = self.provider_factory(profile, request.vault)
        result = await summarize(provider, sources, check_current=lambda: store.check_current(job, revisions, key, event_revisions))
        store.check_current(job, revisions, key, event_revisions)
        # Resolve again after model latency to follow ID-based renames.
        if ref.id and existed_at_start:
            path = vault.resolve(ref)
            ref = vault.reference(path)
        current = path.read_text() if path.exists() else None
        text = current if current is not None else initial_text
        expected_row = store.db.execute("SELECT blocks FROM note_state WHERE key=?", (key,)).fetchone()
        expected = json.loads(expected_row[0]) if expected_row else {}
        version = digest([revisions, profile.model_dump(mode="json"), request.processing_version])
        attendees, warnings = vault.attendees(sources)
        for kind, content in [("attendees", attendees), ("notes", result_markdown(result.result, sources))]:
            text = replace_block(text, kind, content, version, expected=expected.get(kind), force=request.force)
        text = update_ids(text, [s.id for s in sources])
        # New note acquires its stable ID before the first durable write.
        from .vault import frontmatter
        data, _, _ = frontmatter(text)
        ref.id = str(data["id"]) if data.get("id") else None
        prepared = {"ref": ref.model_dump(), "key": key, "revisions": revisions, "event_revisions": event_revisions,
            "before": text_hash(current) if current is not None else None, "text": text,
            "result": {"provider": profile.provider, "model": result.model, "usage": result.usage, "warnings": warnings, "version": version},
            "blocks": {m[1]: m[0] for m in BLOCK.finditer(text)}}
        if dry_run:
            return prepared
        with store.transaction():
            store.check_current(job, revisions, key, event_revisions)
            store.db.execute("UPDATE jobs SET prepared=? WHERE id=?", (canonical(prepared), job["id"]))
        self.commit(job, prepared, vault)

    def commit(self, job, prepared, vault):
        store = self.store
        ref = NoteRef.model_validate(prepared["ref"])
        path = vault.path(ref.path)
        # Lock is kept outside the vault, and SQLite serializes bind/cancel with commit.
        with file_lock(store.directory / "locks" / (prepared["key"] + ".lock")), store.transaction():
            store.check_current(job, prepared["revisions"], prepared["key"], prepared.get("event_revisions", {}))
            if ref.id:
                # First write creates the note; later writes can follow a rename.
                try:
                    path = vault.resolve(ref)
                except AgentError:
                    if prepared["before"] is not None or path.exists():
                        raise
            current = path.read_text() if path.exists() else None
            if current != prepared["text"]:
                atomic_write(path, prepared["text"], prepared["before"], store.directory / "backups")
            ref.path = str(path.relative_to(vault.root))
            # Preserve the assigned key; stable reference is used to resolve renames.
            store.db.execute("INSERT OR REPLACE INTO note_state VALUES (?,?,?,?,0)", (prepared["key"], canonical(ref), canonical(prepared["blocks"]), canonical(list(prepared["revisions"]))))
            store.db.execute("UPDATE jobs SET state='done',error=NULL,details=NULL,note=?,result=?,updated_at=? WHERE id=?", (canonical(ref), canonical(prepared["result"]), time.time(), job["id"]))
            for id in prepared["revisions"]:
                row = store.db.execute("SELECT payload FROM sources WHERE id=?", (id,)).fetchone()
                source = Source.model_validate_json(row[0])
                if source.calendar:
                    store.db.execute("INSERT OR IGNORE INTO event_bindings(occurrence,note) VALUES (?,?)", (source.calendar.occurrence_key, canonical(ref)))

    def refresh_stale_notes(self):
        store = self.store
        for row in store.db.execute("SELECT * FROM note_state WHERE stale=1").fetchall():
            ref = NoteRef.model_validate_json(row["ref"])
            try:
                vault = Vault(ref.vault)
                with file_lock(store.directory / "locks" / (row["key"] + ".lock")):
                    with store.transaction():
                        journal = store.db.execute("SELECT payload FROM stale_updates WHERE key=?", (row["key"],)).fetchone()
                        if journal:
                            prepared = json.loads(journal[0])
                        else:
                            path = vault.resolve(ref)
                            text = path.read_text()
                            expected = json.loads(row["blocks"])
                            current = next((m for m in BLOCK.finditer(text) if m[1] == "notes"), None)
                            if not current:
                                raise AgentError("note_conflict", "Old note managed block was removed")
                            remaining = sorted(r[0] for r in store.db.execute("SELECT id FROM sources WHERE note_key=?", (row["key"],)))
                            warning = "⚠ Итог устарел: запись перенесена в другую заметку. Пересчитайте оставшиеся части.\n\n"
                            content = current[4] if current[4].startswith(warning) else warning + current[4]
                            updated = replace_block(text, "notes", content, digest([row["key"], remaining, "stale"]), expected=expected.get("notes"))
                            updated = update_ids(updated, remaining)
                            prepared = {"before": text_hash(text), "text": updated, "remaining": remaining,
                                "blocks": {m[1]: m[0] for m in BLOCK.finditer(updated)}}
                            store.db.execute("INSERT INTO stale_updates VALUES (?,?)", (row["key"], canonical(prepared)))
                    # Persist the proposed stale edit before touching the file so a
                    # crash after replacement can acknowledge the identical result.
                    with store.transaction():
                        path = vault.resolve(ref)
                        if path.read_text() != prepared["text"]:
                            atomic_write(path, prepared["text"], prepared["before"], store.directory / "backups")
                        remaining = sorted(r[0] for r in store.db.execute("SELECT id FROM sources WHERE note_key=?", (row["key"],)))
                        stale = 2 if remaining == prepared["remaining"] else 1
                        store.db.execute("UPDATE note_state SET stale=?,blocks=?,source_ids=? WHERE key=?", (stale, canonical(prepared["blocks"]), canonical(prepared["remaining"]), row["key"]))
                        store.db.execute("DELETE FROM stale_updates WHERE key=?", (row["key"],))
            except (AgentError, OSError):
                # Keep the durable stale flag and surface it through doctor/jobs.
                continue

    async def run(self, once: bool = False):
        # Nonblocking lock so a second launchd/manual worker exits visibly.
        import fcntl
        with (self.store.directory / "worker.lock").open("a") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise AgentError("worker_running", "One worker is already running") from exc
            self.store.recover()
            while True:
                worked = await self.once()
                if once:
                    break
                if not worked:
                    await asyncio.sleep(2)
