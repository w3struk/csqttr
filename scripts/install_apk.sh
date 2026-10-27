#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Installs a built APK with adb instead of AGP's own installer.
#
# Usage: scripts/install_apk.sh --variant <debug|release>
#                               [--application-id <id>]
#                               [--device <serial>]
#                               [--list]
#
# Environment:
#   PUSH_METHOD=auto|push|shell   transport for the APK (default: auto)
#   PUSH_TIMEOUT_SECONDS=300      bound for one transfer attempt
#   INSTALL_TIMEOUT_SECONDS=600   bound for `pm install`
#
# Why not ./gradlew :app:installRelease: when AGP installs a baseline profile
# next to the APK it switches ddmlib to the session installer, which streams
# the file through the shell protocol instead of pushing it. Measured on a
# CPH2449 over USB that is ~130 KB/s, so a 24 MB APK costs three minutes
# before the device even starts installing.
#
# So the install is two explicit phases instead of `adb install`: push the APK to
# /data/local/tmp, then let `pm install` read it from there. The baseline profile
# stays inside the APK and is applied on first launch instead of at install time.
#
# The transfer is the slow part of an install, so it uses the fastest transport
# adb offers. Measured on the same device with a 23 MB APK:
#
#   adb push -Z                36.3 MB/s    0.64 s    <- the default
#   adb shell "cat > file"    ~130 KB/s      183 s
#   adb push (compressed)     ~131 KB/s      stalls
#
# The shell transport and the compressed sync protocol crawl at the same rate,
# so the size of the APK, the device and the cable are not the variable - the
# transport is. `push -Z` (sync without compression) is the only host-to-device
# path that is fast, which is why it goes first and the shell transport
# follows it for adb builds that cannot do -Z.
#
# `adb push` is not used unguarded: its sync protocol does not always return.
# On this device the bytes arrive, the file on the device is complete, and the
# command then hangs in the teardown of the sync session until it is killed -
# four of five pushes of 20 MB, the file full every time. The result of a
# transfer is therefore the file on the device, not the exit of the command:
# the transfer runs in the background, and as soon as the size on the device
# matches the local one, the command is killed and the transfer counts as
# done. Waiting for the return instead would cost the whole timeout per
# install for bytes that are already there.
#
# Every attempt is bounded by PUSH_TIMEOUT_SECONDS, and the file that lands on
# the device is compared against the local size, so a truncated transfer cannot
# pass unnoticed.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ADB="${ADB:-adb}"
DEVICE_WAIT_SECONDS="${DEVICE_WAIT_SECONDS:-120}"

usage() {
    cat >&2 <<EOF
Usage: $(basename -- "$0") --variant <debug|release>
                                  [--application-id <id>] [--device <serial>]
                                  [--list]

  --variant          debug or release, selects app/build/outputs/apk/<variant>.
  --application-id   package name to report after a successful install.
  --device           adb serial; defaults to ANDROID_SERIAL, then to the only
                     connected device.
  --list             list the APKs present for the variant and exit.

Environment:
  PUSH_METHOD        auto (default), push or shell - transport for the APK.
EOF
}

die() {
    echo >&2
    echo "ERROR: $*" >&2
    exit 1
}

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

VARIANT=""
APPLICATION_ID=""
SERIAL="${ANDROID_SERIAL:-}"
LIST_ONLY=0

while (($# > 0)); do
    case "$1" in
        --variant)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            VARIANT="$2"
            shift 2
            ;;
        --variant=*) VARIANT="${1#*=}"; shift ;;
        --application-id)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            APPLICATION_ID="$2"
            shift 2
            ;;
        --application-id=*) APPLICATION_ID="${1#*=}"; shift ;;
        --device)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            SERIAL="$2"
            shift 2
            ;;
        --device=*) SERIAL="${1#*=}"; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

case "$VARIANT" in
    debug | release) ;;
    "") usage; exit 2 ;;
    *) die "--variant must be debug or release, got: $VARIANT" ;;
esac

APK_DIR="$ROOT/app/build/outputs/apk/$VARIANT"

