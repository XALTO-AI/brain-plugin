#!/usr/bin/env bash
# mock-bootstrap.sh — smoke harness for bootstrap-validator.sh.
#
# Spins up a tmpdir Python http.server serving fake installer + signature
# + attestation-pubkey, runs bootstrap-validator.sh against it in dry-run
# mode, and asserts the four cases:
#
#   1. First run: TOFU pin written, sig verified, exit 0.
#   2. Second run: pin matches, exit 0.
#   3. Pubkey rotated on server with same pin file: exit 2 (TOFU mismatch).
#   4. Tampered installer with fresh pin: exit 3 (sig verify fails).
#
# Live-server smoke is gated on A10 + D1 (the e2e pilot test in cortex/).
# This harness covers the integration shape — pin TOFU, sig verify wiring,
# error-code contract — without depending on the real Mini endpoints.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$REPO_ROOT/hooks/bootstrap-validator.sh"

if [[ ! -x "$BOOTSTRAP" ]]; then
  echo "mock-bootstrap: $BOOTSTRAP not found or not executable" >&2
  exit 1
fi

# Locate an Ed25519-capable openssl (matches the helper's probe order).
find_openssl() {
  for c in \
    "${OPENSSL:-}" \
    "/opt/homebrew/opt/openssl@3/bin/openssl" \
    "/opt/homebrew/opt/openssl@1.1/bin/openssl" \
    "/usr/local/opt/openssl@3/bin/openssl" \
    "/usr/local/opt/openssl@1.1/bin/openssl"; do
    [[ -z "$c" || ! -x "$c" ]] && continue
    case "$("$c" version 2>/dev/null)" in
      "OpenSSL 1.1.1"*|"OpenSSL 3."*|"OpenSSL 4."*) echo "$c"; return 0 ;;
    esac
  done
  return 1
}

OPENSSL_BIN=$(find_openssl) || {
  echo "mock-bootstrap: no Ed25519-capable openssl found (brew install openssl@3)" >&2
  exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

# ---- build a fake "Mini server" tree ----
SERVER_ROOT="$WORK/server"
mkdir -p "$SERVER_ROOT/downloads"

# Generate Ed25519 keypair (the build-attestation key).
"$OPENSSL_BIN" genpkey -algorithm Ed25519 -out "$WORK/ak.pem" 2>/dev/null
"$OPENSSL_BIN" pkey -in "$WORK/ak.pem" -pubout -out "$WORK/ak.pub.pem" 2>/dev/null

# Extract the raw 32-byte pubkey (last 32 bytes of the SPKI DER).
"$OPENSSL_BIN" pkey -in "$WORK/ak.pub.pem" -pubin -outform DER 2>/dev/null \
  | tail -c 32 > "$WORK/ak.pub.raw"

# Publish the attestation pubkey as base64 (the contract: distribution
# endpoint serves base64 text). bootstrap-validator does `base64 -D`.
base64 < "$WORK/ak.pub.raw" > "$SERVER_ROOT/downloads/brain-validator-attestation-pubkey"

# Fake installer + signature over sha256(installer) bytes.
build_installer_and_sig() {
  local pkg="$1"
  local sig="$2"
  printf 'fake brain-validator installer payload %s\n' "$RANDOM" > "$pkg"
  local digest_hex
  digest_hex=$(shasum -a 256 "$pkg" | awk '{print $1}')
  printf '%s' "$digest_hex" | xxd -r -p > "$WORK/digest.bin"
  "$OPENSSL_BIN" pkeyutl -sign -inkey "$WORK/ak.pem" \
       -rawin -in "$WORK/digest.bin" -out "$sig" 2>/dev/null
}

build_installer_and_sig \
  "$SERVER_ROOT/downloads/brain-validator-darwin-latest" \
  "$SERVER_ROOT/downloads/brain-validator-darwin-latest.sig"

# ---- start a python http.server in the tree ----
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
(cd "$SERVER_ROOT" && python3 -m http.server "$PORT" >/dev/null 2>&1) &
SERVER_PID=$!

# Wait for the server to start (≤2s).
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fs "http://127.0.0.1:${PORT}/downloads/brain-validator-attestation-pubkey" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

BASE_URL="http://127.0.0.1:${PORT}"
PIN_FILE="$WORK/pin"

run_bootstrap() {
  BRAIN_SERVER_URL="$BASE_URL" \
    BRAIN_PIN_FILE="$PIN_FILE" \
    BRAIN_BOOTSTRAP_DRY_RUN=1 \
    "$BOOTSTRAP" 2>&1
}

assert_exit() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ✓ $label (exit=$actual)"
  else
    echo "  ✗ $label expected=$expected actual=$actual" >&2
    exit 1
  fi
}

PASSED=0
FAILED=0
note() {
  echo
  echo "=== $* ==="
}

