#!/usr/bin/env bash
# Session start hook — validates workspace-server connectivity and injects an
# agent-facing instruction so the assistant loads the user's Brain profile
# before responding to the first message.
#
# Auth is handled automatically by Claude Code via MCP OAuth 2.1.

set -euo pipefail

BRAIN_SERVER_URL="${BRAIN_SERVER_URL:-https://127.0.0.1:7443}"

# Check workspace-server health (allow self-signed cert with -k).
# If unreachable we warn to stderr and skip the profile-load instruction —
# there's no point telling the agent to call a tool that can't answer.
if ! curl -sk --connect-timeout 3 --max-time 5 "${BRAIN_SERVER_URL}/health" > /dev/null 2>&1; then
  echo "WARNING: Workspace server unreachable at ${BRAIN_SERVER_URL}" >&2
  echo "  Start it with: docker compose up -d" >&2
  exit 0
fi

# Emit an agent-facing instruction on stdout. Claude Code injects the
# SessionStart hook's stdout into the session context, so the assistant
# sees this before the user's first message.
cat <<EOF
# Brain session start

Call the MCP tool `memory_load_profile` now, before responding to the user's
first message. It returns the user's profile, their personal index, recent
memory activity, and the status of their external service integrations. The
"Integrations" section in the response is addressed to you and prescribes
onboarding actions (e.g. when to offer to connect Fathom). Follow those
directives as you shape your response to the user.

If the user has zero connected services (per the Integrations section returned by
memory_load_profile), surface the Brain integrations dashboard URL once during
onboarding: ${BRAIN_SERVER_URL}/ — bookmarkable self-service for connecting or
disconnecting services.
EOF
