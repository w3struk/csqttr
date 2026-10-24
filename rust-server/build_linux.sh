#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Linux-only server build pipeline for csqtt.
#
# Produces the three release assets shipped inside the APK and in rust-server/dist:
#   csqtt-linux-amd64   x86_64-unknown-linux-musl
#   csqtt-linux-arm64   aarch64-unknown-linux-musl
#   csqtt-linux-armv7   armv7-unknown-linux-musleabihf
#
# Variant compilation is delegated to build_linux_variants.sh (parallel by default).

set -euo pipefail

SERVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SERVER_DIR/.." && pwd)"

TOOLCHAIN="1.97.1"
MUSL_TARGETS=(
  x86_64-unknown-linux-musl
  aarch64-unknown-linux-musl
  armv7-unknown-linux-musleabihf
)

GENERATED_ROOT="$ROOT/app/build/generated"
ASSETS_DIR="$GENERATED_ROOT/assets"
PROVENANCE_MANIFEST="$GENERATED_ROOT/provenance/csqtt-server.json"
DIST_DIR="$SERVER_DIR/dist"
PROVENANCE_SCRIPT="$ROOT/scripts/server_asset_provenance.sh"

usage() {
  cat <<'EOF'
Usage: build_linux.sh [--tests|--no-tests] [--diagnostics] [--jobs=N] [--sequential]

  --tests         run fmt, clippy and the Linux musl test suite before building
  --no-tests      skip the pre-build checks
  --diagnostics   build every variant with the `diagnostics` cargo feature
  --jobs=N        maximum number of parallel variant builds (default: nproc / 4)
  --sequential    compile the variants one at a time (low-RAM hosts)
  -h, --help      show this help

Without --tests/--no-tests the checks are run unless stdin is a TTY, in which
case the script asks.
EOF
}

RUN_TESTS=""
DIAGNOSTICS=0
JOBS=""
SEQUENTIAL=0

while (($#)); do
  case "$1" in
    --tests) RUN_TESTS=1 ;;
    --no-tests) RUN_TESTS=0 ;;
    --diagnostics) DIAGNOSTICS=1 ;;
    --jobs=*)
      JOBS="${1#--jobs=}"
      if [[ ! "$JOBS" =~ ^[0-9]+$ ]] || ((JOBS < 1)); then
        echo "Error: --jobs expects a positive integer (got '$JOBS')." >&2
        exit 2
      fi
      ;;
    --sequential) SEQUENTIAL=1 ;;
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

if [[ -z "$RUN_TESTS" ]]; then
  if [[ -t 0 ]]; then
    read -rp "Run fmt, clippy and Linux musl tests before building? [Y/n]: " REPLY
    case "${REPLY:-}" in
      [nN] | [nN][oO]) RUN_TESTS=0 ;;
      *) RUN_TESTS=1 ;;
    esac
  else
    RUN_TESTS=1
  fi
fi

FEATURE_ARGS=()
if [[ "$DIAGNOSTICS" == 1 ]]; then
  FEATURE_ARGS=(--features diagnostics)
fi

section() { printf '\n==> %s\n' "$*"; }

section "Checking build prerequisites"
for tool in cargo rustup zig; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: '$tool' not found in PATH." >&2
    if [[ "$tool" == zig ]]; then
      echo "  Install Zig from https://ziglang.org/download/ or your package manager." >&2
    fi
    exit 1
  fi
done
if ! cargo zigbuild --help >/dev/null 2>&1; then
  echo "Error: cargo-zigbuild not found." >&2
  echo "  Install it with: cargo install cargo-zigbuild --locked" >&2
  exit 1
fi

section "Ensuring Rust $TOOLCHAIN (rustfmt, clippy) and musl targets"
rustup toolchain install "$TOOLCHAIN" --profile minimal --component rustfmt --component clippy
rustup target add "${MUSL_TARGETS[@]}" --toolchain "$TOOLCHAIN"
echo "rustc: $(rustc "+$TOOLCHAIN" --version)"
echo "zig:   $(zig version)"

# cargo-zigbuild installs its own zig cc/ar wrappers and handles musl
# self-contained linking. Do not override CARGO_TARGET_*_LINKER here: a manual
# wrapper duplicates crt1.o on aarch64 and cannot map armv7 to zig's
# "arm-linux-musleabihf" triple.

