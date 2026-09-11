# Meeting agent implementation

Status: implemented; review handoff pending. Branch: `feat/obsidian-meeting-agent`.
`origin/master` is the live remote default; `origin/main` does not exist.

## Scope and invariants

Standalone Python queue/worker and eight provider modes, safe Obsidian matching
and managed blocks, app outbox and binding repositories, independent settings
and meeting controls, EventKit manual search, contracts and synthetic tests.

Preserve dictation/import behavior, external hooks, original calendar snapshots,
manual note contents and checkboxes, existing AI configuration and user data.
Default disabled, Russian output, loopback Ollama, one worker. Never switch
provider or billing mode automatically. Tests use temporary vaults, mocked
providers and in-memory GRDB; no real transcripts or cloud calls.

## Work sequence

- [x] Python schemas, profiles/Keychain, provider adapters and isolation
- [x] Durable queue, sequential worker, replay/cancel/bind/version guards
- [x] Vault matching, attendees, multipart recomputation and safe writes
- [x] Swift repositories, transactional outbox, process bridge and lifecycle wiring
- [x] Settings, manual calendar/note selection and job UI
- [x] Focused tests, contracts, documentation and independent review
- [x] One final full Swift suite; existing failures documented below
- [ ] PR/CI handoff (no automatic merge while checks are failing)

## Verification — 2026-09-10

- Python: 35 tests passed (Pydantic/HTTP/CLI adapters, no billing fallback,
  queue/cancel/retry, renames, multipart, event races, stale binding replay,
  changed-profile consent, manual preservation, file-write crash recovery).
- New Swift `MeetingAgentTests`: 13 passed. Recording flow: 22 passed.
  Existing hook/repository tests also pass in the final full suite.
- `swift-format lint --strict`: all 10 new Swift files pass.
- Full Swift suite run once using Xcode's developer directory: 4910 XCTest
  tests, 20 skipped, 5 failures; another 17 Swift Testing tests pass.
  Four failures are baseline `AppPathsTests` assertions expecting MacParakeet
  paths although unchanged HEAD uses BoldSound/boldsound.db. Confirmed directly
  against HEAD source and tests. One audio recovery timeout
  (`MicrophoneEnginePlatformConfigChangeRecoveryTests.testFailedRecoveryLeavesEngineStopped`)
  passes a focused rerun. No second full suite run.
- Installed CLI smoke: temporary vault + synthetic loopback Ollama server,
  profile → enqueue → worker → note → repeated delivery with identical file.
- Independent Swift and Python reviews converged with no remaining blockers
  after fixes and regression tests. No-mistakes and Greptile CLI are unavailable.
- `git diff --check` passes.

Logs are local `/tmp/boldsound-meeting-agent-*.log`; no logs, credentials, user
transcripts or generated venv files are committed. Real provider logins, live
cloud model calls, launchd installation, and GUI/account smoke tests remain
operator setup checks. The user's vault was not modified and automation remains
disabled by default. See `integrations/obsidian/README.md` for setup and recovery.
