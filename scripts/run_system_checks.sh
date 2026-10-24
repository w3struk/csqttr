#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Linux-only replacement for scripts/run_wsl_checks.sh.
#
# Runs the four CSQTT system checks on the local Linux host:
#   1. native (musl) server test binary from the Rust build tree
#   2. standalone TUN device + HTTPS web panel
#   3. systemd service lifecycle (root only)
#   4. docker deployment (optional, root only)
#
# Ports are configurable through the environment:
#   STANDALONE_LISTEN_PORT / STANDALONE_WEB_PORT   (default 46100 / 46102)
#   SYSTEMD_LISTEN_PORT    / SYSTEMD_WEB_PORT      (default 46200 / 46202)
#   DOCKER_LISTEN_PORT     / DOCKER_WEB_PORT       (default 46300 / 46302)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Server assets are generated into app/build/generated/assets (see rust-server/build_linux.sh).
SERVER_BIN="$ROOT/app/build/generated/assets/csqtt-linux-amd64"

STANDALONE_LISTEN_PORT="${STANDALONE_LISTEN_PORT:-46100}"
STANDALONE_WEB_PORT="${STANDALONE_WEB_PORT:-46102}"
SYSTEMD_LISTEN_PORT="${SYSTEMD_LISTEN_PORT:-46200}"
SYSTEMD_WEB_PORT="${SYSTEMD_WEB_PORT:-46202}"
DOCKER_LISTEN_PORT="${DOCKER_LISTEN_PORT:-46300}"
DOCKER_WEB_PORT="${DOCKER_WEB_PORT:-46302}"

SERVICE_NAME="csqtt-test.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
DOCKER_NAME="csqtt-dock-chk"

PIDS=()
WORK_DIRS=()

