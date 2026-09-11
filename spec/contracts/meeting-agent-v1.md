# Meeting agent JSON v1

Status: ACTIVE. Implementation: `integrations/obsidian/` and
`Sources/MacParakeetCore/Services/MeetingAgent/`.

## Purpose and ownership

Boldsound persists completed meeting transcripts and integration intents
atomically in GRDB. The Python agent owns its durable job queue and Obsidian
writes. The app communicates through subprocess JSON and never reads Python
SQLite. Python uses saved EventKit snapshots, never calendar authorization or
direct app-database access. The external `meeting.completed` hook is unchanged.

Producers: `TranscriptionRepository.save`, `MeetingAgentService`, the agent CLI
and optional external hook adapter. Consumers: app settings/meeting controls,
launchd worker, manual CLI automation.

## Transport

No shell; one request object on stdin, one response object on stdout. Never put
transcripts or keys in argv. Root options: `--state-dir`, `--vault`, `--profile`.
Commands requiring optional stdin use `--stdin` (`profiles`, `doctor`, `jobs`,
`notes`, `retry`, `cancel`). `enqueue`, `bind`, `invalidate`, `hook` require stdin.
Responses are `{ "ok": true, "schema_version": 1, "data": ... }` or
`{ "ok": false, "schema_version": 1, "error": { "code", "message", "details" } }`.
Exit 0 means protocol success, exit 1 means failure. `enqueue` success means
SQLite committed, not that the LLM or note write completed.

## Enqueue

Stable request fields:

```json
{
  "schema_version": 1,
  "source": {
    "id": "transcript-uuid",
    "title": "Meeting title",
    "created_at": "2026-09-10T09:00:00Z",
    "updated_at": "2026-09-10T10:00:00Z",
    "text": "Transcript text",
    "artifact_path": "/absolute/meeting/transcript.json",
    "source_type": "meeting",
    "binding_version": 0,
    "calendar": null,
    "original_calendar": null,
    "note": null,
    "event_note": null
  },
  "profile_id": "local",
  "expected_profile_fingerprint": "SHA-256-returned-by-profiles",
  "vault": "/absolute/vault",
  "force": false,
  "processing_version": 1
}
```

Calendar snapshots reuse camelCase EventKit artifact fields:
`eventIdentifier`, `title`, `scheduledStartAt`, `scheduledEndAt`, `attendees`
(`name`, `email`), optional `organizer`. Additional snapshot fields are accepted.
Occurrence identity includes identifier and scheduled start, not series alone.
`original_calendar` remains the start snapshot; `calendar` is effective context.
Note references are `{ "vault": "/absolute/vault", "path": "relative.md", "id":
"optional-yaml-id" }`. Absolute/traversing note paths and symlink notes are
rejected. `source_type` only accepts `meeting`. `event_note` is an optional inherited app
hint: it seeds a missing occurrence binding only and never overrides an existing
binding or counts as an explicit source selection. Its target/revision are read
atomically and checked again before note assignment and commit.

`profiles` returns a `fingerprints` map keyed by profile ID. App intents always
include `expected_profile_fingerprint`; enqueue rejects a changed profile before
saving or sending content. Binding-only edits retain the original profile and
fingerprint; explicit reprocessing can select a new profile. Manual CLI requests
may omit this field to select the current saved profile at enqueue time.

The job ID hashes the canonical source/request and saved profile snapshot.
Repeated delivery returns the same job. Older binding/transcript revisions are
rejected. On processing, source membership, source content/bindings, event
binding revisions, processing version and profile determine result provenance.
These are rechecked under the commit transaction before writing. No provider
or payment fallback is permitted. Source IDs are case-normalized.

## Commands and results

- `jobs [--source ID]`: `{jobs:[...]}` newest first, up to 200. Job stable fields:
  `id`, `source_id`, `state`, `attempts`, `created_at`, `updated_at`, `error`,
  `details`, `note`, `result`. Result contains provider/model/usage/warnings/version.
- States: `queued`, `processing`, `done`, `needs_action`, `error`, `cancelled`.
- `retry ID` / `cancel ID`, or stdin `{id}`: updated job. Retry checks current
  source and profile; an outdated job requires a new processing request.