if ((LIST_ONLY)); then
    echo "APKs in $APK_DIR:"
    shopt -s nullglob
    for apk in "$APK_DIR"/*.apk; do
        printf '  %10d  %s\n' "$(stat -c %s "$apk")" "$(basename -- "$apk")"
    done
    exit 0
fi

[[ -d "$APK_DIR" ]] || die "no APK directory for the $VARIANT variant: $APK_DIR (build it first)"

command -v "$ADB" >/dev/null 2>&1 || die "adb not found: $ADB (set ADB to its path)"

connected_devices() {
    # `|| true` matters: with pipefail a failing adb would otherwise abort the
    # script before it can say anything useful about the device.
    "$ADB" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }' || true
}

device_state() {
    "$ADB" devices 2>/dev/null | awk -v serial="$1" 'NR > 1 && $1 == serial { print $2; exit }' || true
}

select_device() {
    if [[ -n "$SERIAL" ]]; then
        return
    fi
    local devices
    devices="$(connected_devices)"
    if [[ -z "$devices" ]]; then
        die "no device in state 'device'. Check the cable, USB debugging, and adb authorization."
    fi
    local count
    count="$(grep -c . <<<"$devices")"
    if ((count > 1)); then
        die "several devices connected, pick one with --device or ANDROID_SERIAL:
$(sed 's/^/  /' <<<"$devices")"
    fi
    SERIAL="$devices"
}

require_device_present() {
    # A serial adb has never heard of must fail now: waiting for it would burn the
    # whole timeout on a device that is not going to appear.
    [[ -n "$(device_state "$SERIAL")" ]] ||
        die "device $SERIAL is not connected. adb sees:
$("$ADB" devices | awk 'NR > 1 { print "  " $0 }')
       If the device was reconnected under another serial, Gradle still holds
       the old one in its configuration cache: re-run with --no-configuration-cache."
}

wait_for_device() {
    local state
    state="$(device_state "$SERIAL")"
    [[ "$state" == "device" ]] && return 0
    # An unauthorized device only turns into a usable one when someone taps
    # "Allow USB debugging" on the phone, so waiting out the whole timeout would
    # just hide the reason.
    [[ "$state" == "unauthorized" ]] &&
        die "device $SERIAL is unauthorized: accept the USB debugging prompt on the device"
    if ! timeout "$DEVICE_WAIT_SECONDS" "$ADB" -s "$SERIAL" wait-for-device; then
        die "device $SERIAL stayed in state '${state:-unknown}' for ${DEVICE_WAIT_SECONDS}s"
    fi
    state="$("$ADB" -s "$SERIAL" get-state 2>/dev/null || true)"
    [[ "$state" == "device" ]] || die "device $SERIAL is in state '${state:-unknown}', expected 'device'"
}

select_device
require_device_present
wait_for_device

boot_completed="$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
[[ "$boot_completed" == "1" ]] ||
    die "device $SERIAL has not finished booting (sys.boot_completed='${boot_completed:-}')"

device_abi="$("$ADB" -s "$SERIAL" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r' || true)"
[[ -n "$device_abi" ]] || die "could not read ro.product.cpu.abi from device $SERIAL"

# Prefer the split built for this device: it is smaller than the universal APK
# and matches what AGP used to install. The universal APK only exists when more
# than one ABI was selected, so it is the fallback, not the primary choice.
#
# The APKs carry the app version in their names
# (app-<version>-<abi>-<variant>.apk), so the name is built from the version,
# the ABI and the variant.
APK_VERSION="$(apk_version)"
[[ -n "$APK_VERSION" ]] || die "could not read versionName from app/build.gradle.kts"
ABI_APK="app-$APK_VERSION-$device_abi-$VARIANT.apk"
UNIVERSAL_APK="app-$APK_VERSION-universal-$VARIANT.apk"

APK=""
for candidate in "$APK_DIR/$ABI_APK" "$APK_DIR/$UNIVERSAL_APK"; do
    if [[ -f "$candidate" ]]; then
        APK="$candidate"
        break
    fi
done

if [[ -z "$APK" ]]; then
    echo >&2
    echo "ERROR: no APK for $VARIANT matches this device ($device_abi)." >&2
    echo "       Looked for $ABI_APK and $UNIVERSAL_APK" >&2
    echo "       in $APK_DIR. Present:" >&2
    shopt -s nullglob
    for candidate in "$APK_DIR"/*.apk; do
        echo "         $(basename -- "$candidate")" >&2
    done
    shopt -u nullglob
    # A split for another ABI means the build was configured for another
    # device: Gradle keeps the ABI it detected in the configuration cache and
    # a device that changed afterwards is not noticed there. An APK of another
    # version is not a sign of that, so the ABI is matched, not parsed: it is
    # the token before the variant, and "arm64-v8a" carries a dash of its own.
    shopt -s nullglob
    for candidate in "$APK_DIR"/app-*-"$VARIANT.apk"; do
        name="$(basename -- "$candidate")"
        if [[ "$name" != app-*-"$device_abi-$VARIANT.apk" && "$name" != app-*-"universal-$VARIANT.apk" ]]; then
            echo >&2
            echo "       The build was made for another ABI: Gradle keeps the device ABI it" >&2
            echo "       detected in the configuration cache. Re-run with" >&2
            echo "       -Pcsqtt.abis=$device_abi or --no-configuration-cache." >&2
            break
        fi
    done
    shopt -u nullglob
    exit 1
fi

apk_bytes="$(stat -c %s "$APK")"
echo "Device:     $SERIAL ($device_abi)"
echo "APK:        $(basename -- "$APK") ($((apk_bytes / 1024 / 1024)) MB)"

# Two explicit phases, never `adb install`: this adb build has no
# --no-streaming, so it always streams the APK through a long-lived shell
# session. That protocol stalls here, and it is the same one that makes AGP's
# installer take minutes. A push plus `pm install` moves the same 24 MB in
# about three seconds.
REMOTE_APK="/data/local/tmp/csqtt-$VARIANT-$$.apk"
PUSH_TIMEOUT_SECONDS="${PUSH_TIMEOUT_SECONDS:-300}"
INSTALL_TIMEOUT_SECONDS="${INSTALL_TIMEOUT_SECONDS:-600}"
TRANSFER_POLL_SECONDS="${TRANSFER_POLL_SECONDS:-1}"
TRANSFER_LOG="$(mktemp "${TMPDIR:-/tmp}/csqtt-transfer.XXXXXX")"

cleanup() {
    # Bounded, because this runs from an EXIT trap: on a dead device an unbounded
    # `adb shell rm` would turn every exit into a hang.
    if [[ -n "$REMOTE_APK" ]]; then
        timeout 10 "$ADB" -s "$SERIAL" shell rm -f "$REMOTE_APK" >/dev/null 2>&1 || true
    fi
    if [[ -n "$TRANSFER_LOG" ]]; then
        rm -f "$TRANSFER_LOG"
    fi
}
trap cleanup EXIT

PM_OUTPUT=""
PHASE=""
TRANSFER_OUTPUT=""
TRANSFER_PID=""

# Size of a file on the device, empty when it cannot be read.
remote_file_size() {
    local path="$1" size
    size="$("$ADB" -s "$SERIAL" shell stat -c %s "$path" 2>/dev/null | tr -d '\r' || true)"
    if [[ -z "$size" ]]; then
        # stat -c is not everywhere; wc -c reads the same number.
        size="$("$ADB" -s "$SERIAL" shell "wc -c < '$path'" 2>/dev/null | tr -d '\r ' || true)"
    fi
    printf '%s' "$size"
}

# The result of a transfer is the file on the device, not the exit of the adb
# command.
#
# On this device adb regularly does not return: the bytes arrive, the file on
# the device is complete, and the command then hangs in the teardown of the
# sync session until it is killed (four of five pushes of 20 MB). Waiting for
# that return costs the whole timeout per install, and the bytes are already
# there. So the transfer runs in the background and the size of the file on
# the device decides: as soon as it matches the local one, the transfer is
# done and the command is killed.
transfer_watch() {
    local deadline size status
    deadline=$((SECONDS + PUSH_TIMEOUT_SECONDS))
    while kill -0 "$TRANSFER_PID" 2>/dev/null; do
        size="$(remote_file_size "$REMOTE_APK")"
        if [[ "$size" == "$apk_bytes" ]]; then
            TRANSFER_OUTPUT="$(cat "$TRANSFER_LOG")"
            kill "$TRANSFER_PID" 2>/dev/null || true
            wait "$TRANSFER_PID" 2>/dev/null || true
            return 0
        fi
        if (( SECONDS >= deadline )); then
            kill "$TRANSFER_PID" 2>/dev/null || true
            wait "$TRANSFER_PID" 2>/dev/null || true
            TRANSFER_OUTPUT="$(cat "$TRANSFER_LOG")"
            # The bytes may have arrived in the last moment: the size decides.
            if [[ "$(remote_file_size "$REMOTE_APK")" == "$apk_bytes" ]]; then
                return 0
            fi
            return 1
        fi
        sleep "$TRANSFER_POLL_SECONDS"
    done
    status=0
    wait "$TRANSFER_PID" 2>/dev/null || status=$?
    TRANSFER_OUTPUT="$(cat "$TRANSFER_LOG")"
    if (( status != 0 )) && [[ "$(remote_file_size "$REMOTE_APK")" != "$apk_bytes" ]]; then
        return 1
    fi
    return 0
}

# `cat > file` on the device reads the APK from stdin. This transport needs no
# sync protocol, but it crawls at ~130 KB/s on the test device, so it is the
# fallback and not the default.
transfer_via_shell() {
    TRANSFER_OUTPUT=""
    "$ADB" -s "$SERIAL" shell "cat > '$REMOTE_APK'" <"$APK" >"$TRANSFER_LOG" 2>&1 &
    TRANSFER_PID=$!
    transfer_watch
}

# -Z turns off the compressed sync stream: the compressed one is the one that
# stalls. This is the fast path - 36 MB/s against ~130 KB/s for the compressed
# sync protocol and for the shell transport.
transfer_via_push_z() {
    TRANSFER_OUTPUT=""
    "$ADB" -s "$SERIAL" push -Z "$APK" "$REMOTE_APK" >"$TRANSFER_LOG" 2>&1 &
    TRANSFER_PID=$!
    transfer_watch
}

# The plain sync protocol. It is only worth its seconds for adb builds that do
# not know the -Z flag.
transfer_via_push_plain() {
    TRANSFER_OUTPUT=""
    "$ADB" -s "$SERIAL" push "$APK" "$REMOTE_APK" >"$TRANSFER_LOG" 2>&1 &
    TRANSFER_PID=$!
    transfer_watch
}

# adb builds that do not know the flag reject it by name.
push_z_unsupported() {
    grep -qE 'unrecognized option|unknown option|invalid option' <<<"$TRANSFER_OUTPUT"
}

# PUSH_METHOD=push: -Z first, the plain sync protocol only for an adb that
# does not know the flag.
transfer_via_push() {
    transfer_via_push_z && return 0
    push_z_unsupported || return 1
    transfer_via_push_plain || return 1
}

transfer_apk() {
    case "${PUSH_METHOD:-auto}" in
        shell)
            transfer_via_shell || return 1
            ;;
        push)
            transfer_via_push || return 1
            ;;
        auto)
            # The fast path first, then the shell transport, then the plain
            # sync protocol. An adb without -Z goes straight to the plain one:
            # for it the shell transport is the slow fallback, not the fast one.
            if ! transfer_via_push_z; then
                if push_z_unsupported; then
                    transfer_via_push_plain || transfer_via_shell || return 1
                else
                    echo >&2
                    echo "adb push -Z failed, falling back to the shell transport..." >&2
                    if ! transfer_via_shell; then
                        echo >&2
                        echo "The shell transport failed, falling back to adb push..." >&2
                        transfer_via_push_plain || return 1
                    fi
                fi
            fi
            ;;
        *)
            echo >&2
            echo "ERROR: PUSH_METHOD must be shell, push or auto" >&2
            return 1
            ;;
    esac

    # A truncated transfer is invisible without a check: the file on the device
    # can be shorter than the local one, and `pm install` then fails with a
    # message that says nothing about the transfer.
    local size
    size="$(remote_file_size "$REMOTE_APK")"
    if [[ "$size" != "$apk_bytes" ]]; then
        echo >&2
        echo "ERROR: the APK on the device is ${size:-0} bytes, expected $apk_bytes" >&2
        return 1
    fi
    return 0
}

run_install() {
    PM_OUTPUT=""
    local push_started=$SECONDS
    PHASE="push"
    # The transfer output is captured instead of streamed so a transport failure
    # is recognisable: adb says nothing at all when the link dies mid-command.
    if ! transfer_apk; then
        PM_OUTPUT="${TRANSFER_OUTPUT:-the APK did not reach the device}"
        return 1
    fi
    if [[ -n "$TRANSFER_OUTPUT" ]]; then
        echo "$TRANSFER_OUTPUT"
    fi
    echo "APK on the device: $apk_bytes bytes."
    local push_seconds=$((SECONDS - push_started))
    local install_started=$SECONDS
    # The device may hold this step open for a Play Protect verification dialog,
    # which only a human on the phone can answer, so say so before waiting.
    echo "Installing; answer the Play Protect prompt on the device if it appears."
    PHASE="pm install"
    PM_OUTPUT="$(timeout "$INSTALL_TIMEOUT_SECONDS" "$ADB" -s "$SERIAL" shell pm install -r "$REMOTE_APK" 2>&1)" || return 1
    local install_seconds=$((SECONDS - install_started))
    # A failed `pm install` is reported in its output, and its exit code is not a
    # reliable signal across versions, so the message decides.
    [[ "$PM_OUTPUT" == *Success* ]] || return 1
    echo "Transferred in ${push_seconds}s, installed by pm in ${install_seconds}s."
    return 0
}

is_transport_failure() {
    # No output at all means adb never got to answer: the link died, or the
    # command hit its timeout. Both deserve one retry.
    [[ -z "$1" ]] && return 0
    grep -qE 'device .*(not found|offline|unauthorized)|protocol fault|device still connecting|closed$|Connection reset|error: (device|closed)' <<<"$1"
}

report_failure() {
    if [[ -n "$PM_OUTPUT" ]]; then
        echo "$PM_OUTPUT" >&2
    else
        echo >&2
        echo "adb produced no output during '$PHASE': the link dropped, or the" >&2
        echo "command hit its timeout (${PUSH_TIMEOUT_SECONDS}s push / ${INSTALL_TIMEOUT_SECONDS}s install)." >&2
    fi
}

started=$SECONDS
if ! run_install; then
    report_failure
    # The transport can drop between the host and the device; one retry after
    # waiting for it is enough in practice and keeps the failure loud.
    is_transport_failure "$PM_OUTPUT" ||
        die "install failed during: $PHASE"
    echo >&2
    echo "Transport error during $PHASE, waiting for $SERIAL and retrying once..." >&2
    wait_for_device
    run_install || {
        report_failure
        die "install failed on the retry, during: $PHASE"
    }
fi

echo "Done in $((SECONDS - started))s."

if [[ -n "$APPLICATION_ID" ]]; then
    echo
    package_state="$("$ADB" -s "$SERIAL" shell dumpsys package "$APPLICATION_ID" 2>/dev/null |
        grep -E 'versionCode=|versionName=|lastUpdateTime=|primaryCpuAbi=' |
        sed 's/^ *//' || true)"
    if [[ -n "$package_state" ]]; then
        echo "Package state for $APPLICATION_ID:"
        sed 's/^/  /' <<<"$package_state"
    else
        # The install already succeeded, so an unreadable dumpsys must not turn a
        # good run into a failure.
        echo "Installed; dumpsys gave no state for $APPLICATION_ID."
    fi
fi