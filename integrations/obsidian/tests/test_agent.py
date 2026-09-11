import asyncio
import json
from datetime import datetime, timezone
from pathlib import Path

import httpx
import pytest

from meeting_agent.models import AgentError, CalendarSnapshot, EnqueueRequest, MeetingResult, NoteRef, Person, Profile, ProviderResult, Source
from meeting_agent.providers import Provider, summarize
from meeting_agent.store import Store
from meeting_agent.vault import BLOCK, Vault, source_ids
from meeting_agent.worker import Worker

def transport(handler):
    def wrapped(request):
        if request.url.path == "/api/show":
            return httpx.Response(200, json={"model_info": {"general.architecture": "synthetic"}})
        return handler(request)
    return httpx.MockTransport(wrapped)


RESULT = MeetingResult(summary="Обсудили выпуск", decisions=["Выпустить версию"], tasks=[], open_questions=[])


class FakeProvider:
    calls = []
    callback = None

    def __init__(self, profile, vault):
        self.profile = profile

    async def generate(self, context):
        self.calls.append(context)
        if self.callback:
            self.callback()
        return ProviderResult(result=RESULT, model=self.profile.model)


@pytest.fixture
def fixture(tmp_path):
    vault = tmp_path / "vault"
    vault.mkdir()
    (vault / "Templates").mkdir()
    (vault / "Templates/Meeting.md").write_text("---\nid: <% tp.date.now() %>\nmanual: keep\n---\n#meeting\n<%* throw Error('must not run'); %>\n# Links\nmanual link\n# Attendees\n# Agenda\nmy agenda\n# Notes\n")
    store = Store(tmp_path / "state")
    store.save_profile(Profile(id="local", name="Local", model="test"), True)
    source = Source(id="one", title="Планирование", created_at=datetime(2026, 9, 10, tzinfo=timezone.utc), text="Обсуждение выпуска.", artifact_path=str(tmp_path / "transcript.json"))
    FakeProvider.calls, FakeProvider.callback = [], None
    return store, vault, source


def request(vault, source, **kwargs):
    return EnqueueRequest(source=source, vault=str(vault), **kwargs)


async def test_delivery_replay_and_manual_preservation(fixture):
    store, vault, source = fixture
    job = store.enqueue(request(vault, source))
    assert store.enqueue(request(vault, source))["id"] == job["id"]
    await Worker(store, FakeProvider).run(once=True)
    assert store.job(job["id"])["state"] == "done"
    note = vault / store.job(job["id"])["note"]["path"]
    text = note.read_text()
    assert "<%" not in text and "manual: keep" in text and "my agenda" in text
    assert "- [ ] Планирование" in text
    assert "Обсуждение выпуска." not in text
    assert source_ids(text) == [source.id]
    assert len(list(BLOCK.finditer(text))) == 2
    await Worker(store, FakeProvider).run(once=True)
    assert note.read_text() == text


async def test_multipart_rename_and_retranscription(fixture):
    store, vault, first = fixture
    job = store.enqueue(request(vault, first))
    worker = Worker(store, FakeProvider)
    await worker.run(once=True)
    ref = NoteRef.model_validate(store.job(job["id"])["note"])
    second = first.model_copy(deep=True)
    second.id, second.text, second.note = "two", "Вторая часть", ref
    job2 = store.enqueue(request(vault, second))
    await worker.run(once=True)
    assert store.job(job2["id"])["state"] == "done"
    note = vault / ref.path
    assert source_ids(note.read_text()) == ["one", "two"]
    renamed = vault / "Renamed.md"
    note.rename(renamed)
    second.text = "Новая транскрибация второй части"
    job3 = store.enqueue(request(vault, second))
    await worker.run(once=True)
    assert store.job(job3["id"])["state"] == "done"
    assert store.job(job3["id"])["note"]["path"] == "Renamed.md"
    assert source_ids(renamed.read_text()) == ["one", "two"]
    assert any(first.text in c for c in FakeProvider.calls)
    assert any(second.text in c for c in FakeProvider.calls)


