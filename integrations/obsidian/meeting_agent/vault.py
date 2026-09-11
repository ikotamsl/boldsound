from __future__ import annotations

import contextlib
import difflib
import fcntl
import hashlib
import io
import os
import re
import tempfile
import unicodedata
import uuid
from pathlib import Path
from urllib.parse import quote

from ruamel.yaml import YAML

from .models import AgentError, MeetingResult, NoteRef, Source


def text_hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def normalized(text: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", text).casefold().split())


def frontmatter(text: str):
    match = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|$)", text, re.S)
    yaml = YAML(typ="rt")
    yaml.preserve_quotes = True
    try:
        value = yaml.load(match[1]) if match else {}
        if value is None:
            value = {}
        if not isinstance(value, dict):
            raise ValueError("Frontmatter must be a mapping")
    except Exception as exc:
        raise AgentError("note_yaml", "Invalid YAML frontmatter; select or repair the note") from exc
    return value, match, yaml


def update_ids(text: str, ids: list[str]) -> str:
    data, match, yaml = frontmatter(text)
    data["macparakeet_ids"] = ids
    # The legacy singular field is read-compatible; avoid retaining a moved source.
    if "macparakeet_id" in data and str(data["macparakeet_id"]) not in ids:
        del data["macparakeet_id"]
    stream = io.StringIO()
    yaml.dump(data, stream)
    header = "---\n" + stream.getvalue() + "---\n"
    return header + (text[match.end():] if match else "\n" + text)


def source_ids(text: str) -> list[str]:
    data, _, _ = frontmatter(text)
    ids = data.get("macparakeet_ids") or []
    if not isinstance(ids, list):
        raise AgentError("note_yaml", "macparakeet_ids must be a list")
    legacy = data.get("macparakeet_id")
    return list(dict.fromkeys([str(x).casefold() for x in ids] + ([str(legacy).casefold()] if legacy else [])))


def safe_text(value: str) -> str:
    # Prevent model/calendar strings from introducing managed markers or headings.
    return value.replace("<!--", "&lt;!--").replace("-->", "--&gt;").replace("\r", " ").replace("\n", " ")


