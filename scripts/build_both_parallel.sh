#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Linux replacement for scripts/build_both_parallel.ps1.
#
# Runs the Rust server and Rust client builds concurrently, keeps a separate
# log for each build under build/ and fails if either build fails.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

if (($#)); then
    echo "Usage: $(basename -- "$0")" >&2
    exit 2
fi

cd "$ROOT"

BUILD_DIR="$ROOT/build"
SERVER_LOG="$BUILD_DIR/server-build.log"
CLIENT_LOG="$BUILD_DIR/client-build.log"
mkdir -p "$BUILD_DIR"
: >"$SERVER_LOG"
: >"$CLIENT_LOG"

echo "Starting simultaneous builds: rust-server and rust-client..."

bash "$ROOT/rust-server/build_linux.sh" --no-tests >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
bash "$ROOT/rust-client/build_so.sh" --no-tests >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

cleanup() {
    kill "$SERVER_PID" "$CLIENT_PID" 2>/dev/null || true
}
trap cleanup EXIT

SERVER_RC=0
CLIENT_RC=0
wait "$SERVER_PID" || SERVER_RC=$?
wait "$CLIENT_PID" || CLIENT_RC=$?
trap - EXIT

echo
echo "=================== SERVER BUILD LOG (tail) ==================="
tail -n 40 "$SERVER_LOG" || true
echo
echo "=================== CLIENT BUILD LOG (tail) ==================="
tail -n 40 "$CLIENT_LOG" || true
echo
echo "=================== BUILD RESULT ==================="
echo "server: exit $SERVER_RC (log: ${SERVER_LOG#"$ROOT"/})"
echo "client: exit $CLIENT_RC (log: ${CLIENT_LOG#"$ROOT"/})"

if ((SERVER_RC != 0 || CLIENT_RC != 0)); then
    echo "BUILD FAILED: one or both builds failed." >&2
    exit 1
fi

echo "Both builds completed successfully."
exit 0
