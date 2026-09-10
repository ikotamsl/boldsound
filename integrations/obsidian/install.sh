#!/bin/sh
set -eu
# Installs code only. Configure a profile before explicitly installing launchd.
agent_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
agent_python=${MEETING_AGENT_PYTHON:-python3}
"$agent_python" -m venv "$agent_root/.venv"
"$agent_root/.venv/bin/python" -m pip install "$agent_root"
printf '%s\n' "Agent executable: $agent_root/.venv/bin/meeting-agent" "Configure it in Boldsound before enabling automation."
