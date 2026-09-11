#!/bin/sh
set -eu
agent_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$agent_root/.venv/bin/meeting-agent" --vault "${MEETING_AGENT_VAULT:-/Users/user/obsidian/gtd}" hook
