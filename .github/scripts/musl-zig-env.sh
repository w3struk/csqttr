#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Source-only helper: creates zig wrappers for the musl C/C++ toolchain and
# exports the cargo variables that point at them.
#
# Usage:
#   source ../.github/scripts/musl-zig-env.sh
#
# The file is sourced, never executed, so it must not kill the calling shell:
# every failure returns a status instead of calling exit, and the only exit is
# on the "executed directly" path, which is not used.

set -euo pipefail

_musl_zig_env_setup() {
    local zig_cmd wrap_dir name sub target

    zig_cmd="${ZIG:-zig}"
    if ! command -v "$zig_cmd" >/dev/null 2>&1; then
        printf 'musl-zig-env: zig not found (%s)\n' "$zig_cmd" >&2
        return 1
    fi

    if [[ -n "${ZIG_WRAP_DIR:-}" ]]; then
        wrap_dir="$ZIG_WRAP_DIR"
    elif [[ -n "${RUNNER_TEMP:-}" ]]; then
        wrap_dir="$RUNNER_TEMP/csqtt-zigwrap"
    else
        wrap_dir="${TMPDIR:-/tmp}/csqtt-zigwrap"
    fi

    mkdir -p "$wrap_dir" || return 1

    for pair in zigcc:cc zigcxx:c++ zigar:ar; do
        name="${pair%%:*}"
        sub="${pair##*:}"
        target="$wrap_dir/$name"
        if [[ -x "$target" ]]; then
            continue
        fi
        cat >"$target" <<EOF
#!/bin/bash
newargs=()
for a in "\$@"; do
  case "\$a" in
    --target=*) t="\${a#--target=}"; newargs+=("-target" "\${t/unknown-/}");;
    *) newargs+=("\$a");;
  esac
done
exec "$zig_cmd" $sub "\${newargs[@]}"
EOF
        chmod +x "$target" || return 1
    done

    export CC_x86_64_unknown_linux_musl="$wrap_dir/zigcc"
    export CXX_x86_64_unknown_linux_musl="$wrap_dir/zigcxx"
    export AR_x86_64_unknown_linux_musl="$wrap_dir/zigar"
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="$wrap_dir/zigcc"
    export CSQTT_ZIG_WRAP_DIR="$wrap_dir"
}

_musl_zig_env_status=0
_musl_zig_env_setup || _musl_zig_env_status=$?
unset -f _musl_zig_env_setup

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Sourced: return to the caller instead of terminating its shell.
    return "$_musl_zig_env_status"
fi
exit "$_musl_zig_env_status"
