#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$ROOT/rust-client"
DEFAULT_LOG_DIR="$ROOT/build/rust-client-android-logs"

usage() {
    cat <<'EOF'
Usage: build_android_abis.sh [--abis=arm64-v8a,armeabi-v7a,x86_64] [--jobs=N] [--log-dir=DIR]
                            [--variant=debug|release]

Builds the Android client ABIs concurrently, one log file per ABI.
  --abis=LIST    Comma-separated subset of arm64-v8a,armeabi-v7a,x86_64
  --jobs=N       Parallel cargo jobs per ABI (default: max(1, nproc/3))
  --log-dir=DIR  Directory for per-ABI logs (default: build/rust-client-android-logs)
  --variant=V    Android build variant (default: release). "debug" uses the Cargo
                 "android-debug" profile (inherits dev: opt-level = 1, debuginfo
                 stripped) and its own cargo target directory, so switching
                 variants never mixes artifacts.
EOF
}

ABIS_CSV="arm64-v8a,armeabi-v7a,x86_64"
JOBS=""
VARIANT="release"
LOG_DIR="$DEFAULT_LOG_DIR"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --abis=*)
            ABIS_CSV="${1#*=}"
            ;;
        --jobs=*)
            JOBS="${1#*=}"
            ;;
        --log-dir=*)
            LOG_DIR="${1#*=}"
            ;;
        --variant=*)
            VARIANT="${1#*=}"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'error: unknown argument: %s\n\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

case "$VARIANT" in
    debug) PROFILE_ARGS=(--profile android-debug) ;;
    release) PROFILE_ARGS=(--release) ;;
    *)
        printf 'error: --variant must be debug or release, got: %s\n' "$VARIANT" >&2
        exit 1
        ;;
esac

if [ -z "$ABIS_CSV" ]; then
    printf 'error: --abis requires at least one ABI\n' >&2
    exit 1
fi

IFS=',' read -r -a ABIS <<<"$ABIS_CSV"
if [ "${#ABIS[@]}" -eq 0 ]; then
    printf 'error: --abis requires at least one ABI\n' >&2
    exit 1
fi

if [ -z "$JOBS" ]; then
    CORES="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    JOBS=$((CORES / 3))
    if [ "$JOBS" -lt 1 ]; then
        JOBS=1
    fi
else
    case "$JOBS" in
        *[!0-9]* | 0)
            printf 'error: --jobs must be a positive integer, got: %s\n' "$JOBS" >&2
            exit 1
            ;;
    esac
fi

target_for_abi() {
    case "$1" in
        arm64-v8a) printf 'aarch64-linux-android\n' ;;
        armeabi-v7a) printf 'armv7-linux-androideabi\n' ;;
        x86_64) printf 'x86_64-linux-android\n' ;;
        *) return 1 ;;
    esac
}

target_dir_for_abi() {
    case "$1" in
        arm64-v8a) printf '%s\n' "$ROOT/build/rust-client-android-$VARIANT-arm64" ;;
        armeabi-v7a) printf '%s\n' "$ROOT/build/rust-client-android-$VARIANT-armv7" ;;
        x86_64) printf '%s\n' "$ROOT/build/rust-client-android-$VARIANT-x86_64" ;;
        *) return 1 ;;
    esac
}

for abi in "${ABIS[@]}"; do
    if [ -z "$abi" ] || ! target_for_abi "$abi" >/dev/null; then
        printf 'error: unsupported ABI: %s (expected one of arm64-v8a, armeabi-v7a, x86_64)\n' "$abi" >&2
        exit 1
    fi
done

CARGO_BIN="$(command -v cargo || true)"
if [ -z "$CARGO_BIN" ]; then
    printf 'error: cargo not found on PATH\n' >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
LOG_DIR="$(cd -- "$LOG_DIR" && pwd)"
STATUS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/csqtt-android-abis.XXXXXX")"
cleanup() {
    rm -rf "$STATUS_DIR"
}
trap cleanup EXIT

fmt_duration() {
    printf '%02d:%02d' "$(($1 / 60))" "$(($1 % 60))"
}

printf '========================================================================\n'
printf '  Building %d Android Client ABI(s) in Parallel\n' "${#ABIS[@]}"
printf '  ABIs: %s (%s jobs each, variant: %s)\n' "$ABIS_CSV" "$JOBS" "$VARIANT"
printf '  Logs: %s\n' "$LOG_DIR"
printf '========================================================================\n'

cd "$CLIENT_DIR"

PIDS=()
START_ALL="$(date +%s)"

for abi in "${ABIS[@]}"; do
    target="$(target_for_abi "$abi")"
    tdir="$(target_dir_for_abi "$abi")"
    log="$LOG_DIR/$abi.log"
    mkdir -p "$tdir"
    : >"$log"

    printf '  -> %s (%s), log: %s\n' "$abi" "$target" "$log"

    (
        started="$(date +%s)"
        if env CMAKE_BUILD_PARALLEL_LEVEL="$JOBS" \
            "$CARGO_BIN" ndk -t "$abi" -P 26 build "${PROFILE_ARGS[@]}" --jobs "$JOBS" --target-dir "$tdir" \
            >"$log" 2>&1; then
            rc=0
        else
            rc=$?
        fi
        finished="$(date +%s)"
        printf '%s %s\n' "$rc" "$((finished - started))" >"$STATUS_DIR/$abi.status"
        exit 0
    ) &
    PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do
    wait "$pid" || true
done

TOTAL_DURATION=$(( $(date +%s) - START_ALL ))

printf '\n========================================================================\n'
printf '  Android Native Build Summary (%s total):\n' "$(fmt_duration "$TOTAL_DURATION")"
printf '========================================================================\n'

FAILED=0
for abi in "${ABIS[@]}"; do
    rc="unknown"
    dur=0
    if [ -f "$STATUS_DIR/$abi.status" ]; then
        read -r rc dur <"$STATUS_DIR/$abi.status"
    fi
    if [ "$rc" = "0" ]; then
        printf '  [OK]   %s (%s)\n' "$abi" "$(fmt_duration "${dur:-0}")"
    else
        printf '  [FAIL] %s (ExitCode %s, %s)\n' "$abi" "$rc" "$(fmt_duration "${dur:-0}")"
        FAILED=$((FAILED + 1))
    fi
done

if [ "$FAILED" -ne 0 ]; then
    printf '\n========================================================================\n'
    printf '  Build Failures - Log Tail (last 40 lines):\n'
    printf '========================================================================\n'
    for abi in "${ABIS[@]}"; do
        rc="unknown"
        if [ -f "$STATUS_DIR/$abi.status" ]; then
            read -r rc _ <"$STATUS_DIR/$abi.status"
        fi
        if [ "$rc" != "0" ]; then
            printf '%s\n' "--- Log for $abi ($LOG_DIR/$abi.log) ---"
            if [ -f "$LOG_DIR/$abi.log" ]; then
                tail -n 40 "$LOG_DIR/$abi.log" | sed 's/^/  /'
            else
                printf '  (log file missing)\n'
            fi
        fi
    done
    exit 1
fi

printf '\nAll Android client ABIs compiled successfully.\n'