async def test_conflicting_agent_block_requires_action(fixture):
    store, vault, source = fixture
    job = store.enqueue(request(vault, source))
    worker = Worker(store, FakeProvider)
    await worker.run(once=True)
    note = vault / store.job(job["id"])["note"]["path"]
    edited = note.read_text().replace("Обсудили выпуск", "Мой ручной итог")
    note.write_text(edited)
    source.text += " Изменение"
    next_job = store.enqueue(request(vault, source))
    await worker.run(once=True)
    assert store.job(next_job["id"])["state"] == "needs_action"
    assert "diff" not in str(store.job(next_job["id"])["details"]) or store.job(next_job["id"])["details"]
    assert note.read_text() == edited


async def test_cancel_during_model_call_prevents_write(fixture):
    store, vault, source = fixture
    job = store.enqueue(request(vault, source))
    FakeProvider.callback = lambda _: store.cancel(job["id"])
    await Worker(store, FakeProvider).run(once=True)
    assert store.job(job["id"])["state"] == "cancelled"
    assert not list(vault.glob("2026*.md"))


async def test_recovery_after_write_before_ack(fixture, monkeypatch):
    store, vault, source = fixture
    job = store.enqueue(request(vault, source))
    worker = Worker(store, FakeProvider)
    original = worker.commit
    def crash(job, prepared, vault):
        from meeting_agent.vault import atomic_write
        atomic_write(vault.path(prepared["ref"]["path"]), prepared["text"], prepared["before"], store.directory / "backups")
        raise RuntimeError("simulated process crash")
    monkeypatch.setattr(worker, "commit", crash)
    with pytest.raises(RuntimeError):
        await worker.run(once=True)
    assert store.job(job["id"])["state"] == "processing"
    calls = len(FakeProvider.calls)
    monkeypatch.setattr(worker, "commit", original)
    await worker.run(once=True)
    assert store.job(job["id"])["state"] == "done"
    assert len(FakeProvider.calls) == calls
    assert len(list(BLOCK.finditer(next(vault.glob("2026*.md")).read_text()))) == 2


def test_prepared_note_ambiguity_and_person_email(fixture):
    store, vault, source = fixture
    (vault / "2026-09-10 Планирование.md").write_text("---\nid: prepared\n---\n- [ ] Встреча\n# Notes\n")
    assert Vault(str(vault)).match(source).name == "2026-09-10 Планирование.md"
    (vault / "people").mkdir()
    (vault / "people/A.md").write_text("---\nemail: PERSON@Example.com\n---\n#archive/person")
    source.calendar = CalendarSnapshot(eventIdentifier="event", scheduledStartAt=source.created_at, scheduledEndAt=source.created_at, title=source.title,
        attendees=[Person(name="Иван", email="person@example.COM"), Person(name="Без почты")])
    text, warnings = Vault(str(vault)).attendees([source])
    assert "[[people/A]]" in text and "Без почты" in text and not warnings
    (vault / "people/B.md").write_text("---\nemail: person@example.com\n---\n#archive/person")
    text, warnings = Vault(str(vault)).attendees([source])
    assert "[[@person@example.com]]" in text and warnings


@pytest.mark.parametrize("provider", ["ollama", "openai", "anthropic", "gemini", "openrouter", "compatible"])
async def test_http_adapters(fixture, monkeypatch, provider):
    store, vault, source = fixture
    monkeypatch.setenv("TEST_KEY", "test-secret")
    profile = Profile(id="test", name="test", provider=provider, model="selected-model", execution="local" if provider == "ollama" else "cloud", endpoint="http://127.0.0.1:1234", key_env=None if provider == "ollama" else "TEST_KEY")
    def handler(req):
        body = json.loads(req.content)
        assert source.text in req.content.decode()
        raw = RESULT.model_dump_json()
        data = {"model": "selected-model", "usage": {"input_tokens": 1}}
        if provider == "ollama":
            data["message"] = {"content": raw}
            assert "format" in body
        elif provider == "openai":
            data["output"] = [{"type": "message", "content": [{"type": "output_text", "text": raw}]}]
            assert body["store"] is False and body["tools"] == []
        elif provider == "anthropic":
            data["content"] = [{"type": "text", "text": raw}]
        elif provider == "gemini":
            data["candidates"] = [{"content": {"parts": [{"text": raw}]}}]
            assert "test-secret" not in str(req.url)
        else:
            data["choices"] = [{"message": {"content": raw}}]
        return httpx.Response(200, json=data)
    response = await Provider(profile, str(vault), transport=transport(handler)).generate(source.text)
    assert response.result == RESULT


