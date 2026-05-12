#!/usr/bin/env bash
# Session start hook — validates workspace-server connectivity, ensures the
# Brain audit-chain validator daemon is installed and healthy, and injects
# agent-facing instructions for the upcoming session.
#
# The validator install path is intentionally agent-driven: the hook detects
# missing/unhealthy daemon and emits a system-instruction telling Claude Code
# to perform the one-time install via the `audit_device_register` MCP tool.
# This sidesteps the bearer-token-in-env problem entirely — Claude Code's
# MCP session is already authenticated to the user's Google identity, and
# that's the same identity the workspace-server uses to gate registration.
#
# The validator binary itself ships INSIDE this plugin at
# `${PLUGIN_DIR}/binaries/brain-validator`, replacing the deferred Plan task
# B8 signed-installer path. This collapses the validator's distribution
# channel into the plugin marketplace's; the trade-off is documented in the
# audit-chain spec under "Validator daemon distribution".

set -euo pipefail

BRAIN_SERVER_URL="${BRAIN_SERVER_URL:-https://127.0.0.1:7443}"

# Resolve plugin dir from this hook's path so the validator binary, if
# bundled, can be found without depending on PATH or environment variables
# Claude Code may not propagate.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HOOK_DIR/.." && pwd)"

# Detect host triple and pick the matching pre-built binary. The plugin
# bundle ships six release binaries — one per (os, arch) — so a fresh
# install on any supported platform Just Works without compilation. The
# triple detection mirrors what `uname` reports across the shells the
# plugin runs under: zsh / bash on macOS+Linux, Git Bash on Windows.
case "$(uname -s)" in
  Darwin)               BUNDLED_OS="darwin"  ;;
  Linux)                BUNDLED_OS="linux"   ;;
  MINGW*|CYGWIN*|MSYS*) BUNDLED_OS="windows" ;;
  *)                    BUNDLED_OS=""        ;;
esac
case "$(uname -m)" in
  arm64|aarch64)        BUNDLED_ARCH="arm64" ;;
  x86_64|amd64)         BUNDLED_ARCH="amd64" ;;
  *)                    BUNDLED_ARCH=""      ;;
esac
if [[ -n "$BUNDLED_OS" && -n "$BUNDLED_ARCH" ]]; then
  if [[ "$BUNDLED_OS" == "windows" ]]; then
    BUNDLED_VALIDATOR="$PLUGIN_DIR/binaries/brain-validator-${BUNDLED_OS}-${BUNDLED_ARCH}.exe"
  else
    BUNDLED_VALIDATOR="$PLUGIN_DIR/binaries/brain-validator-${BUNDLED_OS}-${BUNDLED_ARCH}"
  fi
else
  BUNDLED_VALIDATOR=""
fi

# The plugin also ships an `audited-kernels.json` allow-list next to
# the validator binaries. The validator resolves the path itself (from
# `current_exe().parent()/audited-kernels.json`) on startup, so we do
# NOT plumb it through install-config — the trust anchor is the
# plugin install path, not operator config. See cortex's
# `docs/decryptd-protocol-reference.md` section "Threat model:
# kernel-version attestation" for the design rationale.

# Workspace-server reachability check. If unreachable we skip everything
# below — there's no point asking the agent to register against a server
# that can't answer.
if ! curl -sk --connect-timeout 3 --max-time 5 "${BRAIN_SERVER_URL}/health" > /dev/null 2>&1; then
  echo "WARNING: Workspace server unreachable at ${BRAIN_SERVER_URL}" >&2
  echo "  Start it with: docker compose up -d" >&2
  exit 0
fi

# Resolve which validator binary to use. Platform-specific bundle wins;
# fall back to PATH so a developer with a hand-built binary on PATH
# (the dev-loop convention documented in CLAUDE.md) can run without
# re-bundling on every change.
if [[ -n "$BUNDLED_VALIDATOR" && -x "$BUNDLED_VALIDATOR" ]]; then
  BRAIN_VALIDATOR="$BUNDLED_VALIDATOR"
elif command -v brain-validator >/dev/null 2>&1; then
  BRAIN_VALIDATOR="$(command -v brain-validator)"
else
  echo "WARNING: brain-validator binary not found." >&2
  if [[ -n "$BUNDLED_VALIDATOR" ]]; then
    echo "  Looked for $BUNDLED_VALIDATOR (host triple ${BUNDLED_OS}-${BUNDLED_ARCH}) and on PATH." >&2
  else
    echo "  Host platform $(uname -s)/$(uname -m) has no bundled binary; install via your" >&2
    echo "  platform's package manager or build from source: https://github.com/XALTO-AI/brain-validator" >&2
  fi
  echo "  Audit chain finality will not advance until the validator is installed." >&2
  BRAIN_VALIDATOR=""
fi

# Probe daemon state. `status --json` is the machine-readable shape the
# detect-and-instruct flow relies on: missing config / unreachable daemon /
# unhealthy daemon all surface deterministically without polluting stderr.
INSTALLED="false"
RUNNING="false"
HEALTHY="false"
STATUS_JSON=""
if [[ -n "$BRAIN_VALIDATOR" ]]; then
  STATUS_JSON="$("$BRAIN_VALIDATOR" status --json 2>/dev/null || true)"
  if [[ -n "$STATUS_JSON" ]]; then
    INSTALLED="$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("true" if d.get("installed") else "false")' 2>/dev/null || echo "false")"
    RUNNING="$(printf '%s'   "$STATUS_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("true" if d.get("running")   else "false")' 2>/dev/null || echo "false")"
    HEALTHY="$(printf '%s'   "$STATUS_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("true" if d.get("healthy")   else "false")' 2>/dev/null || echo "false")"
  fi