cleanup() {
    local pid dir
    if ((${#PIDS[@]})); then
        for pid in "${PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    if command -v ip >/dev/null 2>&1; then
        ip link delete csqtt1 2>/dev/null || true
    fi
    if command -v docker >/dev/null 2>&1; then
        docker rm -f "$DOCKER_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE" 2>/dev/null || true
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
    fi
    if ((${#WORK_DIRS[@]})); then
        for dir in "${WORK_DIRS[@]}"; do
            rm -rf "$dir"
        done
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

new_work_dir() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/csqtt-check.XXXXXX")"
    WORK_DIRS+=("$dir")
    printf '%s\n' "$dir"
}

poll_http() {
    local url="$1" attempts="${2:-20}" i
    POLLED_HTTP="000"
    for ((i = 0; i < attempts; i++)); do
        POLLED_HTTP="$(curl -k -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
        if [[ "$POLLED_HTTP" == "200" ]]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

cd "$ROOT"

echo "============================================================"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    OS_PRETTY="$(
        . /etc/os-release 2>/dev/null || true
        printf '%s' "${PRETTY_NAME:-unknown Linux}"
    )"
else
    OS_PRETTY="unknown Linux"
fi
echo "CSQTT Linux Environment Diagnostics: $OS_PRETTY"
echo "============================================================"

if [[ ! -x "$SERVER_BIN" ]]; then
    echo "ERROR: server binary not found or not executable: $SERVER_BIN" >&2
    echo "       Rebuild it with: bash rust-server/build_linux.sh --no-tests" >&2
    echo "       (or let Gradle build it: ./gradlew :app:assembleDebug)" >&2
    exit 1
fi

for tool in ip curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool '$tool' not found in PATH" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------- check 1 ---
# Newest test binary wins, and the selection is deterministic: several variants and
# feature sets can coexist under build/, and `find | head` both raced and truncated
# the pipeline under pipefail.
TEST_ELF=""
while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && {
        TEST_ELF="$candidate"
        break
    }
done < <(
    # Only dev-profile artifacts are test binaries; cargo also drops the product
    # binary into release/deps/csqtt-<hash>, which is not runnable as a test suite.
    find "$ROOT/build" -type f -name 'csqtt-*' -path '*/debug/deps/*' -perm -u+x \
        -printf '%T@\t%p\n' 2>/dev/null |
        LC_ALL=C sort -rn -k1,1 |
        cut -f2-
)
if [[ -z "$TEST_ELF" ]]; then
    echo "[1/4] Native Server Tests: FAILED" >&2
    echo "      No test binary found under $ROOT/build (looked in */debug/deps)." >&2
    echo "      Build the tests first with: bash rust-server/build_linux.sh --tests" >&2
    exit 1
fi

echo -n "[1/4] Running Native Server Tests ($TEST_ELF): "
if ! TEST_OUT="$("$TEST_ELF" --test-threads=4 2>&1)"; then
    echo "FAILED"
    printf '%s\n' "$TEST_OUT" | tail -n 20 >&2
    exit 1
fi
PASSED="$(printf '%s\n' "$TEST_OUT" | sed -n 's/^test result: ok\. \([0-9][0-9]*\) passed.*/\1/p' | tail -n1)"
FAILED_COUNT="$(printf '%s\n' "$TEST_OUT" | sed -n 's/^test result: .* \([0-9][0-9]*\) failed.*/\1/p' | tail -n1)"
if [[ -z "$PASSED" || "${FAILED_COUNT:-0}" != "0" ]]; then
    echo "FAILED"
    printf '%s\n' "$TEST_OUT" | tail -n 20 >&2
    exit 1
fi
echo "OK ($PASSED passed, 0 failed)"

# ---------------------------------------------------------------- check 2 ---
echo -n "[2/4] Testing Standalone TUN (MTU 1500, qlen 1000) & HTTPS Web Panel: "
STANDALONE_DIR="$(new_work_dir)"
STANDALONE_LOG="$STANDALONE_DIR/server.log"
"$SERVER_BIN" \
    --config-dir "$STANDALONE_DIR" \
    --web-port "$STANDALONE_WEB_PORT" \
    --listen "0.0.0.0:$STANDALONE_LISTEN_PORT" >"$STANDALONE_LOG" 2>&1 &
STANDALONE_PID=$!
PIDS+=("$STANDALONE_PID")

TUN_LINE=""
HTTP_CODE="000"
for ((i = 0; i < 20; i++)); do
    sleep 0.5
    TUN_LINE="$(ip link show csqtt1 2>/dev/null || true)"
    HTTP_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' "https://127.0.0.1:$STANDALONE_WEB_PORT/" 2>/dev/null || true)"
    if [[ -n "$TUN_LINE" && "$HTTP_CODE" == "200" ]]; then
        break
    fi
done

kill "$STANDALONE_PID" 2>/dev/null || true
wait "$STANDALONE_PID" 2>/dev/null || true
ip link delete csqtt1 2>/dev/null || true

if [[ -n "$TUN_LINE" ]] && printf '%s\n' "$TUN_LINE" | grep -q "qlen 1000" && [[ "$HTTP_CODE" == "200" ]]; then
    echo "OK (TUN UP, qlen 1000, HTTPS 200)"
else
    echo "FAILED (TUN: ${TUN_LINE:-down}, HTTP: $HTTP_CODE)"
    echo "       TUN creation requires root or CAP_NET_ADMIN." >&2
    if [[ -f "$STANDALONE_LOG" ]]; then
        echo "       --- server log tail ---" >&2
        tail -n 10 "$STANDALONE_LOG" >&2 || true
    fi
    exit 2
fi

# ---------------------------------------------------------------- check 3 ---
echo -n "[3/4] Testing Systemd Service Deployment: "
if [[ $EUID -ne 0 ]]; then
    echo "SKIPPED (requires root)"
elif ! command -v systemctl >/dev/null 2>&1; then
    echo "SKIPPED (systemctl unavailable)"
else
    SYSTEMD_DIR="$(new_work_dir)"
    rm -f "$SERVICE_FILE"
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=CSQTT Test Service
After=network.target

[Service]
Type=simple
ExecStart="$SERVER_BIN" --config-dir "$SYSTEMD_DIR" --web-port $SYSTEMD_WEB_PORT --listen 0.0.0.0:$SYSTEMD_LISTEN_PORT
Restart=no
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if ! systemctl start "$SERVICE_NAME"; then
        echo "  (systemctl start $SERVICE_NAME failed)"
    fi

    SYS_ACTIVE="inactive"
    for ((i = 0; i < 20; i++)); do
        sleep 0.5
        SYS_ACTIVE="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo inactive)"
        HTTP_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' "https://127.0.0.1:$SYSTEMD_WEB_PORT/" 2>/dev/null || true)"
        if [[ "$SYS_ACTIVE" == "active" && "$HTTP_CODE" == "200" ]]; then
            break
        fi
    done

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    ip link delete csqtt1 2>/dev/null || true
    rm -rf "$SYSTEMD_DIR"

    if [[ "$SYS_ACTIVE" == "active" && "$HTTP_CODE" == "200" ]]; then
        echo "OK (systemd active, HTTPS 200, clean stop)"
    else
        echo "FAILED (status: $SYS_ACTIVE, http: $HTTP_CODE)"
        exit 3
    fi
fi

# ---------------------------------------------------------------- check 4 ---
echo -n "[4/4] Testing Docker Deployment: "
if [[ $EUID -ne 0 ]]; then
    echo "SKIPPED (requires root)"
elif ! command -v docker >/dev/null 2>&1; then
    echo "SKIPPED (docker CLI unavailable)"
else
    if ! docker info >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start docker >/dev/null 2>&1 || true
        fi
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "SKIPPED (docker daemon unavailable)"
    else
        DOCKER_DIR="$(new_work_dir)"
        docker rm -f "$DOCKER_NAME" >/dev/null 2>&1 || true
        docker run -d --name "$DOCKER_NAME" \
            --net=host \
            --cap-add=NET_ADMIN \
            -v "$DOCKER_DIR:/etc/csqtt" \
            -v "$SERVER_BIN:/usr/local/bin/csqtt:ro" \
            debian:bookworm-slim \
            /usr/local/bin/csqtt \
            --config-dir /etc/csqtt \
            --web-port "$DOCKER_WEB_PORT" \
            --listen "0.0.0.0:$DOCKER_LISTEN_PORT" >/dev/null 2>&1 || true

        poll_http "https://127.0.0.1:$DOCKER_WEB_PORT/" || true
        DOCK_HTTP="$POLLED_HTTP"

        docker rm -f "$DOCKER_NAME" >/dev/null 2>&1 || true
        ip link delete csqtt1 2>/dev/null || true
        rm -rf "$DOCKER_DIR"

        if [[ "$DOCK_HTTP" == "200" ]]; then
            echo "OK (container up with --cap-add=NET_ADMIN, HTTPS 200)"
        else
            echo "SKIPPED (optional docker check, http: $DOCK_HTTP)"
        fi
    fi
fi

echo
echo "ALL SYSTEM CHECKS PASSED SUCCESSFULLY"