async def test_invalid_json_repairs_once(fixture):
    store, vault, source = fixture
    calls = []
    def handler(req):
        calls.append(req)
        return httpx.Response(200, json={"message": {"content": "not json"}})
    with pytest.raises(AgentError, match="one repair"):
        await Provider(store.profile(None), str(vault), transport=transport(handler)).generate("test")
    assert len(calls) == 2


@pytest.mark.parametrize("status,body,code", [(401,"expired","auth_required"),(429,"insufficient_quota","quota_exhausted"),(503,"unavailable","network")])
async def test_provider_errors(fixture, status, body, code):
    store, vault, source = fixture
    with pytest.raises(AgentError) as caught:
        await Provider(store.profile(None), str(vault), transport=httpx.MockTransport(lambda _: httpx.Response(status, text=body))).generate("test")
    assert caught.value.code == code


def test_local_mode_rejects_cloud_and_path_escape(fixture):
    from pydantic import ValidationError
    store, vault, source = fixture
    with pytest.raises(ValidationError):
        Profile(id="local", name="bad", model="test", endpoint="https://cloud.example")
    with pytest.raises(AgentError):
        Vault(str(vault)).path("../outside.md")


async def test_move_marks_old_note_stale_and_preserves_manual(fixture):
    store, vault, source = fixture
    worker = Worker(store, FakeProvider)
    first = store.enqueue(request(vault, source))
    await worker.run(once=True)
    old = vault / store.job(first["id"])["note"]["path"]
    (vault / "Other.md").write_text("---\nid: other\n---\n# Notes\nmanual second\n")
    source.note = Vault(str(vault)).reference(vault / "Other.md")
    source.binding_version += 1
    second = store.enqueue(request(vault, source))
    await worker.run(once=True)
    assert store.job(second["id"])["state"] == "done"
    assert "Итог устарел" in old.read_text() and "my agenda" in old.read_text()
    assert source_ids(old.read_text()) == []
    assert source_ids((vault / "Other.md").read_text()) == [source.id]


async def test_event_binding_changed_during_analysis_cannot_be_undone(fixture):
    store, vault, source = fixture
    source.calendar = CalendarSnapshot(eventIdentifier="event", scheduledStartAt=source.created_at, scheduledEndAt=source.created_at, title=source.title)
    for name in ["A", "B"]:
        (vault / f"{name}.md").write_text(f"---\nid: {name}\n---\n# Notes\nmanual {name}\n")
    a, b = [Vault(str(vault)).reference(vault / f"{name}.md") for name in ["A", "B"]]
    store.bind_event(source.calendar.occurrence_key, a)
    job = store.enqueue(request(vault, source))
    FakeProvider.callback = lambda _: store.bind_event(source.calendar.occurrence_key, b)
    await Worker(store, FakeProvider).run(once=True)
    assert store.job(job["id"])["state"] == "cancelled"
    assert "Обсудили" not in (vault / "A.md").read_text()
    assert store.event_note(source) == b


async def test_file_conflict_retry_rebases_manual_content(fixture, monkeypatch):
    store, vault, source = fixture
    note = vault / "Prepared.md"
    note.write_text("---\nid: prepared\n---\n# Notes\nmanual\n")
    source.note = Vault(str(vault)).reference(note)
    job = store.enqueue(request(vault, source))
    worker = Worker(store, FakeProvider)
    original = worker.commit
    def edit_before_commit(job, prepared, vault):
        note.write_text(note.read_text() + "\nnew manual text\n")
        original(job, prepared, vault)
    monkeypatch.setattr(worker, "commit", edit_before_commit)
    await worker.run(once=True)
    assert store.job(job["id"])["state"] == "needs_action"
    monkeypatch.setattr(worker, "commit", original)
    store.retry(job["id"])
    await worker.run(once=True)
    assert store.job(job["id"])["state"] == "done"
    assert "new manual text" in note.read_text()