if [[ "$RUN_TESTS" == 1 ]]; then
  section "cargo fmt --all -- --check"
  (
    cd "$SERVER_DIR"
    cargo "+$TOOLCHAIN" fmt --all -- --check
  )

  section "cargo clippy (x86_64-unknown-linux-musl, release, -D warnings)"
  (
    cd "$SERVER_DIR"
    CARGO_TARGET_DIR="$ROOT/build/csqtt-uring-linux-clippy" \
      cargo "+$TOOLCHAIN" clippy --release --target x86_64-unknown-linux-musl \
      ${FEATURE_ARGS[@]+"${FEATURE_ARGS[@]}"} --all-targets -- -D warnings
  )

  section "cargo test (native Linux, x86_64-unknown-linux-musl)"
  (
    cd "$SERVER_DIR"
    CARGO_TARGET_DIR="$ROOT/build/linux-musl-tests" \
      cargo "+$TOOLCHAIN" test --target x86_64-unknown-linux-musl \
      ${FEATURE_ARGS[@]+"${FEATURE_ARGS[@]}"} --all-targets
  )
else
  section "Pre-build checks skipped"
fi

section "Building Linux server variants"
VARIANT_ARGS=()
if [[ -n "$JOBS" ]]; then
  VARIANT_ARGS+=("--jobs=$JOBS")
fi
if [[ "$SEQUENTIAL" == 1 ]]; then
  VARIANT_ARGS+=("--sequential")
fi
if [[ "$DIAGNOSTICS" == 1 ]]; then
  VARIANT_ARGS+=("--cargo-feature=diagnostics")
fi
bash "$SERVER_DIR/build_linux_variants.sh" ${VARIANT_ARGS[@]+"${VARIANT_ARGS[@]}"}

section "Copying server assets"
mkdir -p "$ASSETS_DIR" "$DIST_DIR" "$(dirname "$PROVENANCE_MANIFEST")"

copy_asset() {
  local target="$1"
  local asset="$2"
  local src="$ROOT/build/csqtt-uring-linux-$asset/$target/release/csqtt"

  if [[ ! -f "$src" ]]; then
    echo "Error: expected binary not found: $src" >&2
    exit 1
  fi
  install -m 0755 "$src" "$ASSETS_DIR/$asset"
  install -m 0755 "$src" "$DIST_DIR/$asset"
  echo "  $asset: $(stat -c '%s' "$ASSETS_DIR/$asset") bytes"
}

copy_asset x86_64-unknown-linux-musl csqtt-linux-amd64
copy_asset aarch64-unknown-linux-musl csqtt-linux-arm64
copy_asset armv7-unknown-linux-musleabihf csqtt-linux-armv7

# Obsolete single-asset name from the pre-variant pipeline.
rm -f "$ASSETS_DIR/csqtt"

section "Server asset provenance"
if [[ ! -f "$PROVENANCE_SCRIPT" ]]; then
  echo "Error: provenance script not found: $PROVENANCE_SCRIPT" >&2
  exit 1
fi
FEATURES_CSV=""
if [[ "$DIAGNOSTICS" == 1 ]]; then
  FEATURES_CSV="diagnostics"
fi

# The manifest records the feature set; verify refuses anything it was not told to
# expect, so a diagnostics build can never pass as the production payload.
PROVENANCE_ARGS=(
  "--assets-dir=$ASSETS_DIR"
  "--manifest=$PROVENANCE_MANIFEST"
  "--features=$FEATURES_CSV"
)
# This script knows it enabled the feature on purpose, so it allows exactly that;
# every other caller (Gradle, build_apk.sh) has to opt in explicitly and therefore
# cannot ship a diagnostics payload by accident.
if [[ "$DIAGNOSTICS" == 1 ]]; then
  PROVENANCE_ARGS+=("--allow-feature=diagnostics")
fi
bash "$PROVENANCE_SCRIPT" write "${PROVENANCE_ARGS[@]}"
bash "$PROVENANCE_SCRIPT" verify "${PROVENANCE_ARGS[@]}"

section "Done"
echo "Assets: $ASSETS_DIR/csqtt-linux-{amd64,arm64,armv7}"
echo "Dist:   $DIST_DIR/csqtt-linux-{amd64,arm64,armv7}"
