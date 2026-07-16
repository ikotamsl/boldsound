# Dictation Flow State Machine Extraction

> Status: **COMPLETED** - 2026-03-26
> Reviewed by: Gemini, Codex — findings incorporated below

## Overview

Extract the implicit state machine in `DictationFlowCoordinator` into an explicit, testable `DictationFlowStateMachine` type. The coordinator currently tracks dictation UI flow state across 11 mutable variables with 20+ scattered generation guards. This refactor formalizes those states and transitions into a pure, deterministic state machine that can be exhaustively unit-tested.

**Goal:** Replace ad-hoc generation guards with a formal state machine. Zero behavior changes — same UX, same timing, same edge cases.

## Why

1. **Prevent race condition bugs** — Every new async path requires remembering to add generation guards in all the right places. The state machine makes invalid transitions structurally impossible.
2. **Enable unit testing** — The coordinator has zero tests today because logic is entangled with AppKit. The extracted state machine is a pure function that can be tested exhaustively.
3. **Improve debuggability** — Instead of tracing 743 lines to reconstruct state, log transitions: `idle → ready → recording → processing → done`.
4. **Reduce cognitive load** — One enum with documented transitions replaces 11 interacting variables.

## Design Decisions

### State Machine Lives in MacParakeetCore

The state machine is pure logic with no UI dependencies — it belongs in `MacParakeetCore` so it can be tested by the existing test target (`MacParakeetTests` imports `@testable MacParakeetCore`). It also models the dictation flow at a domain level, not a UI level.

### Pure Value Type (struct + enum)

The state machine is a `struct` holding the current `State` enum. Transitions are methods that take an `Event` and return a list of side effects. No async, no Tasks, no AppKit — those stay in the coordinator.

### Coordinator Becomes a Thin Shell

The coordinator keeps all AppKit/async responsibilities:
- Creating/destroying overlay controllers and view models
- Running Tasks for recording, processing, cancel countdown
- Calling DictationService, ClipboardService, EntitlementsService
- Executing side effects returned by the state machine

But all *decisions* about what to do next come from the state machine.

### Generation Is Top-Level on the Machine (not per-state)

Generation is a single `Int` on the `DictationFlowStateMachine` struct, bumped internally when entering a new flow. Async events carry a generation parameter; the machine rejects events whose generation doesn't match. No generation is embedded in state enum cases — one source of truth. (Codex review finding)

### Side Effects Are Data

The state machine returns side effects as an enum array, not by calling methods. This makes transitions testable — assert that a transition returns specific effects.

### `bumpGeneration` Is Internal

Generation increments happen inside `handle(_:)`, not as an externally-executed effect. The coordinator never manually bumps generation. (Codex review finding)

## State Enum

```swift
public enum DictationFlowState: Equatable, Sendable {
    /// No dictation activity. Idle pill may be showing.
    case idle
    /// Ready pill visible, waiting for second tap. Auto-dismisses after timeout.
    case ready
    /// Entitlements check in flight. No overlay visible yet.
    case checkingEntitlements(mode: RecordingMode)
    /// DictationService.startRecording() in flight. Overlay is visible, showing recording UI.
    case startingService(mode: RecordingMode)
    /// Actively recording. Audio level loop running.
    case recording(mode: RecordingMode)
    /// Stop requested while startRecording still in flight. Will auto-stop once recording begins.
    case pendingStop(mode: RecordingMode)
    /// Stop called, transcription in progress.
    case processing
    /// Cancel countdown running (5 seconds). User can undo or confirm.
    case cancelCountdown
    /// Terminal display state (success/noSpeech/error) before returning to idle.
    case finishing(outcome: FinishOutcome)
}

public enum FinishOutcome: Equatable, Sendable {
    case success
    case pasteFailedCopied(String) // transcription succeeded but paste failed
    case noSpeech
    case error(String)
}

/// Re-exported from FnKeyStateMachine to avoid coupling
public enum RecordingMode: Equatable, Sendable {
    case persistent
    case holdToTalk
}
```

Split `starting` into `checkingEntitlements` and `startingService` because cancel/stop behave differently in each: checkingEntitlements has no overlay, startingService has the overlay visible. (Codex review finding)

## Event Enum

