#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RUST_CLIENT_DIR="$ROOT/rust-client"
GENERATED_ROOT="$ROOT/app/build/generated"
PROVENANCE_SCRIPT="$ROOT/scripts/native_client_provenance.sh"
ANDROID_ENV_SCRIPT="$ROOT/scripts/android_env.sh"
BUILD_ABIS_SCRIPT="$RUST_CLIENT_DIR/build_android_abis.sh"

usage() {
    cat <<'EOF'
Usage: build_so.sh [--tests|--no-tests] [--abis=arm64-v8a,armeabi-v7a,x86_64] [--jobs=N]
                   [--variant=debug|release] [--output-dir=DIR]

Builds the Rust client for Android and installs the shared libraries into
app/build/generated/jniLibs/<variant>, then writes and verifies the native client
provenance next to them. Nothing is written into the source tree.

  --tests      Run the pre-build checks (default when stdin is not a terminal)
  --no-tests   Skip the pre-build checks
  --abis=LIST  Comma-separated subset of arm64-v8a,armeabi-v7a,x86_64
  --jobs=N     Parallel cargo jobs per ABI (default: max(1, nproc/3))
  --variant=V  Android build variant: "debug" uses the Cargo "android-debug"
               profile (inherits dev: opt-level = 1, debuginfo stripped - the
               debug APK carries three ABIs), "release" uses --release
  --output-dir=DIR  Override the install directory
EOF
}

RUN_TESTS=""
ABIS_CSV="arm64-v8a,armeabi-v7a,x86_64"
JOBS=""
VARIANT="release"
OUTPUT_DIR=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tests)
            RUN_TESTS=1
            ;;
        --no-tests)
            RUN_TESTS=0
            ;;
        --abis=*)
            ABIS_CSV="${1#*=}"
            ;;
        --jobs=*)
            JOBS="${1#*=}"
            ;;
        --variant=*)
            VARIANT="${1#*=}"
            ;;
        --output-dir=*)
            OUTPUT_DIR="${1#*=}"
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
    debug)
        PROFILE_DIR="android-debug"
        ;;
    release)
        PROFILE_DIR="release"
        ;;
    *)
        printf 'error: --variant must be debug or release, got: %s\n' "$VARIANT" >&2
        exit 1
        ;;
esac

JNILIBS_DIR="${OUTPUT_DIR:-$GENERATED_ROOT/jniLibs/$VARIANT}"
PROVENANCE_DIR="$GENERATED_ROOT/provenance"
PROVENANCE_MANIFEST="$PROVENANCE_DIR/libclient.$VARIANT.json"

if [ -z "$ABIS_CSV" ]; then
    printf 'error: --abis requires at least one ABI\n' >&2
    exit 1
fi

if [ -n "$JOBS" ]; then
    case "$JOBS" in
        *[!0-9]* | 0)
            printf 'error: --jobs must be a positive integer, got: %s\n' "$JOBS" >&2
            exit 1
            ;;
    esac
fi

if [ -z "$RUN_TESTS" ]; then
    if [ -t 0 ]; then
        read -r -p 'Run fmt, clippy and tests before build? [Y/n]: ' answer || answer=""
        case "$answer" in
            "" | y | Y | yes | YES | Yes) RUN_TESTS=1 ;;
            *) RUN_TESTS=0 ;;
        esac
    else
        RUN_TESTS=1
    fi
fi

if [ ! -f "$ANDROID_ENV_SCRIPT" ]; then
    printf 'error: Android environment helper not found: %s\n' "$ANDROID_ENV_SCRIPT" >&2
    exit 1
fi

# shellcheck source=../scripts/android_env.sh
if ! . "$ANDROID_ENV_SCRIPT"; then
    printf 'error: failed to load %s (Android SDK/NDK not detected).\n' "$ANDROID_ENV_SCRIPT" >&2
    printf '       Set ANDROID_HOME and ANDROID_NDK_HOME, or add sdk.dir to local.properties.\n' >&2
    exit 1
fi

for var in CSQTT_SDK_PATH CSQTT_NDK_PATH ANDROID_HOME ANDROID_NDK_HOME; do
    if [ -z "${!var:-}" ]; then
        printf 'error: %s is not set after sourcing %s\n' "$var" "$ANDROID_ENV_SCRIPT" >&2
        exit 1
    fi