# Case 1: first run, pin file does not exist yet.
note "Case 1: first run — TOFU pin"
rm -f "$PIN_FILE"
out1=$(run_bootstrap; echo "EXIT=$?")
ec1=$(echo "$out1" | tail -1 | sed 's/EXIT=//')
assert_exit 0 "$ec1" "first run dry-run exit 0"
if [[ -f "$PIN_FILE" ]]; then
  echo "  ✓ pin file created at $PIN_FILE"
else
  echo "  ✗ pin file NOT created" >&2; exit 1
fi
echo "$out1" | grep -q "TOFU-pinned" && echo "  ✓ TOFU log emitted" || { echo "  ✗ no TOFU log"; exit 1; }
echo "$out1" | grep -q "installer signature verified" && echo "  ✓ sig-verified log emitted" || { echo "  ✗ no sig-verified log"; exit 1; }

# Case 2: second run, pin matches.
note "Case 2: second run — pin matches"
out2=$(run_bootstrap; echo "EXIT=$?")
ec2=$(echo "$out2" | tail -1 | sed 's/EXIT=//')
assert_exit 0 "$ec2" "second run dry-run exit 0"
echo "$out2" | grep -q "TOFU-pinned" && { echo "  ✗ unexpected TOFU re-pin" >&2; exit 1; } || echo "  ✓ no re-pin (pin honored)"

# Case 3: rotate the server pubkey while keeping the existing pin file.
note "Case 3: pubkey rotation — TOFU mismatch"
"$OPENSSL_BIN" genpkey -algorithm Ed25519 -out "$WORK/ak2.pem" 2>/dev/null
"$OPENSSL_BIN" pkey -in "$WORK/ak2.pem" -pubout -out "$WORK/ak2.pub.pem" 2>/dev/null
"$OPENSSL_BIN" pkey -in "$WORK/ak2.pub.pem" -pubin -outform DER 2>/dev/null \
  | tail -c 32 > "$WORK/ak2.pub.raw"
base64 < "$WORK/ak2.pub.raw" > "$SERVER_ROOT/downloads/brain-validator-attestation-pubkey"
# Re-sign installer with the new key so the rest of the path is honest;
# bootstrap-validator should still abort on the pin mismatch BEFORE sig verify.
"$OPENSSL_BIN" pkeyutl -sign -inkey "$WORK/ak2.pem" \
     -rawin -in "$WORK/digest.bin" -out "$SERVER_ROOT/downloads/brain-validator-darwin-latest.sig" 2>/dev/null

set +e
out3=$(run_bootstrap; echo "EXIT=$?")
set -e
ec3=$(echo "$out3" | tail -1 | sed 's/EXIT=//')
assert_exit 2 "$ec3" "rotation mismatch exit 2"
echo "$out3" | grep -q "pubkey rotated" && echo "  ✓ rotation message emitted" || { echo "  ✗ no rotation message"; exit 1; }

# Case 4: tampered installer, fresh pin file (no rotation).
note "Case 4: tampered installer — sig verify fails"
# Restore the original pubkey on the server and start clean.
base64 < "$WORK/ak.pub.raw" > "$SERVER_ROOT/downloads/brain-validator-attestation-pubkey"
build_installer_and_sig \
  "$SERVER_ROOT/downloads/brain-validator-darwin-latest" \
  "$SERVER_ROOT/downloads/brain-validator-darwin-latest.sig"
# Now corrupt the installer AFTER signing — the sig is over the previous
# bytes, so bootstrap-validator's recomputed digest will not verify.
printf 'TAMPERED\n' >> "$SERVER_ROOT/downloads/brain-validator-darwin-latest"
rm -f "$PIN_FILE"

set +e
out4=$(run_bootstrap; echo "EXIT=$?")
set -e
ec4=$(echo "$out4" | tail -1 | sed 's/EXIT=//')
assert_exit 3 "$ec4" "tampered installer exit 3"
echo "$out4" | grep -q "signature verification failed" && echo "  ✓ sig-fail message emitted" || { echo "  ✗ no sig-fail message"; exit 1; }

# Case 5: missing OAuth token in non-dry-run mode.
note "Case 5: missing BRAIN_OAUTH_TOKEN in non-dry-run"
rm -f "$PIN_FILE"
# Restore an honest installer so the failure is the OAuth-token check, not sig verify.
build_installer_and_sig \
  "$SERVER_ROOT/downloads/brain-validator-darwin-latest" \
  "$SERVER_ROOT/downloads/brain-validator-darwin-latest.sig"
set +e
out5=$(BRAIN_SERVER_URL="$BASE_URL" BRAIN_PIN_FILE="$PIN_FILE" \
       BRAIN_BOOTSTRAP_DRY_RUN=0 BRAIN_OAUTH_TOKEN= \
       "$BOOTSTRAP" 2>&1; echo "EXIT=$?")
set -e
ec5=$(echo "$out5" | tail -1 | sed 's/EXIT=//')
assert_exit 4 "$ec5" "missing oauth token exit 4"

echo
echo "All cases passed."