```swift
public enum DictationFlowEvent: Equatable, Sendable {
    // Triggers
    case readyPillRequested
    case readyPillTimedOut(generation: Int)
    case startRequested(mode: RecordingMode)
    case entitlementsGranted(generation: Int)
    case entitlementsDenied(generation: Int)
    case recordingStarted(generation: Int)
    case stopRequested
    case cancelRequested(reason: CancelReason)
    case undoRequested
    case dismissRequested

    // Async completions (all carry generation for stale rejection)
    case transcriptionCompleted(generation: Int)
    case transcriptionFailedNoSpeech(generation: Int)
    case transcriptionFailed(generation: Int, message: String)
    case startFailed(generation: Int, message: String)
    case pasteSucceeded(generation: Int)
    case pasteFailed(generation: Int, message: String)

    // Timers (carry generation for stale rejection)
    case cancelCountdownExpired(generation: Int)
    case cancelConfirmedImmediate
    case displayDismissExpired(generation: Int)
}

public enum CancelReason: Equatable, Sendable {
    case escape
    case ui
}
```

All async completion and timer events carry `generation: Int` so the state machine can reject stale callbacks. (Both reviewers flagged this)

## Side Effect Enum

```swift
public enum DictationFlowEffect: Equatable, Sendable {
    // Overlay lifecycle
    case showReadyPill
    case rescheduleReadyDismissTimer   // ready→ready self-transition
    case showRecordingOverlay(mode: RecordingMode)
    case showProcessingState
    case showCancelCountdown
    case showSuccess
    case showNoSpeech
    case showError(String)
    case hideOverlay
    case dismissReadyPill

    // Idle pill
    case showIdlePill
    case hideIdlePill

    // Audio/service
    case checkEntitlements
    case startRecording(mode: RecordingMode)
    case stopRecordingAndTranscribe
    case cancelRecording(reason: CancelReason)
    case confirmCancel
    case undoCancelAndTranscribe

    // Paste
    case resignKeyWindow
    case pasteTranscript
    case reloadHistory

    // App integration
    case updateMenuBar(MenuBarState)
    case resetHotkeyStateMachine
    case notifyHotkeyCancelledByUI  // distinct from reset (Gemini + Codex)
    case presentEntitlementsAlert

    // Timer management
    case startReadyDismissTimer
    case cancelReadyDismissTimer
    case startCancelCountdown
    case cancelCancelCountdown
    case startDisplayDismissTimer(seconds: Double) // parameterized (2/3/5s)
    case cancelAllTimers

    // Task management
    case cancelRecordingTask
    case cancelActionTask
}

public enum MenuBarState: Equatable, Sendable {
    case idle
    case recording
    case processing
}
```

Key changes from v1:
- `notifyHotkeyCancelledByUI` is separate from `resetHotkeyStateMachine` (both reviewers)
- `resignKeyWindow` added (Gemini)
- `startDisplayDismissTimer(seconds:)` parameterized with duration for the 2/3/5s variance (Codex)
- `cancelRecordingTask` / `cancelActionTask` added (Codex)
- `showRecordingOverlay` carries `mode` (both reviewers)
- `rescheduleReadyDismissTimer` for self-transition (Codex)
- `cancelRecording` carries reason (Gemini)
- No `bumpGeneration` effect — generation is internal

## Transition Table

