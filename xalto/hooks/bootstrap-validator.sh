#!/usr/bin/env bash
# bootstrap-validator.sh — first-run installer for the Brain audit-chain
# validator daemon (`brain-validator`).
#
# Runs on session-start when `brain-validator status` reports the daemon
# missing or unhealthy. Downloads the signed installer + signature
# sidecar from the Mini, verifies the build-attestation Ed25519 sig
# (TOFU-pinned on first success), then runs the installer with the
# current MCP OAuth bearer token in env so the daemon's postinstall
# script can register the device.
#
# Reference: docs/superpowers/specs/2026-05-07-audit-chain-blockchain-design.md
# §"Validator daemon distribution & first-run bootstrap" (in cortex/).
# Plan: docs/superpowers/plans/2026-05-07-audit-chain-blockchain-implementation.md
# task C2.
#
# Env:
#   BRAIN_SERVER_URL          base URL of the Mini (default https://127.0.0.1:7443)
#   BRAIN_OAUTH_TOKEN         required unless BRAIN_BOOTSTRAP_DRY_RUN=1; passed
#                              to the installer's postinstall script
#   BRAIN_PIN_FILE            pin path override (tests); default
#                              "$HOME/Library/Application Support/BrainValidator/attestation-pin"
#   BRAIN_BOOTSTRAP_DRY_RUN   if "1": skip `sudo installer`, do not require
#                              BRAIN_OAUTH_TOKEN. Used by the mock smoke harness;
#                              the live install path is exercised in D1.
#
# Exit codes:
#   0   installer ran (or dry-run completed)
#   1   download failure / curl error
#   2   build-attestation pubkey rotated vs. pinned (TOFU mismatch)
#   3   installer signature verification failed
#   4   missing prerequisites (OAuth token in non-dry-run, helper missing, etc.)

set -euo pipefail

BRAIN_SERVER_URL="${BRAIN_SERVER_URL:-https://127.0.0.1:7443}"
PIN_FILE="${BRAIN_PIN_FILE:-$HOME/Library/Application Support/BrainValidator/attestation-pin}"
DRY_RUN="${BRAIN_BOOTSTRAP_DRY_RUN:-0}"

PLATFORM="darwin"

# Resolve the verifier helper next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_HELPER="$SCRIPT_DIR/verify-ed25519.sh"

if [[ ! -x "$VERIFY_HELPER" ]]; then
  echo "bootstrap-validator: missing or non-executable helper at $VERIFY_HELPER" >&2
  exit 4
fi

if [[ "$DRY_RUN" != "1" && -z "${BRAIN_OAUTH_TOKEN:-}" ]]; then
  echo "bootstrap-validator: BRAIN_OAUTH_TOKEN env var required (set BRAIN_BOOTSTRAP_DRY_RUN=1 to test without)" >&2
  exit 4
fi

mkdir -p "$(dirname "$PIN_FILE")"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# 1) Resolve the latest installer URL. `-skL -w %{url_effective}` follows
# redirects (the production endpoint 302s `-latest` → `-<version>`) and
# prints the final URL; we discard the body. If there is no redirect
# (e.g. test mock), url_effective is the input URL itself.
LATEST_URL="${BRAIN_SERVER_URL}/downloads/brain-validator-${PLATFORM}-latest"
if ! VERSIONED_URL=$(curl -fskL --connect-timeout 5 --max-time 30 \
       -o /dev/null -w '%{url_effective}' "$LATEST_URL"); then
  echo "bootstrap-validator: failed to resolve installer URL ($LATEST_URL)" >&2
  exit 1
fi

# 2) Download the installer + the detached signature sidecar.
if ! curl -fsk --connect-timeout 5 --max-time 120 \
       "$VERSIONED_URL" -o "$WORKDIR/installer.pkg"; then
  echo "bootstrap-validator: failed to download installer ($VERSIONED_URL)" >&2
  exit 1
fi

if ! curl -fsk --connect-timeout 5 --max-time 30 \
       "${VERSIONED_URL}.sig" -o "$WORKDIR/installer.pkg.sig"; then
  echo "bootstrap-validator: failed to download installer signature" >&2
  exit 1
fi

# 3) Fetch the build-attestation pubkey. TOFU-pin on first run, refuse to
# proceed on rotation (the user has to confirm via /brain-validator).
if ! SERVER_PUBKEY=$(curl -fsk --connect-timeout 5 --max-time 15 \
       "${BRAIN_SERVER_URL}/downloads/brain-validator-attestation-pubkey"); then
  echo "bootstrap-validator: failed to fetch build-attestation pubkey" >&2
  exit 1
fi

# Normalize trailing whitespace on both sides of the comparison.
SERVER_PUBKEY="${SERVER_PUBKEY%%[[:space:]]}"

if [[ -f "$PIN_FILE" ]]; then
  PINNED=$(cat "$PIN_FILE")
  PINNED="${PINNED%%[[:space:]]}"
  if [[ "$PINNED" != "$SERVER_PUBKEY" ]]; then
    echo "bootstrap-validator: FATAL — build-attestation pubkey rotated." >&2
    echo "  Pinned at: $PIN_FILE" >&2
    echo "  If this is an intended rotation, confirm via /brain-validator and" >&2
    echo "  delete the pin file to re-TOFU. Otherwise treat this as a supply-chain alarm." >&2
    exit 2
  fi
else
  printf '%s\n' "$SERVER_PUBKEY" > "$PIN_FILE"
  echo "bootstrap-validator: TOFU-pinned build-attestation pubkey at $PIN_FILE" >&2
fi

# 4) Verify the installer signature. The Mini signs sha256(installer.pkg)
# bytes with Ed25519; verify-ed25519.sh wraps the raw 32-byte pubkey into
# PKCS8 SPKI internally. The DIGEST goes in as raw 32 bytes (xxd -r -p
# converts hex to binary).
DIGEST_HEX=$(shasum -a 256 "$WORKDIR/installer.pkg" | awk '{print $1}')
printf '%s' "$DIGEST_HEX" | xxd -r -p > "$WORKDIR/digest.bin"

if ! printf '%s' "$SERVER_PUBKEY" | base64 -D > "$WORKDIR/pubkey.raw" 2>/dev/null; then
  echo "bootstrap-validator: failed to decode build-attestation pubkey (expected base64)" >&2
  exit 3
fi

if ! "$VERIFY_HELPER" "$WORKDIR/pubkey.raw" "$WORKDIR/digest.bin" "$WORKDIR/installer.pkg.sig"; then
  echo "bootstrap-validator: FATAL — installer signature verification failed." >&2
  echo "  Either the installer is tampered or the wrong pubkey was published." >&2
  echo "  Refusing to install." >&2
  exit 3
fi

echo "bootstrap-validator: installer signature verified." >&2

# 5) Run the installer with the OAuth token in env. The daemon's
# postinstall script reads BRAIN_OAUTH_TOKEN to perform the one-shot
# `POST /audit/devices/register` call after launchd loads the plist.
if [[ "$DRY_RUN" == "1" ]]; then
  echo "bootstrap-validator: DRY RUN complete (skipping sudo installer)" >&2
  exit 0
fi

export BRAIN_OAUTH_TOKEN
sudo -E installer -pkg "$WORKDIR/installer.pkg" -target / >&2