class Vault:
    def __init__(self, root: str):
        self.root = Path(root).expanduser().resolve()
        if not self.root.is_dir():
            raise AgentError("vault_unavailable", "Obsidian vault is unavailable")

    def path(self, relative: str) -> Path:
        candidate = self.root / relative
        resolved = candidate.resolve()
        if not resolved.is_relative_to(self.root) or resolved.suffix.lower() != ".md":
            raise AgentError("unsafe_path", "Note must be a Markdown file inside the configured vault")
        # Symlinks would otherwise let a check/replace change a different target.
        if any(p.is_symlink() for p in [candidate, *candidate.parents] if p != self.root.parent):
            raise AgentError("unsafe_path", "Symlink notes and vault paths are not supported")
        return resolved

    def notes(self):
        for directory, dirs, files in os.walk(self.root, followlinks=False):
            dirs[:] = sorted(d for d in dirs if not d.startswith(".") and not (Path(directory) / d).is_symlink())
            for name in sorted(files):
                path = Path(directory) / name
                if path.suffix.lower() == ".md" and not path.is_symlink() and not name.startswith("."):
                    yield path

    def reference(self, path: Path) -> NoteRef:
        data, _, _ = frontmatter(path.read_text())
        return NoteRef(vault=str(self.root), path=str(path.relative_to(self.root)), id=str(data["id"]) if data.get("id") else None)

    def resolve(self, ref: NoteRef) -> Path:
        if Path(ref.vault).resolve() != self.root:
            raise AgentError("vault_mismatch", "Selected note belongs to another vault")
        path = self.path(ref.path)
        if ref.id:
            matches = []
            for note in self.notes():
                try:
                    if self.reference(note).id == ref.id:
                        matches.append(note)
                except AgentError:
                    continue
            if len(matches) != 1:
                raise AgentError("note_selection", "Note ID is missing or ambiguous; choose the note again", details=[str(p.relative_to(self.root)) for p in matches])
            return matches[0]
        if not path.exists():
            raise AgentError("note_selection", "Selected note was moved or is unavailable; choose it again")
        return path

    def match(self, source: Source, event_note: NoteRef | None = None) -> Path:
        if source.note or event_note:
            return self.resolve(source.note or event_note)
        id_matches, exact_matches = [], []
        date = (source.calendar.scheduledStartAt if source.calendar else source.created_at).astimezone().strftime("%Y-%m-%d")
        title = source.calendar.title if source.calendar else source.title
        for path in self.notes():
            if "Templates" in path.relative_to(self.root).parts:
                continue
            try:
                contents = path.read_text()
                if source.id in source_ids(contents):
                    id_matches.append(path)
                if normalized(path.stem) == normalized(f"{date} {title}"):
                    exact_matches.append(path)
            except AgentError:
                continue
        for candidates in (id_matches, exact_matches):
            if len(candidates) > 1:
                raise AgentError("note_selection", "Several notes match; choose a note", details=[str(p.relative_to(self.root)) for p in candidates])
            if candidates:
                return candidates[0]
        title = re.sub(r'[/\\:*?"<>|\x00-\x1f]', " ", title).strip(" .")[:150] or "Встреча"
        path = self.path(f"{date} {title}.md")
        if path.exists():
            raise AgentError("note_selection", "Generated filename is occupied; choose the note explicitly")
        return path

    def new_note(self, source: Source) -> str:
        template = self.root / "Templates" / "Meeting.md"
        text = template.read_text() if template.is_file() else "---\nid:\n---\n\n#meeting\n\n# Links\n\n# Attendees\n\n# Agenda\n\n# Notes\n"
        text = re.sub(r"<%.*?%>", "", text, flags=re.S)
        data, match, yaml = frontmatter(text)
        data["id"] = str(uuid.uuid4())
        stream = io.StringIO()
        yaml.dump(data, stream)
        text = "---\n" + stream.getvalue() + "---\n" + (text[match.end():] if match else text)
        when = (source.calendar.scheduledStartAt if source.calendar else source.created_at).astimezone()
        title = source.calendar.title if source.calendar else source.title
        line = f"- [ ] {safe_text(title)} (@{when.strftime('%Y-%m-%d %H:%M')})\n"
        if re.search(r"^#meeting\s*$", text, re.M):
            text = re.sub(r"^#meeting[^\S\n]*\n", lambda _: "#meeting\n" + line, text, count=1, flags=re.M)
        else:
            text += "\n#meeting\n" + line
        return text

    def attendees(self, sources: list[Source]) -> tuple[str, list[str]]:
        people_by_email: dict[str, list[Path]] = {}
        for path in self.notes():
            try:
                text = path.read_text()
                data, _, _ = frontmatter(text)
            except AgentError:
                continue
            tags = data.get("tags") or []
            if isinstance(tags, str):
                tags = tags.split()
            if "#archive/person" not in text and "archive/person" not in tags:
                continue
            emails = data.get("email") or []
            if isinstance(emails, str):
                emails = [emails]
            if not isinstance(emails, list):
                continue
            for email in emails:
                people_by_email.setdefault(str(email).strip().casefold(), []).append(path)
        lines, warnings, seen = [], [], set()
        for source in sources:
            if not source.calendar:
                continue
            for person in source.calendar.attendees:
                email = (person.email or "").strip().casefold()
                identity = email or (person.name or "").strip()
                if not identity or identity in seen:
                    continue
                seen.add(identity)
                if not email:
                    lines.append("- " + safe_text(person.name or ""))
                    continue
                matches = list(dict.fromkeys(people_by_email.get(email, [])))
                if len(matches) == 1:
                    # Relative vault path avoids ambiguous basename links.
                    target = str(matches[0].relative_to(self.root).with_suffix(""))
                    lines.append(f"- [[{target}]]")
                else:
                    clean = re.sub(r"[\[\]\n\r|]", "", email)
                    lines.append(f"- [[@{clean}]]")
                    if len(matches) > 1:
                        warnings.append(f"Duplicate person cards for {email}")
        return "\n".join(lines), warnings