fi

# ── Emit agent instruction(s) on stdout ───────────────────────────────
#
# Claude Code injects SessionStart-hook stdout as a single system reminder.
# Multiple sections concatenate into one block; the agent reads them in
# order and acts.

# Brain validator install path — emitted only when needed.
if [[ -n "$BRAIN_VALIDATOR" && "$INSTALLED" != "true" ]]; then
  HOSTNAME_LABEL="$(scutil --get ComputerName 2>/dev/null || hostname)"
  cat <<EOF
# Brain audit-chain validator install required

The Brain audit-chain validator daemon is not installed on this device. It
must be installed before this session can proceed — chain finality depends
on a co-signing validator running on the employee's laptop.

The install uses your current MCP session's authenticated identity, so no
tokens or credentials need to be copied. Perform these steps in order
before responding to the user's first message:

  Step 1 — Generate the device keypair (idempotent: re-running returns
  the same key if one already exists in the keychain):

      $BRAIN_VALIDATOR generate-key --label "$HOSTNAME_LABEL"

  This prints a one-line JSON object with fields \`device_pubkey_b64\`
  and \`device_label\`. Capture both.

  macOS will prompt once for keychain access — that's the OS confirming
  device-key creation. Click "Always Allow" so future ticks don't prompt.

  Step 2 — Register this device with the Mini by calling the MCP tool
  \`audit_device_register\` with:

      {
        "device_pubkey_b64": "<from step 1>",
        "device_label":      "<from step 1>"
      }

  The tool authenticates via the current MCP session (your Google
  identity) and emits a \`validator_added\` block on the audit chain.
  The response is a JSON object with these fields, all of which you'll
  need in step 3:
      device_id
      registered_block_id
      registered_block_sig
      se_mk_pubkey_pem
      attestation_pubkey_b64
      employee_slug

  Step 3 — Persist the registration locally. Combine the step-2 response
  with \`device_label\` from step 1 into a single JSON blob and run:

      $BRAIN_VALIDATOR install-config --registration-json '<json blob>'

  The blob must include all of: device_id, registered_block_id,
  registered_block_sig, se_mk_pubkey_pem, attestation_pubkey_b64,
  employee_slug, device_label. install-config writes the daemon's config
  + persisted-registration files and TOFU-pins the attestation pubkey.

  Step 4 — Register the daemon as a LaunchAgent so it survives reboots.
  This writes ~/Library/LaunchAgents/com.xalto.brain-validator.plist and
  loads it; launchd then keeps the daemon running and respawns on crash:

      $BRAIN_VALIDATOR install-service

  Step 5 — Confirm the daemon is healthy:

      sleep 3
      $BRAIN_VALIDATOR status --json

  The output's \`healthy\` field must be \`true\`. If it is, tell the
  user in one sentence that the validator was installed and proceed with
  their original request.

  If any step fails, do NOT proceed with the user's request. Surface the
  error verbatim and ask the user how they want to handle it. Likely
  causes: decryptd not running on the Mini (keychain or SE-MK pubkey
  unavailable), workspace-server unreachable, or a stale registration
  blocking re-install (use \`$BRAIN_VALIDATOR wipe\` then retry).

EOF
elif [[ -n "$BRAIN_VALIDATOR" && "$RUNNING" != "true" ]]; then
  cat <<EOF
# Brain audit-chain validator daemon is registered but not running

The bootstrap files are on disk (config + registration), but the daemon
process isn't running yet — no status snapshot exists. Bring it back
under launchd before responding to the user's first message:

      $BRAIN_VALIDATOR install-service
      sleep 3
      $BRAIN_VALIDATOR status --json

\`install-service\` is idempotent — if the LaunchAgent is already
loaded, it kicks the existing job. The output's \`healthy\` field must
be \`true\`. If it isn't, surface the \`last_error\` field plus the
tail of ~/Library/Logs/brain-validator.err.log, then ask the user how
to proceed.

EOF
elif [[ -n "$BRAIN_VALIDATOR" && "$HEALTHY" != "true" ]]; then
  cat <<EOF
# Brain audit-chain validator daemon is running but not healthy

The validator is registered and the daemon process has ticked, but its
last status snapshot reports \`healthy: false\`. Diagnose and recover
before responding to the user's first message:

      $BRAIN_VALIDATOR status --json

Check the snapshot's \`last_error\` field. If the daemon exited or
needs to be re-pointed at a recovered server, kick the LaunchAgent:

      $BRAIN_VALIDATOR restart
      sleep 3
      $BRAIN_VALIDATOR status --json

If the second check still reports unhealthy, do NOT proceed with the
user's request. Surface \`last_error\` plus the tail of
~/Library/Logs/brain-validator.err.log and ask the user how to
proceed. Common causes: workspace-server unreachable, the chain has a
break newer than this device's registration, or the device's signing
key was rotated server-side.

EOF
fi

# Existing memory-profile instruction. Always emitted; valid regardless
# of validator state because memory_load_profile is independent of the
# audit chain.
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