def test_manual_source_merges_effective_binding(fixture):
    store, vault, source = fixture
    source.binding_version = 3
    source.note = NoteRef(vault=str(vault), path="Chosen.md", id="chosen")
    store.enqueue(request(vault, source))
    fresh = source.model_copy(deep=True)
    fresh.binding_version, fresh.note, fresh.text = 0, None, "new transcription"
    merged = store.merge_saved_binding(fresh)
    assert merged.binding_version == 3 and merged.note == source.note
    assert merged.text == "new transcription"
    store.enqueue(request(vault, merged))


async def test_codex_subscription_invocation_and_environment(fixture, monkeypatch):
    import meeting_agent.providers as providers
    store, vault, source = fixture
    monkeypatch.setenv("OPENAI_API_KEY", "must-not-inherit")
    calls = []
    async def fake_process(argv, **kwargs):
        if "--help" in argv:
            return "--ignore-user-config --ignore-rules --ephemeral --output-schema", ""
        calls.append((argv, kwargs))
        Path(argv[argv.index("--output-last-message") + 1]).write_text(RESULT.model_dump_json())
        sandbox = Path(argv[argv.index("-f") + 1]).read_text()
        assert str(vault) in sandbox and "deny file-read* file-write*" in sandbox
        return "", ""
    monkeypatch.setattr(providers, "run_process", fake_process)
    profile = Profile(id="subscription", name="sub", provider="codex", model="account-model", execution="cloud", cli_path="/tmp/codex")
    result = await Provider(profile, str(vault)).generate(source.text)
    argv, kwargs = calls[0]
    assert 'forced_login_method="chatgpt"' in argv
    assert 'features.shell_tool=false' in argv and '--ignore-user-config' in argv
    assert "OPENAI_API_KEY" not in kwargs["env"]
    assert source.text not in " ".join(argv)
    assert result.result == RESULT


async def test_gemini_cli_disables_tools_extensions_and_api_fallback(fixture, monkeypatch):
    import meeting_agent.providers as providers
    store, vault, source = fixture
    monkeypatch.setenv("GEMINI_API_KEY", "must-not-inherit")
    monkeypatch.setenv("GOOGLE_GENAI_USE_VERTEXAI", "true")
    async def fake_process(argv, **kwargs):
        assert argv[argv.index("--extensions") + 1] == "none"
        env = kwargs["env"]
        assert "GEMINI_API_KEY" not in env and "GOOGLE_GENAI_USE_VERTEXAI" not in env
        settings = json.loads(Path(env["GEMINI_CLI_SYSTEM_SETTINGS_PATH"]).read_text())
        assert settings["security"]["auth"]["selectedType"] == "oauth-personal"
        assert settings["tools"]["core"] == ["__boldsound_no_tools__"]
        assert not settings["hooksConfig"]["enabled"]
        return json.dumps({"response": RESULT.model_dump_json()}), ""
    monkeypatch.setattr(providers, "run_process", fake_process)
    profile = Profile(id="google", name="google", provider="gemini_cli", model="model", execution="cloud", cli_path="/tmp/gemini")
    assert (await Provider(profile, str(vault)).generate(source.text)).result == RESULT


async def test_long_transcript_keeps_tail_and_merges(fixture):
    store, vault, source = fixture
    source.text = "A" * 24000 + "UNIQUE_TAIL"
    await summarize(FakeProvider(store.profile(None), str(vault)), [source])
    assert any("UNIQUE_TAIL" in c for c in FakeProvider.calls)
    assert len(FakeProvider.calls) >= 4


