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

# Brain audit-chain validator daemon — gate per the audit-chain blockchain
# design (specs/2026-05-07-audit-chain-blockchain-design.md §"Core, not
# optional"). The daemon is required for chain finality; without it every
# block stays in `mini-only` state.
#
# TODO: flip back to fail-closed (`exit 1`) once Plan task B8's signed
# `.pkg` distribution path is end-to-end — i.e. notarization creds wired,
# server publishes to `<data_root>/distribution/validator-installers/`,
# bootstrap can actually `sudo installer -pkg ... -target /` successfully.
# Until then the gate has to be warn-only, otherwise a clean dev machine
# can't start the plugin (chicken-and-egg: the bootstrap needs a published
# installer the build pipeline can't yet produce). Tracked in the plan's
# "What's deferred" section.
#
# Override: set BRAIN_VALIDATOR_GATE=fail to opt back into fail-closed
# behaviour for environments where the install path is already in place.
BRAIN_VALIDATOR_GATE="${BRAIN_VALIDATOR_GATE:-warn}"

if ! command -v brain-validator >/dev/null 2>&1; then
  echo "WARNING: Brain validator daemon not installed (audit chain unfinalized)." >&2
  echo "  Once Plan task B8's installer path is end-to-end, the bootstrap" >&2
  echo "  hook at xalto/hooks/bootstrap-validator.sh will install on first run." >&2
  if [[ "$BRAIN_VALIDATOR_GATE" == "fail" ]]; then
    if ! bash "$(dirname "${BASH_SOURCE[0]}")/bootstrap-validator.sh"; then
      echo "Brain bootstrap failed; refusing to start session." >&2
      echo "Diagnose with /brain-validator and rerun, or contact your admin." >&2
      exit 1
    fi
  fi
elif ! brain-validator status >/dev/null 2>&1; then
  echo "WARNING: Brain validator daemon installed but not running." >&2
  echo "  Run \`brain-validator restart\` (or /brain-validator restart) to recover." >&2
  if [[ "$BRAIN_VALIDATOR_GATE" == "fail" ]]; then
    exit 1
  fi
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
