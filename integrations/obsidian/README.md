# Boldsound meeting agent → Obsidian

Python 3.11+ / macOS. The app saves a completed meeting and an outbox intent in
one GRDB transaction. `meeting-agent enqueue` acknowledges a durable SQLite job;
a single launchd worker produces the Russian summary and updates managed blocks
in the vault. Dictation and file/media imports never enqueue automatically.
The existing external `meeting.completed` hook is independent.

## Setup

1. Install code into a private virtual environment:

   ```sh
   MEETING_AGENT_PYTHON=/opt/homebrew/bin/python3 integrations/obsidian/install.sh
   ```

2. In Settings → Meetings → **Агент встреч · Obsidian**, enter the absolute
   `integrations/obsidian/.venv/bin/meeting-agent` path and choose your vault.
   The default vault is `/Users/user/obsidian/gtd`; `Templates/Meeting.md` is
   read as text. Templater JavaScript is never executed.
3. Save a connection profile, specify an available model, and test it. The
   initial provider is local Ollama. No cloud profile, API payment or provider
   is selected automatically after a failure. Cloud execution is explicitly
   labeled. Profile edits/default changes require rechecking before enabling
   automation.
4. Install the worker with **Установить и запустить worker**. It runs as the
   current user under `com.boldsound.meeting-agent`, survives app closure, and
   recovers interrupted jobs on restart.
5. Enable **Обрабатывать завершённые встречи автоматически**. This permits
   subsequent meeting processing through the selected profile without a prompt
   for each meeting. Manual processing is available with automation off.