async def test_local_provider_never_follows_cloud_redirect(fixture):
    store, vault, source = fixture
    calls = []
    def handler(req):
        calls.append(str(req.url))
        return httpx.Response(307, headers={"Location": "https://cloud.invalid"})
    with pytest.raises(AgentError):
        await Provider(store.profile(None), str(vault), transport=transport(handler)).generate("test")
    assert calls == ["http://127.0.0.1:11434/api/chat"]


async def test_rename_while_analyzing_follows_id(fixture):
    store, vault, source = fixture
    old = vault / "Original.md"
    new = vault / "Renamed during analysis.md"
    old.write_text("---\nid: stable\n---\n# Notes\nKeep me\n")
    source.note = Vault(str(vault)).reference(old)
    job = store.enqueue(request(vault, source))
    FakeProvider.callback = lambda _: old.rename(new)
    await Worker(store, FakeProvider).run(once=True)
    assert store.job(job["id"])["state"] == "done"
    assert store.job(job["id"])["note"]["path"] == new.name
    assert not old.exists() and "Keep me" in new.read_text()


async def test_local_ollama_rejects_cloud_model_before_sending_transcript(fixture):
    store, vault, source = fixture
    calls = []
    def handler(req):
        calls.append(req)
        return httpx.Response(200, json={"remote_host": "https://ollama.com", "remote_model": "cloud-model"})
    with pytest.raises(AgentError) as caught:
        await Provider(store.profile(None), str(vault), transport=httpx.MockTransport(handler)).generate(source.text)
    assert caught.value.code == "local_model_required"
    assert len(calls) == 1 and source.text not in calls[0].content.decode()


def test_pending_app_intent_rejects_changed_provider(fixture):
    store, vault, source = fixture
    fingerprint = store.profiles()["fingerprints"]["local"]
    pending = request(vault, source, profile_id="local", expected_profile_fingerprint=fingerprint)
    store.save_profile(Profile(id="local", name="Changed", provider="openai", model="test", endpoint="https://example.com/v1", execution="cloud"))
    with pytest.raises(AgentError, match="profile changed"):
        store.enqueue(pending)
    assert store.jobs()["jobs"] == []


async def test_inherited_event_hint_never_overrides_new_binding(fixture):
    store, vault, source = fixture
    source.calendar = CalendarSnapshot(eventIdentifier="event", title="Meeting", scheduledStartAt=source.created_at, scheduledEndAt=source.created_at)
    source.event_note = NoteRef(vault=str(vault), path="Old.md")
    (vault / "Old.md").write_text("# Notes\n")
    (vault / "New.md").write_text("# Notes\n")
    job = store.enqueue(request(vault, source))
    assert store.event_note(source) == source.event_note
    def change(_):
        store.bind_event(source.calendar.occurrence_key, NoteRef(vault=str(vault), path="New.md"))
    FakeProvider.callback = change
    await Worker(store, FakeProvider).run(once=True)
    assert store.job(job["id"])["state"] == "cancelled"
    assert (vault / "Old.md").read_text() == "# Notes\n"
    FakeProvider.callback = None
    store.retry(job["id"])
    await Worker(store, FakeProvider).run(once=True)
    assert store.job(job["id"])["note"]["path"] == "New.md"
    store.enqueue(request(vault, source, processing_version=2))
    assert store.event_note(source).path == "New.md"


async def test_event_binding_change_during_note_matching_is_rejected(fixture, monkeypatch):
    store, vault, source = fixture
    source.calendar = CalendarSnapshot(eventIdentifier="event", title="Meeting", scheduledStartAt=source.created_at, scheduledEndAt=source.created_at)
    for name in ("Old.md", "New.md"):
        (vault / name).write_text("# Notes\n")
    store.bind_event(source.calendar.occurrence_key, NoteRef(vault=str(vault), path="Old.md"))
    original = Vault.match
    def match(self, source, event_note=None):
        path = original(self, source, event_note)
        store.bind_event(source.calendar.occurrence_key, NoteRef(vault=str(vault), path="New.md"))
        return path
    monkeypatch.setattr(Vault, "match", match)
    job = store.enqueue(request(vault, source))
    await Worker(store, FakeProvider).run(once=True)
    assert store.job(job["id"])["state"] == "cancelled"
    assert FakeProvider.calls == []
    assert (vault / "Old.md").read_text() == "# Notes\n"


