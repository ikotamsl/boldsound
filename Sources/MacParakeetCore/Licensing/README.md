# Licensing

> Retained purchase-activation plumbing. Currently dormant; **do not delete**.

## Entry point

`EntitlementsService` — the single read/write surface for entitlement
state. Every code path that asks "is this build licensed?" goes
through it.

## What's here

- `EntitlementsService.swift` — entitlement state machine; owns trial
  and licensed transitions and persists to keychain via
  `KeyValueStore`.
- `Entitlements.swift` — pure value types describing the entitlement
  state.
- `LemonSqueezyLicenseAPI.swift` — network client for license-key
  activation and validation against LemonSqueezy.
- `KeychainKeyValueStore.swift` + `KeyValueStore.swift` — generic
  keychain-backed K/V used by this folder. Not licensing-specific in
  shape, but currently used only here.

## Cross-references

- ADR-003 — one-time purchase pricing (historical, kept for context).
- ADR-006 — trial + license activation (historical, kept for context).
- `CLAUDE.md` § "Known Pitfalls — General" — repeats the
  do-not-delete rule for project agents.

## What to know before editing

**This is retained future-option code, not dead code.** Current
public DMG builds are free and GPL-3.0; entitlements are always
unlocked. The plumbing here exists so a future GPL-compatible paid
distribution channel can be activated without re-implementing
licensing from scratch.

**Do not delete `EntitlementsService`, `LemonSqueezyLicenseAPI`,
entitlement state types, or trial/license telemetry as dead code.**
This applies to refactors, "cleanup" passes, lint sweeps, and any
agent that thinks the unused code looks suspicious. The only
acceptable removal path is: explicit owner direction + an ADR or
spec update reflecting the decision.

**Do not introduce active gating from these types into user-facing
flows.** Calling `EntitlementsService.isLicensed` to enable a
feature is fine if the feature already gates correctly when
licensed == true (which it always is today). Adding a *new*
gate on dormant infrastructure is the wrong direction and would
need owner sign-off.

**Keychain access is not free on first call.** The first read after
launch can take tens of milliseconds. Cache results in callers if
hot-pathing.

## How to verify a change

- `swift test --filter EntitlementsService` (and any
  `LemonSqueezy*` tests that exist).
- `swift test` — full suite. Licensing changes can ripple through
  telemetry (entitlement state is included in some events).
- Manual: confirm a fresh launch still treats the build as licensed
  (current behaviour) and that no UI surface gates on entitlement
  state.