| From | Event | To | Effects |
|------|-------|----|---------|
| **Idle / Ready pill** | | | |
| idle | readyPillRequested | ready | hideIdlePill, showReadyPill, startReadyDismissTimer |
| ready | readyPillRequested | ready | rescheduleReadyDismissTimer *(self-transition, Codex)* |
| ready | readyPillTimedOut(gen) | idle | dismissReadyPill, showIdlePill |
| ready | startRequested(mode) | checkingEntitlements(mode) | cancelReadyDismissTimer, checkEntitlements |
| ready | cancelRequested | idle | dismissReadyPill, resetHotkeyStateMachine, showIdlePill |
| ready | dismissRequested | idle | cancelReadyDismissTimer, dismissReadyPill, resetHotkeyStateMachine, showIdlePill |
| **Starting** | | | |
| idle | startRequested(mode) | checkingEntitlements(mode) | hideIdlePill, checkEntitlements |
| checkingEntitlements | entitlementsGranted(gen) | startingService(mode) | showRecordingOverlay(mode), startRecording(mode), updateMenuBar(.recording) |
| checkingEntitlements | entitlementsDenied(gen) | idle | resetHotkeyStateMachine, presentEntitlementsAlert, showIdlePill |
| checkingEntitlements | cancelRequested | idle | cancelRecordingTask, resetHotkeyStateMachine, showIdlePill |
| checkingEntitlements | stopRequested | idle | cancelRecordingTask, resetHotkeyStateMachine, showIdlePill |
| checkingEntitlements | dismissRequested | idle | cancelAllTimers, cancelRecordingTask, resetHotkeyStateMachine, showIdlePill |
| startingService | recordingStarted(gen) | recording(mode) | *(audio level loop starts externally)* |
| startingService | startFailed(gen, msg) | finishing(.error(msg)) | showError(msg), startDisplayDismissTimer(5) |
| startingService | stopRequested | pendingStop(mode) | *(deferred)* |
| startingService | cancelRequested | idle | cancelRecordingTask, cancelRecording(reason), hideOverlay, resetHotkeyStateMachine, updateMenuBar(.idle), showIdlePill |
| **Recording** | | | |
| recording | stopRequested | processing | cancelRecordingTask, stopRecordingAndTranscribe, showProcessingState, updateMenuBar(.processing) |
| recording | cancelRequested(reason) | cancelCountdown | cancelRecordingTask, cancelRecording(reason), showCancelCountdown, updateMenuBar(.idle), startCancelCountdown, notifyHotkeyCancelledByUI |
| recording | startRequested(mode) | checkingEntitlements(mode) | cancelAllTimers, cancelRecordingTask, hideOverlay, hideIdlePill, checkEntitlements *(rapid restart, Gemini + Codex)* |
| recording | dismissRequested | idle | cancelAllTimers, cancelRecordingTask, hideOverlay, resetHotkeyStateMachine, updateMenuBar(.idle), showIdlePill |
| **Pending Stop** | | | |
| pendingStop | recordingStarted(gen) | processing | stopRecordingAndTranscribe, showProcessingState, updateMenuBar(.processing) |
| pendingStop | startFailed(gen, msg) | finishing(.error(msg)) | showError(msg), startDisplayDismissTimer(5) |
| pendingStop | cancelRequested | idle | cancelRecordingTask, cancelRecording(reason), hideOverlay, resetHotkeyStateMachine, updateMenuBar(.idle), showIdlePill |
| **Processing** | | | |
| processing | transcriptionCompleted(gen) | finishing(.success) | showSuccess, resignKeyWindow, pasteTranscript |
| processing | transcriptionFailedNoSpeech(gen) | finishing(.noSpeech) | showNoSpeech, startDisplayDismissTimer(3) |
| processing | transcriptionFailed(gen, msg) | finishing(.error(msg)) | showError(msg), startDisplayDismissTimer(5) |
| processing | cancelRequested/dismissRequested | idle | cancelAllTimers, cancelActionTask, hideOverlay, resetHotkeyStateMachine, updateMenuBar(.idle), showIdlePill |
| **Cancel Countdown** | | | |
| cancelCountdown | undoRequested | processing | cancelCancelCountdown, cancelActionTask, undoCancelAndTranscribe, showProcessingState, updateMenuBar(.processing) |
| cancelCountdown | cancelConfirmedImmediate | idle | cancelCancelCountdown, cancelActionTask, confirmCancel, hideOverlay, resetHotkeyStateMachine, updateMenuBar(.idle), showIdlePill |
| cancelCountdown | cancelCountdownExpired(gen) | idle | confirmCancel, hideOverlay, resetHotkeyStateMachine, updateMenuBar(.idle), showIdlePill |
| cancelCountdown | startRequested(mode) | checkingEntitlements(mode) | cancelCancelCountdown, cancelActionTask, confirmCancel, hideOverlay, hideIdlePill, checkEntitlements *(rapid restart, both reviewers)* |
| cancelCountdown | dismissRequested | idle | cancelAllTimers, cancelActionTask, confirmCancel, hideOverlay, resetHotkeyStateMachine, updateMenuBar(.idle), showIdlePill |
| **Finishing** | | | |
| finishing(.success) | pasteSucceeded(gen) | finishing(.success) | startDisplayDismissTimer(0.8) *(self-transition with timer, Gemini)* |
| finishing(.success) | pasteFailed(gen, msg) | finishing(.pasteFailedCopied(msg)) | showError(msg), startDisplayDismissTimer(5) *(Gemini + Codex)* |
| finishing | displayDismissExpired(gen) | idle | hideOverlay, reloadHistory, resetHotkeyStateMachine, updateMenuBar(.idle), showIdlePill |
| finishing | dismissRequested | idle | cancelAllTimers, hideOverlay, reloadHistory, resetHotkeyStateMachine, updateMenuBar(.idle), showIdlePill |

**Stale generation handling:** All events with `generation: Int` are rejected (return `[]`, no state change) if the generation doesn't match `self.generation`.

**`isDictationActive` derivation:** The coordinator's `isDictationActive` property should continue checking `overlayController != nil`, NOT the state machine state. This avoids behavior changes during `checkingEntitlements` where no overlay exists yet. (Codex regression risk finding)

