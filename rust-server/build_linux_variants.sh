#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Compile the three Linux musl server variants with cargo-zigbuild.
#
# Each variant gets its own CARGO_TARGET_DIR ($ROOT/build/csqtt-uring-linux-<asset>)
# and its own zig cache, so the builds never share state and can run in parallel.
# Logs: $ROOT/build/csqtt-uring-linux-logs/<name>.log
#
# Normally invoked by build_linux.sh, but standalone use works as long as the
# pinned toolchain, the musl target and cargo-zigbuild are installed.

set -euo pipefail

SERVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SERVER_DIR/.." && pwd)"
LOG_DIR="$ROOT/build/csqtt-uring-linux-logs"

TOOLCHAIN="1.97.1"

VARIANT_NAMES=(amd64 arm64 armv7)
VARIANT_TARGETS=(x86_64-unknown-linux-musl aarch64-unknown-linux-musl armv7-unknown-linux-musleabihf)
VARIANT_ASSETS=(csqtt-linux-amd64 csqtt-linux-arm64 csqtt-linux-armv7)

usage() {
  cat <<'EOF'
Usage: build_linux_variants.sh [--jobs=N] [--sequential] [--cargo-feature=NAME]

  --jobs=N       maximum number of parallel variant builds (default: nproc / 4)
  --sequential   compile the variants one at a time (low-RAM hosts)
  --cargo-feature=NAME  enable a cargo feature (repeatable)
  -h, --help     show this help
EOF
}

JOBS=""
SEQUENTIAL=0
CARGO_FEATURES=()

while (($#)); do
  case "$1" in
    --jobs=*)
      JOBS="${1#--jobs=}"
      if [[ ! "$JOBS" =~ ^[0-9]+$ ]] || ((JOBS < 1)); then
        echo "Error: --jobs expects a positive integer (got '$JOBS')." >&2
        exit 2
      fi
      ;;
    --sequential) SEQUENTIAL=1 ;;
    --cargo-feature=*) CARGO_FEATURES+=("${1#--cargo-feature=}") ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

FEATURE_ARGS=()
for feature in "${CARGO_FEATURES[@]:-}"; do
  [[ -n "$feature" ]] && FEATURE_ARGS+=(--features "$feature")
done

if [[ "$SEQUENTIAL" == 1 ]]; then
  JOBS=1
elif [[ -z "$JOBS" ]]; then
  NPROC="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
  [[ "$NPROC" =~ ^[0-9]+$ ]] || NPROC=4
  JOBS=$((NPROC / 4))
  ((JOBS >= 1)) || JOBS=1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "Error: 'cargo' not found in PATH." >&2
  exit 1
fi
if ! command -v zig >/dev/null 2>&1; then
  echo "Error: 'zig' not found in PATH." >&2
  exit 1
fi
if ! cargo zigbuild --help >/dev/null 2>&1; then
  echo "Error: cargo-zigbuild not found." >&2
  echo "  Install it with: cargo install cargo-zigbuild --locked" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
for asset in "${VARIANT_ASSETS[@]}"; do
  mkdir -p "$ROOT/build/csqtt-uring-linux-$asset"
done

build_one() {
  local idx="$1"
  local name="${VARIANT_NAMES[$idx]}"
  local target="${VARIANT_TARGETS[$idx]}"
  local asset="${VARIANT_ASSETS[$idx]}"
  local target_dir="$ROOT/build/csqtt-uring-linux-$asset"
  local log="$LOG_DIR/$name.log"
  local rc=0

  : >"$log"
  printf '[%s] %s -> %s\n' "$name" "$target" "${target_dir#"$ROOT/"}"

  if [[ "$SEQUENTIAL" == 1 ]]; then
    # Stream the compiler output; pipefail keeps cargo's status.
    set +e
    (
      cd "$SERVER_DIR"
      exec env \
        ZIG_GLOBAL_CACHE_DIR="$ROOT/build/zig-cache/$asset/global" \
        ZIG_LOCAL_CACHE_DIR="$ROOT/build/zig-cache/$asset/local" \
        CARGO_TARGET_DIR="$target_dir" \
        cargo "+$TOOLCHAIN" zigbuild --release --target "$target" \
        ${FEATURE_ARGS[@]+"${FEATURE_ARGS[@]}"}
    ) 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e
  else
    (
      cd "$SERVER_DIR"
      exec env \
        ZIG_GLOBAL_CACHE_DIR="$ROOT/build/zig-cache/$asset/global" \
        ZIG_LOCAL_CACHE_DIR="$ROOT/build/zig-cache/$asset/local" \
        CARGO_TARGET_DIR="$target_dir" \
        cargo "+$TOOLCHAIN" zigbuild --release --target "$target" \
        ${FEATURE_ARGS[@]+"${FEATURE_ARGS[@]}"}
    ) >"$log" 2>&1 || rc=$?
  fi

  if ((rc == 0)) && [[ ! -f "$target_dir/$target/release/csqtt" ]]; then
    # Report it, but keep cargo's status: the caller flags the missing binary.
    printf '[%s] error: cargo succeeded but %s is missing\n' \
      "$name" "$target_dir/$target/release/csqtt" >>"$log"
  fi

  return "$rc"
}