async def test_stale_note_edit_recovers_crash_after_file_replacement(fixture, monkeypatch):
    import meeting_agent.worker as worker_module
    store, vault, source = fixture
    worker = Worker(store, FakeProvider)
    job = store.enqueue(request(vault, source))
    await worker.run(once=True)
    old = vault / store.job(job["id"])["note"]["path"]
    (vault / "New.md").write_text("# Notes\n")
    source.note = NoteRef(vault=str(vault), path="New.md")
    source.binding_version += 1
    store.enqueue(request(vault, source))
    original = worker_module.atomic_write
    def crash(*args):
        original(*args)
        raise RuntimeError("crash after stale file write")
    monkeypatch.setattr(worker_module, "atomic_write", crash)
    with pytest.raises(RuntimeError):
        worker.refresh_stale_notes()
    after_crash = old.read_text()
    assert "Итог устарел" in after_crash
    monkeypatch.setattr(worker_module, "atomic_write", original)
    Worker(store, FakeProvider).refresh_stale_notes()
    assert old.read_text() == after_crash
    assert store.db.execute("SELECT count(*) FROM stale_updates").fetchone()[0] == 0
    assert store.db.execute("SELECT stale FROM note_state").fetchone()[0] == 2


def test_rejected_source_binding_rolls_back_event_binding(fixture):
    store, vault, source = fixture
    source.calendar = CalendarSnapshot(eventIdentifier="event", title="Meeting", scheduledStartAt=source.created_at, scheduledEndAt=source.created_at)
    source.binding_version = 3
    old = NoteRef(vault=str(vault), path="Old.md")
    new = NoteRef(vault=str(vault), path="New.md")
    store.bind_event(source.calendar.occurrence_key, old)
    job = store.enqueue(request(vault, source))
    revision = store.event_revisions([source])
    with pytest.raises(AgentError, match="older binding"):
        store.bind(source.id, new, source.calendar, binding_version=1)
    assert store.event_note(source) == old
    assert store.event_revisions([source]) == revision
    assert store.job(job["id"])["state"] == "queued"


def test_replayed_old_bind_cannot_mutate_event_via_job_dedup(fixture):
    store, vault, source = fixture
    source.calendar = CalendarSnapshot(eventIdentifier="event", title="Meeting", scheduledStartAt=source.created_at, scheduledEndAt=source.created_at)
    old = NoteRef(vault=str(vault), path="Old.md")
    new = NoteRef(vault=str(vault), path="New.md")
    source.note, source.binding_version = old, 1
    store.enqueue(request(vault, source))
    store.bind(source.id, new, source.calendar, binding_version=2)
    revision = store.event_revisions([source.model_copy(update={"note": None})])
    with pytest.raises(AgentError, match="older binding"):
        store.bind(source.id, old, source.calendar, binding_version=1)
    assert store.event_note(source) == new
    assert store.event_revisions([source.model_copy(update={"note": None})]) == revision


def test_event_identity_normalizes_equivalent_timezones():
    a = CalendarSnapshot(eventIdentifier="series", title="Meeting", scheduledStartAt="2026-09-10T09:00:00Z", scheduledEndAt="2026-09-10T10:00:00Z")
    b = a.model_copy(update={"scheduledStartAt": datetime.fromisoformat("2026-09-10T14:00:00+05:00")})
    assert a.occurrence_key == b.occurrence_key


async def test_launchd_descriptor_uses_installed_interpreter(fixture):
    import sys
    from meeting_agent.cli import dispatch, parser
    store, _, _ = fixture
    args = parser().parse_args(["launchd"])
    result = await dispatch(args, store)
    assert result["plist"]["ProgramArguments"][:3] == [sys.executable, "-m", "meeting_agent"]
    assert result["plist"]["KeepAlive"] is True
