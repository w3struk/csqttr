#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Linux replacement for scripts/build_apk.bat.
#
# Usage: scripts/build_apk.sh [--verify-native-only]
#
# Verifies the provenance of the native server asset and the Rust JNI
# libraries, builds the release APKs with Gradle and copies the split APKs
# into app/release/ with the app version in the name.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
    echo "Usage: $(basename -- "$0") [--verify-native-only]" >&2
}

VERIFY_ONLY=0
if (($# > 1)); then
    usage
    exit 2
fi
case "${1:-}" in
    "") ;;
    --verify-native-only) VERIFY_ONLY=1 ;;
    -h | --help)
        echo "Usage: $(basename -- "$0") [--verify-native-only]"
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac

cd "$ROOT"

# The app version, as it appears in the APK file names.
#
# app/build.gradle.kts is the single place the version is defined, and the
# scripts read it from there instead of keeping a second copy of the number:
# the APK names are built from this value and from the ABI.
apk_version() {
    local versions
    versions="$(sed -n 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$ROOT/app/build.gradle.kts")"
    printf '%s' "${versions%%$'\n'*}"
}

echo "=== CSQTT APK Build Script ==="
echo "=== Output: 4 APKs (universal, arm64-v8a, armeabi-v7a, x86_64) ==="
echo

for helper in scripts/server_asset_provenance.sh scripts/native_client_provenance.sh; do
    if [[ ! -f "$ROOT/$helper" ]]; then
        echo "ERROR: missing $helper" >&2
        exit 1
    fi
done

verify_native() {
    if ! bash "$ROOT/scripts/server_asset_provenance.sh" verify; then
        echo >&2
        echo "ERROR: server asset provenance verification failed." >&2
        echo "       Rebuild the verified server asset with: bash rust-server/build_linux.sh --no-tests" >&2
        return 1
    fi

    if ! bash "$ROOT/scripts/native_client_provenance.sh" verify; then
        echo >&2
        echo "ERROR: native client provenance verification failed." >&2
        echo "       Rebuild the verified JNI libraries with: bash rust-client/build_so.sh --no-tests" >&2
        return 1
    fi
    return 0
}

# --verify-native-only is a pure check. The full run verifies *after* the Gradle
# build: Gradle owns the native payload now and rebuilds it when stale, so a
# pre-check here only rejected clean checkouts and post-`rm -rf build` trees.
if ((VERIFY_ONLY)); then
    verify_native || exit 1
    echo "Native verification completed successfully."
    exit 0
fi

# The Android SDK environment is provided by scripts/android_env.sh when it
# exists; Gradle itself also honours local.properties / ANDROID_HOME.
if [[ -f "$ROOT/scripts/android_env.sh" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT/scripts/android_env.sh" || {
        echo "ERROR: Android SDK/NDK environment setup failed (scripts/android_env.sh)." >&2
        exit 1
    }
    cd "$ROOT"
fi

if [[ ! -f "$ROOT/gradlew" ]]; then
    echo "ERROR: missing gradlew in $ROOT" >&2
    exit 1
fi

echo "Building release APKs..."
if ! bash "$ROOT/gradlew" :app:assembleRelease --no-daemon; then
    echo
    echo "BUILD FAILED! Please check the errors above." >&2
    exit 1
fi

echo "Verifying the native payload that was just built..."
verify_native || exit 1

APK_DIR="$ROOT/app/build/outputs/apk/release"
RELEASE_DIR="$ROOT/app/release"
mkdir -p "$RELEASE_DIR"

APK_VERSION="$(apk_version)"
if [[ -z "$APK_VERSION" ]]; then
    echo "ERROR: could not read versionName from app/build.gradle.kts" >&2
    exit 1
fi

# Stale split from the x86 era is never produced anymore.
rm -f "$APK_DIR/app-x86-release.apk" "$APK_DIR"/app-*-x86-release.apk "$RELEASE_DIR/CSQTT-x86.apk"

human_size() {
    awk -v bytes="$1" 'BEGIN {
        split("B KiB MiB GiB", unit, " ")
        value = bytes
        unit_idx = 1
        while (value >= 1024 && unit_idx < 4) {
            value = value / 1024
            unit_idx++
        }
        printf (unit_idx == 1 ? "%.0f %s" : "%.1f %s"), value, unit[unit_idx]
    }'
}

copy_apk() {
    local abi="$1" src dst bytes
    src="$APK_DIR/app-$APK_VERSION-$abi-release.apk"
    dst="$RELEASE_DIR/CSQTT-$APK_VERSION-$abi.apk"
    if [[ -f "$src" ]]; then
        cp -f "$src" "$dst"
        bytes="$(stat -c %s "$dst")"
        printf '  [OK] %-28s [%s bytes, %s]\n' "$(basename -- "$dst")" "$bytes" "$(human_size "$bytes")"
    else
        printf '  [!!] %-28s not found: %s\n' "$(basename -- "$dst")" "$src" >&2
        MISSING=$((MISSING + 1))
    fi
}

# Clear the targets first: copying over them would leave a mix of fresh and stale
# APKs behind if one of the splits turns out to be missing. Every version goes,
# not just the current one, so an older release never lingers next to a newer one.
for abi in universal arm64-v8a armeabi-v7a x86_64; do
    rm -f "$RELEASE_DIR/CSQTT-$abi.apk" "$RELEASE_DIR"/CSQTT-*"-$abi.apk"
done

MISSING=0
echo
echo "Copying APKs to release folder..."
copy_apk universal
copy_apk arm64-v8a
copy_apk armeabi-v7a
copy_apk x86_64

echo
echo "=== DONE ==="
echo "Output directory: app/release/"
echo
echo "  CSQTT-$APK_VERSION-universal.apk    - all architectures in one APK"
echo "  CSQTT-$APK_VERSION-arm64-v8a.apk    - 64-bit ARM only"
echo "  CSQTT-$APK_VERSION-armeabi-v7a.apk  - 32-bit ARM only"
echo "  CSQTT-$APK_VERSION-x86_64.apk       - 64-bit x86 only"
echo

if ((MISSING > 0)); then
    echo >&2
    echo "ERROR: $MISSING expected APK split(s) were missing from $APK_DIR" >&2
    echo "       Check the Gradle splits configuration: -Pcsqtt.abis must list" >&2
    echo "       arm64-v8a, armeabi-v7a and x86_64 for a full release build." >&2
    echo "       Note that a csqtt.abis setting in ~/.gradle/gradle.properties" >&2
    echo "       also narrows the splits." >&2
    exit 1
fi

exit 0