format_duration() {
  local secs="$1"
  printf '%02d:%02d' $((secs / 60)) $((secs % 60))
}

TOTAL=${#VARIANT_NAMES[@]}
declare -a PIDS START RESULTS DUR BAD
TOTAL_START=$SECONDS
FAILED=0

echo "================================================================================"
echo "  Building $TOTAL Linux server variants (jobs: $JOBS$([[ "$SEQUENTIAL" == 1 ]] && echo ', sequential'))"
echo "  Targets: amd64 (x86_64), arm64 (aarch64), armv7 (armv7eabihf)"
echo "  Logs:    ${LOG_DIR#"$ROOT/"}/<name>.log"
echo "================================================================================"

idx=0
while ((idx < TOTAL)); do
  batch=()
  for ((slot = 0; slot < JOBS && idx < TOTAL; slot++)); do
    START[$idx]=$SECONDS
    build_one "$idx" &
    PIDS[$idx]=$!
    batch+=("$idx")
    idx=$((idx + 1))
  done

  for i in "${batch[@]}"; do
    if wait "${PIDS[$i]}"; then
      RESULTS[$i]=0
    else
      RESULTS[$i]=$?
      FAILED=1
    fi
    DUR[$i]=$((SECONDS - START[$i]))
    BAD[$i]=0
    if ((RESULTS[$i] == 0)) && [[ ! -f "$ROOT/build/csqtt-uring-linux-${VARIANT_ASSETS[$i]}/${VARIANT_TARGETS[$i]}/release/csqtt" ]]; then
      BAD[$i]=1
      FAILED=1
    fi

    if ((RESULTS[$i] == 0 && BAD[$i] == 0)); then
      printf '  [OK]   %s (%s)\n' "${VARIANT_NAMES[$i]}" "$(format_duration "${DUR[$i]}")"
    else
      printf '  [FAIL] %s (%s)\n' "${VARIANT_NAMES[$i]}" "$(format_duration "${DUR[$i]}")"
    fi
  done
done

echo
echo "================================================================================"
echo "  Linux server build summary ($(format_duration $((SECONDS - TOTAL_START))) total)"
echo "================================================================================"

for i in "${!VARIANT_NAMES[@]}"; do
  if ((RESULTS[$i] == 0 && BAD[$i] == 0)); then
    printf '  [OK]   %s (%s) -> %s (%s bytes)\n' \
      "${VARIANT_NAMES[$i]}" \
      "$(format_duration "${DUR[$i]}")" \
      "${VARIANT_ASSETS[$i]}" \
      "$(stat -c '%s' "$ROOT/build/csqtt-uring-linux-${VARIANT_ASSETS[$i]}/${VARIANT_TARGETS[$i]}/release/csqtt")"
  else
    if ((RESULTS[$i] == 0)); then
      reason="binary missing"
    else
      reason="exit=${RESULTS[$i]}"
    fi
    printf '  [FAIL] %s (%s) %s -> %s\n' \
      "${VARIANT_NAMES[$i]}" \
      "$(format_duration "${DUR[$i]}")" \
      "$reason" \
      "${LOG_DIR#"$ROOT/"}/${VARIANT_NAMES[$i]}.log"
  fi
done

if ((FAILED != 0)); then
  echo
  echo "================================================================================"
  echo "  Build failures - log tail (last 40 lines)"
  echo "================================================================================"
  for i in "${!VARIANT_NAMES[@]}"; do
    if ((RESULTS[$i] != 0 || BAD[$i] != 0)); then
      echo "--- ${VARIANT_NAMES[$i]} (${LOG_DIR#"$ROOT/"}/${VARIANT_NAMES[$i]}.log) ---"
      tail -n 40 "$LOG_DIR/${VARIANT_NAMES[$i]}.log" 2>/dev/null | sed 's/^/  /' || true
      echo
    fi
  done
  exit 1
fi

echo
echo "All Linux server variants compiled successfully."
