from __future__ import annotations

import hashlib
import ipaddress
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, model_validator, field_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class AgentError(Exception):
    def __init__(self, code: str, message: str, *, retryable: bool = False, details: Any = None):
        super().__init__(message)
        self.code, self.retryable, self.details = code, retryable, details


class Profile(StrictModel):
    id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,80}$")
    name: str = Field(min_length=1, max_length=120)
    provider: Literal["ollama", "openai", "codex", "anthropic", "gemini", "gemini_cli", "openrouter", "compatible"] = "ollama"
    model: str = Field(min_length=1, max_length=160)
    endpoint: str = "http://127.0.0.1:11434"
    timeout: float = Field(default=120, ge=1, le=1800)
    execution: Literal["local", "cloud"] = "local"
    key_ref: str | None = None
    key_env: str | None = None
    # auto probes the selected model, native requires schema support, json opts out.
    structured_output: Literal["auto", "native", "json"] = "auto"
    chunk_chars: int = Field(default=12000, ge=2000, le=100000)
    cli_path: str | None = None

    @model_validator(mode="after")
    def validate_connection(self):
        if self.provider in {"codex", "gemini_cli"}:
            if self.execution != "cloud" or self.key_ref or self.key_env:
                raise ValueError("CLI subscription profiles require cloud execution and saved CLI login only")
        else:
            url = urlsplit(self.endpoint)
            if url.scheme not in {"http", "https"} or not url.hostname or url.username or url.password or url.query or url.fragment:
                raise ValueError("Endpoint must be an HTTP(S) base URL without credentials, query or fragment")
            try:
                loopback = ipaddress.ip_address(url.hostname).is_loopback
            except ValueError:
                loopback = url.hostname == "localhost"
            if self.execution == "local" and not loopback:
                raise ValueError("Local execution requires a loopback endpoint")
            if not loopback and url.scheme != "https":
                raise ValueError("Cloud endpoints require HTTPS")
            if self.provider not in {"ollama", "compatible"} and self.execution != "cloud":
                raise ValueError("This API provider requires an explicitly cloud profile")
        if self.cli_path and not Path(self.cli_path).is_absolute():
            raise ValueError("CLI path must be absolute")
        return self


class Person(StrictModel):
    name: str | None = None
    email: str | None = None


class CalendarSnapshot(BaseModel):
    model_config = ConfigDict(extra="ignore")
    eventIdentifier: str
    scheduledStartAt: datetime
    scheduledEndAt: datetime
    title: str
    attendees: list[Person] = Field(default_factory=list)
    organizer: Person | None = None

    @property
    def occurrence_key(self) -> str:
        return digest([self.eventIdentifier, self.scheduledStartAt.astimezone(timezone.utc).isoformat()])


class NoteRef(StrictModel):
    vault: str
    path: str
    id: str | None = None

    @model_validator(mode="after")
    def validate_path(self):
        if not Path(self.vault).is_absolute() or Path(self.path).is_absolute() or ".." in Path(self.path).parts or Path(self.path).suffix.lower() != ".md":
            raise ValueError("Note requires an absolute vault and a relative Markdown path")
        return self


class Source(StrictModel):
    id: str = Field(min_length=1, max_length=128)
    title: str
    created_at: datetime
    updated_at: datetime | None = None
    text: str = Field(min_length=1)
    artifact_path: str
    calendar: CalendarSnapshot | None = None
    original_calendar: CalendarSnapshot | None = None
    note: NoteRef | None = None
    event_note: NoteRef | None = None
    binding_version: int = Field(default=0, ge=0)
    source_type: Literal["meeting"] = "meeting"

    @field_validator("id")
    @classmethod
    def normalize_id(cls, value):
        return value.casefold()

    @field_validator("created_at", "updated_at")
    @classmethod
    def timezone_required(cls, value):
        if value is not None and value.tzinfo is None:
            raise ValueError("Timestamps require a timezone")
        return value


class EnqueueRequest(StrictModel):
    schema_version: Literal[1] = 1
    source: Source
    profile_id: str | None = None
    expected_profile_fingerprint: str | None = None
    vault: str = "/Users/user/obsidian/gtd"
    force: bool = False
    processing_version: int = Field(default=1, ge=1)


class ActionItem(StrictModel):
    task: str
    owner: str | None
    due: str | None


class MeetingResult(StrictModel):
    summary: str
    decisions: list[str]
    tasks: list[ActionItem]
    open_questions: list[str]


class ProviderResult(StrictModel):
    result: MeetingResult
    model: str
    usage: dict[str, Any] = Field(default_factory=dict)


def canonical(value: Any) -> str:
    if isinstance(value, BaseModel):
        value = value.model_dump(mode="json")
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value: Any) -> str:
    return hashlib.sha256(canonical(value).encode()).hexdigest()
