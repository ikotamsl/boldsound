# Meeting recording: Clock injection for deterministic time-based tests

> Status: **DEFERRED**
> Filed: 2026-05-10
> Owner: unassigned
> Trigger conditions: see [§ When to revisit](#when-to-revisit) below

## Context

On 2026-05-10 the CI run for the merge of [PR #247](https://github.com/moona3k/macparakeet/pull/247) (UI polish for pause/resume) failed on a test that had nothing to do with the PR's diff:

```
testStopRecordingWhilePausedSettlesOngoingPauseIntoDuration:
  XCTAssertLessThan failed: ("0.21773") is not less than ("0.21260")
  - Stopping while paused must still subtract the in-flight pause interval
```

The test had shipped earlier in `a1b6c7e6` (PR #245's 9-agent-review cleanup commit). It measured real wallclock with a 200ms slack budget; pre-pause buffer-yield + actor mailbox drain spiked to ~218ms on a contended GitHub macOS runner, blowing past the slack by ~5ms. Local runs had passed by 100-200ms of margin.

The short-term fix in [PR #248](https://github.com/moona3k/macparakeet/pull/248) doubled both the pause sleep (500→1000ms) and the slack (0.3s→0.6s) in both `testStopRecordingDurationExcludesPausedTime` and `testStopRecordingWhilePausedSettlesOngoingPauseIntoDuration`. CI on main went green; same proof strength (60% of pause carved out of duration), now with ~400ms of headroom against runner jitter.

This plan captures the **structural fix** — inject a `Clock` so the tests don't have to depend on wallclock at all — and the reasons we deferred it.

## Problem statement

Three of the duration-related test assertions in `Tests/MacParakeetTests/Services/MeetingRecording/MeetingRecordingServiceTests.swift` use real wallclock:

- `testStopRecordingDurationExcludesPausedTime` (line ~1256)
- `testStopRecordingWhilePausedSettlesOngoingPauseIntoDuration` (line ~1308)
- `testActiveRecordingSecondsExcludesPausedAndOngoing` (similar shape — uses `Date()`)

These tests sleep for hundreds of milliseconds and assert that `output.durationSeconds` falls inside a tolerance window vs. measured wallclock. They're correct in intent — the math they verify (pause subtraction from saved duration) is the behavior users actually depend on. They're fragile in execution — the tolerance has to absorb runner jitter, actor scheduling, audio-buffer processing time, lock-file I/O, and `Task.sleep` wake-precision.

The same shape recurs in the recovery service (`MeetingRecordingRecoveryService.swift:192` uses `Date().timeIntervalSince(lock.startedAt)` for the duration fallback when source-derived duration isn't available).

## Verified inventory (2026-05-10)

Anchors for the refactor scope. Cross-check before re-prioritizing.

### `Date()` call sites in production code

| File | Line | What it captures |
|---|---|---|
| `MeetingRecordingService.swift` | 191 | "Now" used for `elapsedSeconds` (UI tick) |
| `MeetingRecordingService.swift` | 249 | Session `startedAt` + `displayName` fallback date |
| `MeetingRecordingService.swift` | 480 | "Now" at stop, used to settle in-flight pause + compute `durationSeconds` |
| `MeetingRecordingService.swift` | 563 | `pausedAt` captured when entering pause |
| `MeetingRecordingService.swift` | 593 | "Now" at resume, used to add to `accumulatedPausedDuration` |
| `MeetingRecordingRecoveryService.swift` | 192 | Wallclock fallback duration when no source-derived duration exists |
| `MeetingRecordingRecoveryService.swift` | 334 | `recovered.updatedAt` |

### Already-present clock prior art

`MeetingRecordingService.swift:93` already declares `private let clock = ContinuousClock()` and uses it at line 939 (`latestSystemSignalAt = clock.now`) and line 955 (`clock.now.duration(to: latestSystemSignalAt)`) for **audio signal freshness windowing**. It is **not injectable** — it's a private actor property. The pattern shows that the codebase is comfortable using `Clock` for non-persisted, internal-only timing concerns, but the duration-math path uses `Date()` because (a) `startedAt` is persisted into the lock file as `Date`, and (b) `Date()` matches the format the rest of the app uses for transcription timestamps.

### Test surface

| Metric | Count |
|---|---|
| Test construction sites of `MeetingRecordingService(...)` | **42** |
| `Task.sleep` calls in `MeetingRecordingServiceTests.swift` | 15 |
| `Date()` direct usages in `MeetingRecordingServiceTests.swift` | 4 |

Adding a clock parameter to the service `init` requires touching all 42 construction sites. Most would default to a real-clock helper; the 3 timing-fragile tests would adopt a `TestClock`.

### Persistence boundary (hard constraint)

`MeetingRecordingLockFile.startedAt: Date` (`MeetingRecordingLockFileStore.swift:23`) is persisted to disk for crash recovery. When the recovery service reads a lock file after a process restart, the only meaningful "now" is the real wallclock — there is no continuity of an in-memory `Clock` across process death.

This means **any `Clock` injection has to draw a boundary**: clocks govern in-memory pause/duration math; the lock file persists real `Date`. The conversion sites are:
- `startRecording` writes `session.startedAt` (currently `Date()`) into the lock file
- `stopRecording` computes `durationSeconds` against `session.startedAt`
- Recovery reads `lock.startedAt` and compares to `Date()` for the fallback duration

In a `Clock`-injected design, `session.startedAt` would have to be both a `Clock.Instant` (for in-memory math) AND a `Date` (for persistence). Either dual-store both representations, or convert at write-time and accept that test-clock instants written to lock files won't deserialize meaningfully — making recovery-path tests still real-wallclock dependent.

## Proposed approach

Inject a `Clock`-conforming dependency into `MeetingRecordingService` and `MeetingRecordingRecoveryService`.

### Sketch

```swift
public protocol MeetingClock: Sendable {
    func now() -> Date           // wallclock for persistence
    func elapsed(since: Date) -> TimeInterval
}

public struct SystemMeetingClock: MeetingClock {
    public init() {}
    public func now() -> Date { Date() }
    public func elapsed(since: Date) -> TimeInterval { now().timeIntervalSince(since) }
}

public actor MeetingRecordingService {
    private let clock: MeetingClock

    public init(
        /* ... existing params ... */
        clock: MeetingClock = SystemMeetingClock()
    ) { /* ... */ }

    // every Date() → clock.now()
    // every Date().timeIntervalSince(x) → clock.elapsed(since: x)
}
```

Tests use a `MockMeetingClock` that advances deterministically:

```swift
final class MockMeetingClock: MeetingClock {
    var current: Date
    init(start: Date = Date()) { self.current = start }
    func advance(by interval: TimeInterval) { current.addTimeInterval(interval) }
    func now() -> Date { current }
    func elapsed(since: Date) -> TimeInterval { current.timeIntervalSince(since) }
}
```

The three flaky tests become deterministic — no `Task.sleep`, just `clock.advance(by: 1.0)` between pause and resume.

### What this does NOT solve

- **Audio buffer timestamps** stay on `AVAudioTime.hostTime` / CMTime, emitted by CoreAudio / ScreenCaptureKit. These can't be injected. They flow into `MeetingAudioPairJoiner` and `MeetingRecordingMetadata.startOffsetMs` independently of the recording service's clock. Tests that exercise audio-pipeline timing (sync drift, lag detection) would still require either real audio buffers or a separate audio-time mock.
- **Lock-file persistence** still uses real `Date` for crash-recovery durability (see [§ Persistence boundary](#persistence-boundary-hard-constraint)).
- **Telemetry events** (`pause_recording`, etc.) emit durations to the self-hosted backend. They'd read the service's clock — fine in production, fine in tests, but cross-repo schema (Worker `ALLOWED_EVENTS`) is unaffected.

## Alternatives considered

| Alternative | Why we didn't pick it |
|---|---|
| Keep loosening test margins as flakes appear | What we just did. Works for the one flake, but every new pause-related test inherits the same fragility — death by a thousand margin bumps |
| Test-only `Date` factory closure (no protocol, just `init(dateFactory: () -> Date = Date.init)`) | Slightly lighter than a full `Clock` protocol but loses the structured `advance(by:)` ergonomics in tests. Still touches 42 construction sites |
| Swift's built-in `Clock` protocol (`ContinuousClock`/`SuspendingClock`) | Native, but its `Instant` types don't bridge cleanly to `Date` for the persistence boundary. The custom `MeetingClock` protocol above is thinner and explicit about the `Date`-handing-out contract |
| Refactor `MeetingRecordingService` to take **only** an `Instant`-based clock and convert at persistence boundaries | Cleaner type story, but doubles the conversion sites and risks introducing the very off-by-pause-duration bugs the refactor is supposed to prevent |
| Don't test the duration math at all — trust the implementation | The 9-agent-review explicitly added these tests as regression guards for the `captureOrchestrator.reset()` bug. Dropping them would re-open that hole |

## Risks

Grounded in the verified code locations.

| Risk | Concrete failure mode | Mitigation |
|---|---|---|
| **Missing one of the 5 Date() call sites** in the service, leaving mixed time bases | Test passes (because both sides of one assertion use TestClock) but production silently miscalculates durations because one call site still reads real `Date()` while in-memory state was advanced via TestClock | Code review + add an internal lint or `#if DEBUG` assertion that disallows raw `Date()` inside the service |
| **Lock-file recovery path** uses real `Date` but service flow uses injected clock | Recovery duration fallback off by the gap between TestClock's "now" and real `Date()` in tests that exercise recovery | Keep `MeetingRecordingLockFile.startedAt: Date` as wallclock; document the conversion boundary explicitly in the service header |
| **Telemetry event durations** start to drift if the clock isn't threaded into telemetry-emitting code paths | Telemetry queries get bimodal — production sees real durations, tests see synthetic — but the schema accepts both, so the bug surfaces only in dashboards | Audit `Telemetry.send(.pauseRecording(...))` etc. and ensure they're fed values derived from the service's clock |
| **Actor / Sendable** mistakes with the clock dependency | TestClock not actor-safe → data race in test causes spurious failures or hangs | Swift 6 strict-concurrency catches most of these; `MeetingClock: Sendable` constraint enforces |
| **AVAudioTime / CMTime boundary** | Audio-pipeline tests that mix service-clock time and host-time timestamps drift apart | Document that the audio time path is out of scope for the clock refactor; keep audio tests as-is |
| **42-touch-site refactor** introduces unrelated regressions | Tests get re-edited; a Sendable closure capture changes; a constructor reorder confuses a default value | Mechanical refactor with careful PR review. Run full XCTest + Swift Testing suite before merge |

## Cost estimate

Rough — assumes one engineer familiar with the meeting subsystem.

| Stage | Hours |
|---|---|
| Design + spec the `MeetingClock` protocol, doc the persistence boundary | 1-2 |
| Thread clock through `MeetingRecordingService` (5 call sites) | 1 |
| Thread clock through `MeetingRecordingRecoveryService` (2 call sites + recovery test fixtures) | 1-2 |
| Update 42 test construction sites (mostly mechanical, default arg covers most) | 2-3 |
| Convert 3 timing-fragile tests to use `MockMeetingClock` | 2 |
| Audit telemetry emit sites for clock consistency | 1 |
| Write `Tests/MacParakeetCore/Mocks/MockMeetingClock.swift` + helper extensions | 1 |
| Run full XCTest + Swift Testing, fix any fallout | 2-4 |
| PR review cycle (likely multi-reviewer given service-layer touch) | 2-4 (calendar) |

**Total**: ~2-3 focused days of engineering, plus calendar time for review.

## When to revisit

Revisit this plan if **any** of:

1. **A second pause-related timing test flakes on CI** within ~30 days. One flake fixed with margin bump is bad luck; two is a pattern.
2. **A new pause-time-sensitive feature** lands or is planned — e.g., auto-resume after wake, max-pause-duration enforcement, scheduled pause, "pause" as part of a broader recording state machine. Determinism becomes structurally valuable when there's more pause logic to verify.
3. **You want to test long pause durations** (hours, overnight) and the current sleep-based tests would be prohibitively slow.
4. **The audio-pipeline tests** start needing clock injection too — at that point the cost amortizes across two subsystems and the ROI improves.
5. **A bug** is suspected in the pause-duration math that the current tests don't catch because their wallclock-based assertions are too forgiving.

Until then, the [PR #248](https://github.com/moona3k/macparakeet/pull/248) margin bump is good enough.

## References

- ADR-014 (meeting recording architecture) — `spec/adr/014-meeting-recording.md`
- ADR-019 (crash-resilient meeting recording — lock file design) — `spec/adr/019-crash-resilient-meeting-recording.md`
- PR #245 (original pause/resume feature) — https://github.com/moona3k/macparakeet/pull/245
- PR #247 (pause UI polish — incidental trigger for the flake) — https://github.com/moona3k/macparakeet/pull/247
- PR #248 (margin-bump short-term fix) — https://github.com/moona3k/macparakeet/pull/248
- Failing test commit (`a1b6c7e6`) — `git show a1b6c7e6`
