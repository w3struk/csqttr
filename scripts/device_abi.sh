#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Reports the ABI of the connected Android device.
#
# Usage: scripts/device_abi.sh
#
# Prints two lines to stdout:
#
#   abi=<abi>        arm64-v8a | armeabi-v7a | x86_64
#   serial=<serial>  adb serial of the device
#
# Exits non-zero with a message on stderr when no device is connected, when
# several devices are connected, or when the device reports an ABI that this
# build does not support.
#
# Gradle calls this at configuration time: the ABI decides how many native
# binaries cargo builds (one `cargo ndk` run per ABI) and which APK splits get
# packaged, so it has to be known before the build is configured. The supported
# list must match `supportedAbis` in app/build.gradle.kts.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SUPPORTED_ABIS=(arm64-v8a armeabi-v7a x86_64)

die() {
    echo >&2
    echo "ERROR: $*" >&2
    exit 1
}

# adb is looked up the same way the other scripts find it: the ADB override
# first, then the SDK, then PATH.
find_adb() {
    local candidate sdk
    if [[ -n "${ADB:-}" ]]; then
        printf '%s\n' "$ADB"
        return 0
    fi
    for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
        if [[ -n "$candidate" && -x "$candidate/platform-tools/adb" ]]; then
            printf '%s\n' "$candidate/platform-tools/adb"
            return 0
        fi
    done
    sdk="$(sed -n 's/^[[:space:]]*sdk\.dir[[:space:]]*=[[:space:]]*//p' "$ROOT/local.properties" 2>/dev/null | sed -n '1p' || true)"
    if [[ -n "$sdk" ]]; then
        sdk="${sdk//\\:/:}"
        sdk="${sdk//\\\\/\\}"
        sdk="${sdk%/}"
        if [[ -x "$sdk/platform-tools/adb" ]]; then
            printf '%s\n' "$sdk/platform-tools/adb"
            return 0
        fi
    fi
    command -v adb 2>/dev/null || true
}

ADB_BIN="$(find_adb)"
[[ -n "$ADB_BIN" ]] || die "adb not found: set ADB, set ANDROID_HOME, or add sdk.dir to local.properties"

# Every adb call is bounded: on a half-alive link the shell session can block
# forever, and this script runs inside Gradle's configuration phase, where a
# hang means a silent hang.
ADB_TIMEOUT_SECONDS="${ADB_TIMEOUT_SECONDS:-10}"

adb_devices() {
    local output status
    output="$(timeout "$ADB_TIMEOUT_SECONDS" "$ADB_BIN" devices 2>/dev/null)" && status=0 || status=$?
    if [[ $status -eq 124 ]]; then
        die "adb timed out after ${ADB_TIMEOUT_SECONDS}s while listing the devices"
    fi
    printf '%s' "$output"
}

read_prop() {
    local prop="$1" output status
    output="$(timeout "$ADB_TIMEOUT_SECONDS" "$ADB_BIN" -s "$SERIAL" shell getprop "$prop" 2>/dev/null | tr -d '\r\n')" && status=0 || status=$?
    if [[ $status -eq 124 ]]; then
        die "adb timed out after ${ADB_TIMEOUT_SECONDS}s while reading $prop from device $SERIAL"
    fi
    printf '%s' "$output"
}

devices="$(adb_devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
if [[ -z "$devices" ]]; then
    unauthorized="$(adb_devices | awk 'NR > 1 && $2 == "unauthorized" { print $1 }')"
    if [[ -n "$unauthorized" ]]; then
        die "device $unauthorized is unauthorized: accept the USB debugging prompt on the device"
    fi
    die "no device in state 'device'. Check the cable, USB debugging, and adb authorization."
fi

device_count="$(grep -c . <<<"$devices")"
if [[ "$device_count" -gt 1 ]]; then
    die "several devices connected, pick one by disconnecting the others or by naming the ABI:
$(sed 's/^/  /' <<<"$devices")"
fi

SERIAL="$devices"

# ro.product.cpu.abilist is the ordered list of ABIs the device runs, best
# first. It is empty on some builds, so the primary ABI is the fallback.
abilist="$(read_prop ro.product.cpu.abilist)"
if [[ -z "$abilist" ]]; then
    abilist="$(read_prop ro.product.cpu.abi)"
fi
[[ -n "$abilist" ]] || die "could not read the ABI list from device $SERIAL (ro.product.cpu.abilist and ro.product.cpu.abi are empty)"

# The first ABI of the device list that this build supports: the device states
# its own preference order, and 64-bit ARM wins over 32-bit there.
ABI=""
IFS=',' read -r -a entries <<<"$abilist"
for entry in "${entries[@]}"; do
    entry="${entry//$'\r'/}"
    entry="${entry//[[:space:]]/}"
    [[ -n "$entry" ]] || continue
    for supported in "${SUPPORTED_ABIS[@]}"; do
        if [[ "$entry" == "$supported" ]]; then
            ABI="$supported"
            break 2
        fi
    done
done

[[ -n "$ABI" ]] || die "device $SERIAL reports ABIs '$abilist' that this build does not support.
       Supported: ${SUPPORTED_ABIS[*]}"

printf 'abi=%s\n' "$ABI"
printf 'serial=%s\n' "$SERIAL"
