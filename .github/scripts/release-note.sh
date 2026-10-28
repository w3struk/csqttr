#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Технический блок описания GitHub-релиза: версия, коммит, длительность
# сборки, wire-ревизия, состав ассетов и отпечаток подписи.
#
# Версия и versionCode читаются из app/build.gradle.kts теми же регексами, что
# и в scripts/build_apk.sh (apk_version()); wire-ревизия — из rust-server/main.rs
# тем же регексом, что и в scripts/server_asset_provenance.sh.
#
# Usage:
#   release-note.sh --root DIR --tag T --commit SHA --duration-seconds N
#                   [--fingerprint HEX] [--signer CN] [--wire-revision R]
#                   --out FILE

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: release-note.sh --root DIR --tag T --commit SHA --duration-seconds N
                      [--fingerprint HEX] [--signer CN] [--wire-revision R]
                      --out FILE

Writes the technical block of the release description to --out and prints it
to stdout.

Required:
  --root DIR             repository root (reads app/build.gradle.kts and
                         rust-server/main.rs from it)
  --tag T                release tag, e.g. v2.5.1
  --commit SHA           full commit sha of the tag
  --duration-seconds N   build duration in seconds
  --out FILE             file to write the note to

Optional:
  --fingerprint HEX      signing certificate SHA-256 (with --signer)
  --signer CN            signing certificate CN (with --fingerprint)
  --wire-revision R      wire protocol revision; read from rust-server/main.rs
                         when omitted

The "Подпись:" line is printed only when both --signer and --fingerprint are
given. The last line of the file is always <!-- CSQTT-TECH-NOTES-END -->.
EOF
}

die() {
    printf 'release note: %s\n' "$1" >&2
    exit 1
}

root=""
tag=""
commit=""
duration=""
fingerprint=""
signer=""
wire_revision=""
out=""

while (($#)); do
    case "$1" in
        --root)
            root="${2:?--root requires a value}"
            shift 2
            ;;
        --root=*)
            root="${1#--root=}"
            shift
            ;;
        --tag)
            tag="${2:?--tag requires a value}"
            shift 2
            ;;
        --tag=*)
            tag="${1#--tag=}"
            shift
            ;;
        --commit)
            commit="${2:?--commit requires a value}"
            shift 2
            ;;
        --commit=*)
            commit="${1#--commit=}"
            shift
            ;;
        --duration-seconds)
            duration="${2:?--duration-seconds requires a value}"
            shift 2
            ;;
        --duration-seconds=*)
            duration="${1#--duration-seconds=}"
            shift
            ;;
        --fingerprint)
            fingerprint="${2:?--fingerprint requires a value}"
            shift 2
            ;;
        --fingerprint=*)
            fingerprint="${1#--fingerprint=}"
            shift
            ;;
        --signer)
            signer="${2:?--signer requires a value}"
            shift 2
            ;;
        --signer=*)
            signer="${1#--signer=}"
            shift
            ;;
        --wire-revision)
            wire_revision="${2:?--wire-revision requires a value}"
            shift 2
            ;;
        --wire-revision=*)
            wire_revision="${1#--wire-revision=}"
            shift
            ;;
        --out)
            out="${2:?--out requires a value}"
            shift 2
            ;;
        --out=*)
            out="${1#--out=}"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
done

require_value() {
    local flag="$1" value="$2"
    [[ -n "$value" ]] || {
        printf 'release note: %s is required\n' "$flag" >&2
        usage >&2
        exit 1
    }
}

require_value --root "$root"
require_value --tag "$tag"
require_value --commit "$commit"
require_value --duration-seconds "$duration"
require_value --out "$out"

[[ "$duration" =~ ^[0-9]+$ ]] ||
    die "duration must be a non-negative number of seconds, got '$duration'"

gradle_file="$root/app/build.gradle.kts"
[[ -f "$gradle_file" ]] || die "cannot read the app version, file not found: $gradle_file"
version="$(
    sed -n 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$gradle_file" | sed -n '1p'
)"
version_code="$(
    sed -n 's/^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' \
        "$gradle_file" | sed -n '1p'
)"
[[ -n "$version" ]] || die "could not read versionName from $gradle_file"
[[ -n "$version_code" ]] || die "could not read versionCode from $gradle_file"

if [[ -z "$wire_revision" ]]; then
    wire_source="$root/rust-server/main.rs"
    [[ -f "$wire_source" ]] ||
        die "cannot read WIRE_PROTOCOL_REVISION, file not found: $wire_source"
    wire_revision="$(
        sed -n 's/.*WIRE_PROTOCOL_REVISION[[:space:]]*:[[:space:]]*&str[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$wire_source" | sed -n '1p'
    )"
    [[ -n "$wire_revision" ]] ||
        die "could not read WIRE_PROTOCOL_REVISION from $wire_source"
fi

short_commit="${commit:0:7}"
build_duration="$(printf '%dm %ds' "$((duration / 60))" "$((duration % 60))")"

out_dir="$(dirname -- "$out")"
[[ -d "$out_dir" ]] || die "cannot write the note, directory not found: $out_dir"

note="$(
    {
        printf '## CSQTT %s\n\n' "$version"
        printf 'Тег: %s\n' "$tag"
        printf 'Версия: %s (versionCode %s)\n' "$version" "$version_code"
        printf 'Коммит: %s (%s)\n' "$commit" "$short_commit"
        printf 'Длительность сборки: %s\n' "$build_duration"
        printf 'Wire-ревизия: %s\n\n' "$wire_revision"

        printf 'Приложение:\n'
        printf '%s\n' \
            "- CSQTT-$version-universal.apk" \
            "- CSQTT-$version-arm64-v8a.apk" \
            "- CSQTT-$version-armeabi-v7a.apk"

        printf '\nСервер:\n'
        printf '%s\n' \
            '- csqtt-linux-amd64' \
            '- csqtt-linux-arm64' \
            '- csqtt-linux-armv7'

        printf '\nКонтрольные суммы: SHA256SUMS\n\n'
        # GitHub не хранит режим файла в ассетах: без chmod бинари не запустятся.
        printf 'Права после скачивания: chmod +x csqtt-linux-*\n\n'
        if [[ -n "$signer" && -n "$fingerprint" ]]; then
            printf 'Подпись: CN=%s, SHA-256 %s\n' "$signer" "$fingerprint"
        fi
        printf '<!-- CSQTT-TECH-NOTES-END -->\n'
    }
)"

printf '%s\n' "$note" >"$out" || die "cannot write the note to $out"
printf '%s\n' "$note"