- `bind`: `{source_id,note,calendar,binding_version?}`; updates effective
  selection and enqueues. `{event_only:true,note,calendar}` saves an event link.
  Explicit per-recording notes outrank event links.
- `invalidate`: `{source_id}` cancels queued/processing jobs before the app
  commits a manual binding change. Failed invalidation keeps the old app
  selection, with an error shown to the user.
- `profiles`: stdin `{action:"list"}` or `{action:"save",profile,default,api_key?}`.
  Returned `profiles` never contain keys; `fingerprints` identifies exact saved configurations. Profile fields: `id`, `name`,
  `provider`, `model`, `endpoint`, `timeout`, `execution` (`local|cloud`),
  `key_ref?`, `key_env?`, `structured_output` (`auto|native|json`), `chunk_chars`,
  `cli_path?`. Provider IDs are documented in the integration README.
- `notes`: `{vault,path}` returns `{note}`; `{vault,query?}` returns `{notes}`.
- `doctor`: local installation/vault/profile/stale-note information. `{test:true,
  profile_id,vault}` explicitly tests the selected model with synthetic input.
- `login`: returns `{executable,arguments}` for the official interactive CLI;
  the app opens it in Terminal. No credentials are returned.
- `worker [--once]`: sequential processor with exclusive lifetime lock.
- `launchd [--install]`: returns a plist descriptor or installs the user worker.
- `process latest|ID [--note RELATIVE.md] [--dry-run] [--force]`: manual enqueue
  through the public MacParakeet CLI. Dry run returns proposed Markdown using
  temporary agent state and does not write the vault.
- `hook`: accepts the existing `meeting.completed` v1 envelope; validates the
  completed meeting artifact ID and queues the same source protocol.

## App persistence and lifecycle

Migration `v0.29-meeting-agent` adds independent recording bindings, event
bindings and outbox tables; see `spec/01-data-model.md`. Recording session UUIDs
and transcription UUIDs differ: the first row save transfers the binding by
session folder UUID atomically. A failed app→agent delivery remains pending;
startup and periodic dispatch retry it. Dispatch waits for the canonical artifact
and never materializes or rewrites sidecars; stale transcript payloads require
explicit reprocessing. External hooks keep their own settings,
20-second default timeout, execution and result files.

The default is disabled, local Ollama, Russian summaries and one worker.
Enabling automatic processing authorizes future completed meetings with the
configured default profile. Manual processing works while automation is off.
Switching the default or editing its connection requires rechecking and
reenabling automation. Calendar choices never change other AI settings.

## Obsidian write boundary

Matching order: explicit note; saved occurrence link; transcript YAML ID;
unique exact normalized date/title filename; new root note. Ambiguity is
`needs_action`. YAML IDs resolve renames. `macparakeet_ids` is the multipart
membership list; singular `macparakeet_id` remains readable.

Managed `attendees` and `notes` blocks use `boldsound:<kind>:begin` / `end` HTML
comments with SHA-256 content and result version. Manual edits/removal produce
conflicts; force applies only to managed blocks. Existing YAML values,
checkboxes, Agenda, Links and manual text remain. Only source membership keys
are maintained in existing YAML. Notes contain local transcript links, not
full transcript copies. New notes fill template fields without executing JS.

Prepared output is committed to the agent database before file replacement.
Note lock, version comparison, private backup, fsync and atomic replacement
protect writes. Exact-result replay handles a crash before job acknowledgement.
Moves mark old summaries stale and update membership without deleting notes.
Stale-summary edits also use a durable prepared journal with identical-result
recovery. Source and event binding changes roll back together if validation fails.
Network retries use a maximum of four attempts and bounded delay. Auth/quota,
conflicts and ambiguity require action; cancellation retains user artifacts.

## Compatibility and verification

Additive response/snapshot fields are allowed. Removing/renaming stable fields
or changing state semantics requires a new schema version and compatibility
handling. Timestamps, absolute paths, result prose, usage shapes and cosmetic
JSON formatting are not frozen.

Tests: `MeetingAgentTests`, existing `MeetingAutomationHookRunnerTests`,
`MeetingRecordingFlowCoordinatorTests`, `TranscriptionRepositoryTests`, and
`integrations/obsidian/tests/test_agent.py`. Changes to this boundary update the
contract, integration README, migrations where needed, and focused tests.
