#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# shellcheck shell=bash

# Sourceable helper that resolves the Android SDK and NDK on Linux.
# Usage: source "$ROOT/scripts/android_env.sh" || exit 1

if [[ -z "${CSQTT_PROJECT_ROOT:-}" ]]; then
    CSQTT_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export CSQTT_PROJECT_ROOT

_csqtt_is_dir() {
    [[ -n "${1:-}" && -d "$1" ]]
}

_csqtt_sdk_from_local_properties() {
    local file="$CSQTT_PROJECT_ROOT/local.properties"
    [[ -f "$file" ]] || return 1
    local value
    value="$(sed -n 's/^[[:space:]]*sdk\.dir[[:space:]]*=[[:space:]]*//p' "$file" | sed -n '1p')"
    [[ -n "$value" ]] || return 1
    value="${value//\\:/:}"
    value="${value//\\\\/\\}"
    value="${value%/}"
    _csqtt_is_dir "$value" || return 1
    printf '%s\n' "$value"
}

_csqtt_find_sdk() {
    local candidate
    for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
        if _csqtt_is_dir "$candidate"; then
            printf '%s\n' "${candidate%/}"
            return 0
        fi
    done
    if candidate="$(_csqtt_sdk_from_local_properties)"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    for candidate in \
        "$HOME/Android/Sdk" \
        "$HOME/.android-sdk" \
        "$HOME/android-sdk" \
        "/opt/android-sdk" \
        "/usr/lib/android-sdk"; do
        if _csqtt_is_dir "$candidate"; then
            printf '%s\n' "${candidate%/}"
            return 0
        fi
    done
    return 1
}

_csqtt_ndk_has_toolchain() {
    [[ -d "$1/toolchains/llvm/prebuilt/linux-x86_64/bin" ]]
}

_csqtt_find_ndk() {
    local sdk="$1" candidate
    for candidate in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${NDK_HOME:-}"; do
        if _csqtt_ndk_has_toolchain "${candidate%/}"; then
            printf '%s\n' "${candidate%/}"
            return 0
        fi
    done
    if [[ -d "$sdk/ndk" ]]; then
        while IFS= read -r candidate; do
            if _csqtt_ndk_has_toolchain "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(find "$sdk/ndk" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort -Vr)
    fi
    return 1
}

if ! CSQTT_SDK_PATH="$(_csqtt_find_sdk)"; then
    printf 'error: Android SDK not found.\n' >&2
    printf '       Set ANDROID_HOME/ANDROID_SDK_ROOT, add sdk.dir to local.properties,\n' >&2
    printf '       or install the SDK to ~/Android/Sdk.\n' >&2
    return 1 2>/dev/null || exit 1
fi

if ! CSQTT_NDK_PATH="$(_csqtt_find_ndk "$CSQTT_SDK_PATH")"; then
    printf 'error: Android NDK not found.\n' >&2
    printf '       Set ANDROID_NDK_HOME/ANDROID_NDK_ROOT or install an NDK under %s/ndk.\n' "$CSQTT_SDK_PATH" >&2
    return 1 2>/dev/null || exit 1
fi

CSQTT_NDK_VERSION="$(basename "$CSQTT_NDK_PATH")"
export CSQTT_SDK_PATH CSQTT_NDK_PATH CSQTT_NDK_VERSION
export ANDROID_HOME="$CSQTT_SDK_PATH"
export ANDROID_SDK_ROOT="$CSQTT_SDK_PATH"
export ANDROID_NDK_HOME="$CSQTT_NDK_PATH"
export ANDROID_NDK_ROOT="$CSQTT_NDK_PATH"

_csqtt_cmake_bin="$(
    find "$CSQTT_SDK_PATH/cmake" -mindepth 2 -maxdepth 2 -type d -name bin 2>/dev/null |
        LC_ALL=C sort -Vr | sed -n '1p'
)"
if [[ -n "$_csqtt_cmake_bin" && -d "$_csqtt_cmake_bin" ]]; then
    case ":$PATH:" in
        *":$_csqtt_cmake_bin:"*) ;;
        *) PATH="$_csqtt_cmake_bin:$PATH" ;;
    esac
fi

_csqtt_llvm_bin="$CSQTT_NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [[ -d "$_csqtt_llvm_bin" ]]; then
    case ":$PATH:" in
        *":$_csqtt_llvm_bin:"*) ;;
        *) PATH="$_csqtt_llvm_bin:$PATH" ;;
    esac
fi

export PATH

printf 'Using SDK: %s\n' "$CSQTT_SDK_PATH"
printf 'Using NDK: %s (%s)\n' "$CSQTT_NDK_PATH" "$CSQTT_NDK_VERSION"