## Implementation Steps

### Step 1: Create DictationFlowStateMachine in MacParakeetCore

**File:** `Sources/MacParakeetCore/DictationFlow/DictationFlowStateMachine.swift`

Create the state machine with all types defined above and the `handle(_:)` transition function. Pure, synchronous, no imports beyond Foundation.

### Step 2: Write Exhaustive Tests

**File:** `Tests/MacParakeetTests/DictationFlow/DictationFlowStateMachineTests.swift`

Test every transition in the table above, plus:
- Invalid transitions return empty effects and don't change state
- Stale generation events are rejected
- Happy path: idle → ready → checkingEntitlements → startingService → recording → processing → finishing → idle
- Cancel flow: recording → cancelCountdown → expired → idle
- Undo flow: recording → cancelCountdown → undo → processing → finishing → idle
- Cancel-confirm flow: recording → cancelCountdown → cancelConfirmedImmediate → idle
- Pending stop: checkingEntitlements → startingService → pendingStop → recordingStarted → processing
- Rapid restart: recording → startRequested → checkingEntitlements (new gen)
- Rapid restart from cancelCountdown → startRequested → checkingEntitlements
- Cancel from ready → idle (no countdown)
- Cancel from checkingEntitlements → idle
- Ready pill self-transition (readyPillRequested while ready)
- Paste failure: processing → finishing(.success) → pasteFailed → finishing(.pasteFailedCopied)
- Display dismiss timer durations: 0.8s (success), 3s (noSpeech), 5s (errors)

### Step 3: Refactor DictationFlowCoordinator to Use the State Machine

**File:** `Sources/MacParakeet/App/DictationFlowCoordinator.swift`

Replace the 11 state variables with:
```swift
private var stateMachine = DictationFlowStateMachine()
```

Each public method becomes:
1. Call `stateMachine.handle(event)`
2. Execute returned effects via `executeEffects(_:)`

The `executeEffects` method loops through effects and dispatches each one. Synchronous effects execute immediately. Async effects (startRecording, stopRecordingAndTranscribe, etc.) launch Tasks that send completion events back via `sendEvent(_:)` which calls `handle` + `executeEffects` again.

**Remove:** overlayGeneration, overlayActionGeneration, overlayActionTask, isStartRecordingInFlight, pendingStopGeneration, cancelTask, readyDismissTimer, bumpOverlayGeneration()

**Keep:** overlayController, overlayViewModel, recordingTask, idlePillController, all dependencies and callbacks. `isDictationActive` stays as `overlayController != nil`.

**Keep DictationStopDecider** until state machine tests pass — then remove in a follow-up. (Codex suggestion)

### Step 4: Verify

1. `swift test` — all existing tests pass
2. New state machine tests pass
3. Manual smoke test all dictation flows

## Resolved Open Questions

1. **DictationStopDecider** — Keep during refactor, remove in follow-up commit once state machine tests cover its paths.
2. **RecordingMode** — Stored in state (`checkingEntitlements(mode:)`, `recording(mode:)`, etc.). Re-exported as a simple enum in the state machine file to avoid coupling to FnKeyStateMachine.
3. **Overlay VM state sync** — Explicit setting via effects. The state machine is decoupled from the view layer.
4. **Timer ownership** — Coordinator creates timers on effect, timer fires → `sendEvent` → handle → effects. Safe because `@MainActor` serializes.
5. **Async effect execution** — Sync effects execute inline. Async effects launch Tasks that call `sendEvent` on completion.
6. **Generation storage** — Single `generation` property on the struct. Not per-state. Events carry generation for stale rejection.
7. **`notifyHotkeyCancelledByUI`** — Separate effect from `resetHotkeyStateMachine`. Always emitted when entering cancel countdown (matches old behavior where coordinator always called `notifyCancelledByUI()`).
8. **Timer durations** — `startDisplayDismissTimer(seconds:)` with explicit duration: 0.8s (success+paste), 3s (noSpeech), 5s (errors).
9. **Paste failure** — Modeled as `finishing(.success) + pasteFailed → finishing(.pasteFailedCopied)` transition.

## Files Changed

| File | Action | Notes |
|------|--------|-------|
| `Sources/MacParakeetCore/DictationFlow/DictationFlowStateMachine.swift` | **New** | Pure state machine |
| `Tests/MacParakeetTests/DictationFlow/DictationFlowStateMachineTests.swift` | **New** | Exhaustive transition tests |
| `Sources/MacParakeet/App/DictationFlowCoordinator.swift` | **Modified** | Refactored to use state machine |