Use a local Ollama model already installed on your machine. The agent checks
`/api/show` before sending transcript text and refuses cloud-backed models in
local mode. HTTP redirects and proxy environment inheritance are disabled.
For additional defense, run Ollama with its own cloud features disabled. See
[Ollama local-only mode](https://docs.ollama.com/cloud#local-only).
A custom loopback compatible server is user-managed; configure that server for
local inference as well.

## Providers and authentication

| Provider ID | Endpoint base | Authentication |
| --- | --- | --- |
| `ollama` | `http://127.0.0.1:11434` | None for local inference |
| `openai` | `https://api.openai.com/v1` | API key; Responses API |
| `codex` | Not used | Official Codex CLI saved ChatGPT login |
| `anthropic` | `https://api.anthropic.com/v1` | Claude API key |
| `gemini` | `https://generativelanguage.googleapis.com/v1beta` | Gemini API key |
| `gemini_cli` | Not used | Official Gemini CLI saved Google login |
| `openrouter` | `https://openrouter.ai/api/v1` | API key; provider fallback disabled |
| `compatible` | Your base URL including `/v1` | Optional API key, explicitly local/cloud |

API keys entered in the app are stored with the macOS Keychain backend under
service `com.boldsound.meeting-agent`. Profiles contain only `key_ref`, never
the key itself. Manual CLI profiles may specify `key_env`; the app does not
inherit API-key environment variables. Never put keys or transcripts in argv.

For Codex, install the official CLI and run `codex login`, choosing ChatGPT.
The app's login button opens that official command in Terminal. Processing uses
`codex exec` with `forced_login_method="chatgpt"`, a read-only sandbox, ignored
user configuration/rules, disabled shell, plugins, hooks, apps and web search,
and ephemeral output. The CLI retains ownership of its credentials: the agent
never extracts OAuth tokens or calls an API using subscription credentials.
A CLI too old for the required isolation options fails visibly; update it.
[Codex authorization](https://learn.chatgpt.com/docs/auth),
[noninteractive execution](https://learn.chatgpt.com/docs/non-interactive-mode),
[forced login configuration](https://learn.chatgpt.com/docs/config-file/config-reference).

For Gemini CLI, install the official CLI, run `gemini`, and select Google login
with the appropriate account (including AI Pro/Ultra when applicable). The
worker forces `oauth-personal`, excludes API/Vertex environment variables,
disables extensions, hooks, tool discovery and MCP, and uses an empty working
directory. [Authentication](https://geminicli.com/docs/get-started/authentication/),
[configuration](https://geminicli.com/docs/reference/configuration/).

Both CLIs run without a shell in private temporary directories and inside an
additional macOS sandbox that denies vault reads and writes. Only the Python
writer changes the vault. Authentication and quota errors require user action;
there is no subscription-to-paid-API fallback. Anthropic subscription login is
not offered; use its API key.

Native JSON schema output is attempted for the selected model. A specific
unsupported-schema response in `auto` mode falls back to ordinary JSON on the
same connection. All results are Pydantic-validated with one JSON repair
attempt. `native` requires schema support; `json` explicitly opts out.
Long inputs are divided without dropping text and merged hierarchically;
context/output limits fail visibly instead of silently truncating.

## CLI

All commands return one JSON envelope: `ok`, `schema_version: 1`, and `data`
or `error`. Exit code is zero on success, one on a request/agent failure.
Root options precede the command: `--state-dir`, `--vault`, `--profile`.

```sh
meeting-agent doctor
meeting-agent --profile local doctor --test
meeting-agent profiles
meeting-agent profiles --stdin < profile.json
meeting-agent enqueue < request.json
meeting-agent jobs
meeting-agent jobs --source TRANSCRIPT_ID
meeting-agent retry JOB_ID
meeting-agent cancel JOB_ID
meeting-agent bind < binding.json
meeting-agent process latest
meeting-agent --profile local process TRANSCRIPT_ID --note 'Prepared meeting.md'
meeting-agent process TRANSCRIPT_ID --dry-run
meeting-agent process TRANSCRIPT_ID --force
meeting-agent worker --once
meeting-agent worker
meeting-agent launchd --install
```

`process` reads the public `macparakeet-cli meetings` JSON interface and queues
work; it does not read the app database directly. Use
`--macparakeet-cli /absolute/path` if the CLI is not on PATH. `--dry-run` uses a
copied temporary agent database with the existing multipart context and returns
proposed Markdown without changing the queue or vault. It still invokes the
chosen model. `--force` authorizes replacement of modified managed blocks only;
manual sections remain intact. Each manual `process` starts a new processing
revision; normal `enqueue` delivery is idempotent.

Example profile file (no secret):

```json
{
  "action": "save",
  "default": true,
  "profile": {
    "id": "local",
    "name": "Local Ollama",
    "provider": "ollama",
    "model": "YOUR_INSTALLED_MODEL",
    "endpoint": "http://127.0.0.1:11434",
    "execution": "local",
    "timeout": 120,
    "structured_output": "auto"
  }
}
```

An API profile can use `"key_env": "MY_PROVIDER_API_KEY"` for a manual CLI.
For app/launchd use Keychain through the settings UI. The app sends structured
stdin for processing, bindings and credentials. See the full
[app-agent contract](../../spec/contracts/meeting-agent-v1.md).

## Note selection and multiple recordings

The binding sheet is available before recording, during recording, and on a
saved meeting. Calendar search uses EventKit by day/title and includes past,
future, all-day and declined events independently of automatic-recording
filters. Notes and events can be chosen separately. Choosing a note for a future
event saves an occurrence-specific binding. The original start snapshot is
kept separately from later manual selections.

Matching order: explicit note → event-instance binding → transcript ID in YAML
→ unique exact normalized date/title filename → new root note named
`YYYY-MM-DD Title.md`. Multiple matches require selection. YAML `id` follows
renames; duplicate/missing IDs require a fresh choice. Pending checkboxes and
empty Notes do not prevent matching.

`macparakeet_ids` lists all related sources; legacy `macparakeet_id` is read.
New parts recompute the summary from all stored parts in chronological order.
Unchanged repeated deliveries do not create blocks or sources twice. Missing
legacy parts must be enqueued before the agent can safely recompute a note.
Moving a source updates source membership and marks the old managed summary
stale. The old file and manual text remain; process its remaining sources to
refresh it.

Attendees use calendar email addresses, normalized case-insensitively, to find
person cards tagged `#archive/person`. Unique matches use vault-relative wiki
links, missing/duplicate cards use `[[@email]]`, and duplicates produce a
warning. Names without email stay plain text. The agent writes only managed
blocks under `# Attendees` and `# Notes`, plus source-ID YAML metadata. Links,
Agenda, unrelated YAML fields and the meeting checkbox are preserved.

## Recovery

State is private to `~/Library/Application Support/Boldsound/MeetingAgent`:
`agent.sqlite` (WAL/FULL), `backups/`, and lock files. The app reads agent states
through JSON only. Its independent GRDB outbox retries unacknowledged delivery
on startup and while running. Delivery waits for existing canonical artifacts
without rewriting them. Keep both databases when recovering a machine.

Pending app intents retain the exact selected profile fingerprint. If the profile
has changed, review the connection and use **Обработать заново**; changing just
the note never changes the processing profile. Refreshing a changed default
profile disables automation until you test and enable it again.

- `queued` / **В очереди**: start the worker; check pending app delivery errors.
- `processing` / **Обрабатывается**: wait, or cancel. Killing/restarting the
  worker returns interrupted work to the queue. A lifetime lock rejects a
  second worker.
- `needs_action` / **Нужно действие**: choose a note, sign in, restore vault
  access, resolve quota, or inspect a managed-block conflict diff.
- `error` / **Ошибка**: transient network errors retry at most four attempts
  with bounded backoff. Fix the connection/model and retry.
- `done` / **Готово**: open the note from the app.
- `cancelled` / **Отменено**: transcripts and notes remain; manually reprocess
  with current bindings if desired.

Prepared writes are persisted before touching a note. After a crash between
atomic replacement and job acknowledgement, replay recognizes the exact result
and acknowledges it without duplicate blocks or another LLM call. Stale-summary
marks on moved sources use the same durable replay principle. A normal
conflict retry rebases on the current manual text. Modified agent blocks still
require an explicit force action. Backups are private Markdown snapshots;
restore manually after reviewing the current note. No recovery command deletes
user notes, transcripts or meeting audio.

External automation may use `hook.sh` as the configured hook executable. It
reads the existing `meeting.completed` v1 JSON from stdin and quickly enqueues;
it never waits for an LLM. This optional adapter does not modify the app's
external-hook preference. Do not also enable both delivery paths unless you
want redundant (idempotent) enqueue requests.

## Verification

```sh
integrations/obsidian/.venv/bin/python -m pytest integrations/obsidian/tests -q
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MeetingAgent
```

Tests use synthetic transcripts, temporary vaults, mock HTTP/CLI providers and
in-memory GRDB. Live cloud accounts, real meeting data and the user's vault are
not needed for testing. Account/model availability is checked when the user
presses **Проверить подключение**.
