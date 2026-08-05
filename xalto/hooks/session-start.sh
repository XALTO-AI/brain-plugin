#!/usr/bin/env bash
# Session start hook — checks workspace-server connectivity and injects
# agent-facing instructions for the upcoming session.
#
# Scope note: this hook does NOT manage the audit-chain validator daemon.
# Validator install, registration, and health monitoring belong to the
# desktop app, which owns the daemon per-device and watches it out-of-band.
# Driving that lifecycle from a per-session Claude Code hook meant every
# customer session re-probed the daemon and could inject instructions to
# run local binaries and block the user's request on the result — an
# install/recovery workflow wedged into unrelated work.

set -euo pipefail

BRAIN_SERVER_URL="${BRAIN_SERVER_URL:-https://127.0.0.1:7443}"

# Workspace-server reachability check. If unreachable, skip the session
# instructions below — there's no point pointing the agent at a server
# that can't answer.
if ! curl -sk --connect-timeout 3 --max-time 5 "${BRAIN_SERVER_URL}/health" > /dev/null 2>&1; then
  echo "WARNING: Workspace server unreachable at ${BRAIN_SERVER_URL}" >&2
  echo "  Start it with: docker compose up -d" >&2
  exit 0
fi

# ── Emit agent instruction(s) on stdout ───────────────────────────────
#
# Claude Code injects SessionStart-hook stdout as a single system reminder.
#
# NOTE: validator lifecycle is deliberately NOT handled here. Installing,
# registering, and health-checking the audit-chain validator daemon is the
# desktop app's job — it owns the daemon on each device and monitors it
# out-of-band. A per-session Claude Code hook is the wrong place for it:
# every customer session would re-probe the daemon and, on any unhealthy
# reading, inject instructions telling the agent to run local binaries and
# refuse the user's actual request until they passed. That put an
# install/recovery workflow in the path of unrelated work.

# Memory-profile instruction. Always emitted; independent of the audit chain.
cat <<EOF
# Brain session start

Call the MCP tool \`memory_load_profile\` now, before responding to the user's
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
