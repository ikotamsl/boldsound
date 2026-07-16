#!/usr/bin/env bash
# Verify backticked .swift references in Sources/**/README.md still exist.
#
# Why: per-subsystem READMEs reference Swift files by name (e.g.,
# `MeetingRecordingService.swift`). When code is renamed or deleted,
# those references rot silently. This script runs in CI on every code
# change and fails the build if any reference is broken — making
# drift visible at PR time, when it's cheapest to fix.
#
# Scope: extracts single-backtick tokens ending in `.swift` from each
# README, resolves them against the README's own folder first, then
# falls back to a repo-wide Sources/ search. Paths in fenced code
# blocks (```...```) are also caught, which is fine — they should also
# resolve.
#
# Not in scope: cross-folder relative paths in Markdown links,
# function names like `extractChannelZero(from:)`, event names
# like `engine_started`, or any non-`.swift` reference. The dominant
# drift case is "file got renamed inside the subsystem folder," which
# this script catches.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

ERRORS=0

while IFS= read -r README; do
  README_DIR="$(dirname "$README")"
  # `|| true` so a README with no .swift backticks doesn't fail the
  # whole script under `set -euo pipefail` (grep exits 1 on no match).
  SWIFT_REFS=$(grep -oE '`[A-Za-z_][A-Za-z0-9_]*\.swift`' "$README" | tr -d '`' | sort -u || true)
  for ref in $SWIFT_REFS; do
    if [[ -f "$README_DIR/$ref" ]]; then
      continue
    fi
    # No `-quit`: BSD find (macOS) doesn't support it. Pipe scan is
    # fine — Sources/ is small and the script runs in ~150 ms.
    if find Sources -type f -name "$ref" | grep -q .; then
      continue
    fi
    echo "ERROR: $README references missing file: $ref"
    ERRORS=$((ERRORS + 1))
  done
done < <(find Sources -type f -name 'README.md')

if [[ $ERRORS -gt 0 ]]; then
  echo ""
  echo "Found $ERRORS missing file reference(s) across Sources/**/README.md."
  echo "Either update the README or restore the referenced file."
  exit 1
fi

echo "All Sources/**/README.md backticked .swift references resolve."
