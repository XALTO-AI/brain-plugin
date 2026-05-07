#!/usr/bin/env bash
# verify-ed25519.sh — verify an Ed25519 detached signature using openssl.
#
# Usage: verify-ed25519.sh <pubkey-raw-file> <message-file> <sig-file>
#
#   pubkey-raw-file  32-byte raw Ed25519 public key (NOT base64, NOT PEM)
#   message-file     the bytes that were signed (e.g. sha256(installer))
#   sig-file         64-byte raw Ed25519 detached signature
#
# Exit codes:
#   0   signature is valid
#   1   signature is invalid (cryptographic mismatch)
#   2   bad arguments / inputs (missing/wrong-size files, missing tools)
#
# This helper exists because:
#   - Pure-`openssl pkeyutl -verify` requires the public key in PEM form
#     (PKCS8 SubjectPublicKeyInfo), but the chain-bootstrap pulls the raw
#     32-byte key from the Mini's distribution endpoint.
#   - Ed25519 verification is supported only by openssl 1.1.1+ / 3.x.
#     macOS ships LibreSSL by default which does not support Ed25519
#     pkeyutl ops; we probe for a working openssl in the usual locations
#     and fail loudly with remediation if none is found.
#
# This script is dependency-free for the brain-plugin and consumed by
# bootstrap-validator.sh (Task C2 of the audit-chain rollout, plan
# 2026-05-07-audit-chain-blockchain-implementation.md).

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: verify-ed25519.sh <pubkey-raw-file> <message-file> <sig-file>" >&2
  exit 2
fi

PUBKEY_RAW="$1"
MESSAGE="$2"
SIG="$3"

for f in "$PUBKEY_RAW" "$MESSAGE" "$SIG"; do
  if [[ ! -f "$f" ]]; then
    echo "verify-ed25519: missing file: $f" >&2
    exit 2
  fi
done

# Validate file sizes. Ed25519 public keys are exactly 32 bytes; signatures
# are exactly 64 bytes. The message can be any length.
PUBKEY_SIZE=$(wc -c < "$PUBKEY_RAW" | tr -d ' ')
SIG_SIZE=$(wc -c < "$SIG" | tr -d ' ')

if [[ "$PUBKEY_SIZE" != "32" ]]; then
  echo "verify-ed25519: pubkey must be 32 bytes (got ${PUBKEY_SIZE})" >&2
  exit 2
fi

if [[ "$SIG_SIZE" != "64" ]]; then
  echo "verify-ed25519: signature must be 64 bytes (got ${SIG_SIZE})" >&2
  exit 2
fi

# Probe for an openssl that supports Ed25519 pkeyutl -rawin. LibreSSL
# (macOS default at /usr/bin/openssl) does not; homebrew openssl@3 or
# openssl@1.1 does.
find_openssl() {
  local candidate
  for candidate in \
    "${OPENSSL:-}" \
    "/opt/homebrew/opt/openssl@3/bin/openssl" \
    "/opt/homebrew/opt/openssl@1.1/bin/openssl" \
    "/usr/local/opt/openssl@3/bin/openssl" \
    "/usr/local/opt/openssl@1.1/bin/openssl" \
    "openssl"; do
    if [[ -z "$candidate" ]]; then
      continue
    fi
    if ! command -v "$candidate" >/dev/null 2>&1; then
      continue
    fi
    # Ed25519 is supported by openssl >= 1.1.1 and is a no-op in LibreSSL's
    # pkeyutl. Probe by version string.
    local v
    v=$("$candidate" version 2>/dev/null || true)
    case "$v" in
      "OpenSSL 1.1.1"*|"OpenSSL 3."*|"OpenSSL 4."*)
        echo "$candidate"
        return 0
        ;;
    esac
  done
  return 1
}

OPENSSL_BIN=$(find_openssl) || {
  echo "verify-ed25519: no openssl with Ed25519 support found." >&2
  echo "  Install via: brew install openssl@3" >&2
  echo "  Or set: OPENSSL=/path/to/openssl" >&2
  exit 2
}

# Build a PKCS8 SubjectPublicKeyInfo PEM from the raw 32-byte pubkey.
# The DER prefix for an Ed25519 SPKI is the 12 bytes:
#   30 2A 30 05 06 03 2B 65 70 03 21 00
# followed by the 32-byte raw pubkey, total 44 bytes. Base64-wrapped in a
# standard PEM envelope is what pkeyutl -pubin expects.
TMPDIR_VED=$(mktemp -d)
trap 'rm -rf "$TMPDIR_VED"' EXIT

PEM="$TMPDIR_VED/pubkey.pem"
{
  printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
  cat "$PUBKEY_RAW"
} | {
  echo "-----BEGIN PUBLIC KEY-----"
  base64
  echo "-----END PUBLIC KEY-----"
} > "$PEM"

# Verify. pkeyutl -rawin tells openssl the input is the message (not a
# pre-hashed digest); Ed25519 hashes internally.
if "$OPENSSL_BIN" pkeyutl -verify \
     -pubin -inkey "$PEM" \
     -rawin -in "$MESSAGE" \
     -sigfile "$SIG" >/dev/null 2>&1; then
  exit 0
else
  exit 1
fi