BLOCK = re.compile(r"<!-- boldsound:(attendees|notes):begin sha256=([a-f0-9]{64}) version=([a-f0-9]{64}) -->\n(.*?)\n<!-- boldsound:\1:end -->", re.S)


def replace_block(text: str, kind: str, content: str, version: str, *, force: bool = False, expected: str | None = None) -> str:
    found = [m for m in BLOCK.finditer(text) if m[1] == kind]
    if len(found) > 1 or (f"<!-- boldsound:{kind}:" in text and not found):
        raise AgentError("note_conflict", "Managed block markers are damaged or duplicated")
    old = found[0] if found else None
    changed = (old and text_hash(old[4]) != old[2]) or (expected is not None and (not old or old[0] != expected))
    if changed and not force:
        diff = "".join(difflib.unified_diff((expected or "").splitlines(True), (old[0] if old else "").splitlines(True), fromfile="last-agent-block", tofile="current-note"))
        raise AgentError("note_conflict", "The managed block was edited; review the diff before forcing", details=diff)
    block = f"<!-- boldsound:{kind}:begin sha256={text_hash(content)} version={version} -->\n{content}\n<!-- boldsound:{kind}:end -->"
    if old:
        return text[:old.start()] + block + text[old.end():]
    heading = "Attendees" if kind == "attendees" else "Notes"
    match = re.search(rf"^# {heading}[^\S\n]*\n", text, re.M)
    if match:
        return text[:match.end()] + "\n" + block + "\n" + text[match.end():]
    return text.rstrip() + f"\n\n# {heading}\n\n{block}\n"


def result_markdown(result: MeetingResult, sources: list[Source], *, stale: bool = False) -> str:
    sections = ["⚠ Итог устарел: состав записей изменён.\n" if stale else "", "## Итог", safe_text(result.summary), "", "## Решения"]
    sections += ["- " + safe_text(x) for x in result.decisions] or ["- Не зафиксированы"]
    sections += ["", "## Задачи"]
    sections += ["- [ ] " + safe_text(x.task) + (f" — {safe_text(x.owner)}" if x.owner else "") + (f"; срок: {safe_text(x.due)}" if x.due else "") for x in result.tasks] or ["- Не зафиксированы"]
    sections += ["", "## Открытые вопросы"]
    sections += ["- " + safe_text(x) for x in result.open_questions] or ["- Не зафиксированы"]
    sections += ["", "## Транскрипты"]
    sections += [f"- [{safe_text(s.title).replace('[', '').replace(']', '')}](file://{quote(str(Path(s.artifact_path).absolute()))})" for s in sources]
    return "\n".join(sections).strip()


@contextlib.contextmanager
def file_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        os.chmod(path, 0o600)
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def atomic_write(path: Path, text: str, expected_hash: str | None, backup_dir: Path):
    current = path.read_text() if path.exists() else None
    if (text_hash(current) if current is not None else None) != expected_hash:
        raise AgentError("note_conflict", "Note changed during processing; retry using the current note")
    if current == text:
        return
    backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    if current is not None:
        backup = backup_dir / (text_hash(str(path)) + "-" + text_hash(current) + ".md")
        with backup.open("a+b") as handle:
            os.chmod(backup, 0o600)
            if handle.tell() == 0:
                handle.write(current.encode())
                handle.flush()
                os.fsync(handle.fileno())
    descriptor, name = tempfile.mkstemp(prefix=".boldsound-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            if path.exists():
                os.fchmod(handle.fileno(), path.stat().st_mode & 0o777)
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        latest = path.read_text() if path.exists() else None
        if (text_hash(latest) if latest is not None else None) != expected_hash:
            raise AgentError("note_conflict", "Note changed immediately before replacement")
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)