done

require_cmd() {
    local cmd="$1"
    local message="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf 'error: %s\n' "$message" >&2
        exit 1
    fi
}

require_cmd cargo "cargo not found"
if ! cargo ndk --version >/dev/null 2>&1; then
    printf 'error: cargo-ndk not found. Run cargo install cargo-ndk\n' >&2
    exit 1
fi
require_cmd cmake "CMake not found. Install it from the Android SDK Manager."
require_cmd ninja "Ninja not found. Install CMake from the Android SDK Manager."

if [ "$RUN_TESTS" = "1" ]; then
    if ! cargo fmt --version >/dev/null 2>&1; then
        printf 'error: rustfmt not found. Install it with rustup component add rustfmt\n' >&2
        exit 1
    fi
    if ! cargo clippy --version >/dev/null 2>&1; then
        printf 'error: clippy not found. Install it with rustup component add clippy\n' >&2
        exit 1
    fi
fi

printf 'Using CMake: %s\n' "$(command -v cmake)"
printf 'Using Ninja: %s\n' "$(command -v ninja)"

cd "$RUST_CLIENT_DIR"

if [ "$RUN_TESTS" = "1" ]; then
    printf '\n==> Runtime panic lint\n'
    bash "$RUST_CLIENT_DIR/check_no_runtime_panics.sh"

    printf '\n==> cargo fmt --check\n'
    cargo fmt --all -- --check

    printf '\n==> cargo clippy\n'
    cargo clippy --all-targets -- -D warnings

    printf '\n==> cargo test\n'
    cargo test --quiet
else
    printf 'Pre-build checks skipped\n'
fi

mkdir -p "$JNILIBS_DIR" "$PROVENANCE_DIR"

printf '\n==> Building Android ABIs (variant: %s)\n' "$VARIANT"
ABIS_ARGS=("--abis=$ABIS_CSV" "--variant=$VARIANT")
if [ -n "$JOBS" ]; then
    ABIS_ARGS+=("--jobs=$JOBS")
fi
bash "$BUILD_ABIS_SCRIPT" "${ABIS_ARGS[@]}"

install_lib() {
    local abi="$1"
    local target="$2"
    local tdir="$3"
    local src="$ROOT/build/rust-client-android-$VARIANT-$tdir/$target/$PROFILE_DIR/client"
    local dest="$JNILIBS_DIR/$abi/libclient.so"
    if [ ! -f "$src" ]; then
        printf 'error: expected build artifact not found: %s\n' "$src" >&2
        exit 1
    fi
    mkdir -p "$JNILIBS_DIR/$abi"
    cp -f "$src" "$dest"
}

IFS=',' read -r -a ABIS <<<"$ABIS_CSV"
for abi in "${ABIS[@]}"; do
    case "$abi" in
        arm64-v8a)
            install_lib "$abi" aarch64-linux-android arm64
            ;;
        armeabi-v7a)
            install_lib "$abi" armv7-linux-androideabi armv7
            ;;
        x86_64)
            install_lib "$abi" x86_64-linux-android x86_64
            ;;
        *)
            printf 'error: unsupported ABI: %s\n' "$abi" >&2
            exit 1
            ;;
    esac
done

rm -f "$JNILIBS_DIR/x86/libclient.so"

if [ ! -f "$PROVENANCE_SCRIPT" ]; then
    printf 'error: provenance script not found: %s\n' "$PROVENANCE_SCRIPT" >&2
    exit 1
fi

PROVENANCE_ARGS=(
    "--abis=$ABIS_CSV"
    "--variant=$VARIANT"
    "--jni-libs-dir=$JNILIBS_DIR"
    "--manifest=$PROVENANCE_MANIFEST"
)

printf '\n==> Writing native client provenance\n'
bash "$PROVENANCE_SCRIPT" write "${PROVENANCE_ARGS[@]}"

printf '\n==> Verifying native client provenance\n'
bash "$PROVENANCE_SCRIPT" verify "${PROVENANCE_ARGS[@]}"

printf '\n==> Installed libraries\n'
for abi in "${ABIS[@]}"; do
    dest="$JNILIBS_DIR/$abi/libclient.so"
    size="$(stat -c '%s' "$dest")"
    printf '  %s: %s bytes\n' "$abi" "$size"
done

printf '\nBuild completed successfully.\n'
