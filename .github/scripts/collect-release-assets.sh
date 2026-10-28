#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Собирает ассеты релиза: три APK из Gradle, три серверных бинаря и
# SHA256SUMS. Имена входов жёсткие — никаких глобов «по совпадению имени».
#
# Usage:
#   collect-release-assets.sh --root DIR [--apk-dir DIR] [--assets-dir DIR]
#                             --out DIR [--list-file FILE] [--version V]

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: collect-release-assets.sh --root DIR [--apk-dir DIR] [--assets-dir DIR]
                                 --out DIR [--list-file FILE] [--version V]

Copies the three release APKs and the three server binaries into --out,
renames the APKs to CSQTT-<version>-<abi>.apk and writes SHA256SUMS.
Prints the seven absolute paths (SHA256SUMS last) to stdout and to the
list file.
EOF
}

die() {
    printf 'release assets: %s\n' "$1" >&2
    exit 1
}

root="$PWD"
apk_dir=""
assets_dir=""
out=""
list_file=""
version=""

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
        --apk-dir)
            apk_dir="${2:?--apk-dir requires a value}"
            shift 2
            ;;
        --apk-dir=*)
            apk_dir="${1#--apk-dir=}"
            shift
            ;;
        --assets-dir)
            assets_dir="${2:?--assets-dir requires a value}"
            shift 2
            ;;
        --assets-dir=*)
            assets_dir="${1#--assets-dir=}"
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
        --list-file)
            list_file="${2:?--list-file requires a value}"
            shift 2
            ;;
        --list-file=*)
            list_file="${1#--list-file=}"
            shift
            ;;
        --version)
            version="${2:?--version requires a value}"
            shift 2
            ;;
        --version=*)
            version="${1#--version=}"
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

[[ -n "$out" ]] || {
    usage >&2
    exit 1
}

if [[ -z "$apk_dir" ]]; then
    apk_dir="$root/app/build/outputs/apk/release"
fi
if [[ -z "$assets_dir" ]]; then
    assets_dir="$root/app/build/generated/assets"
fi

if [[ -z "$version" ]]; then
    gradle_file="$root/app/build.gradle.kts"
    [[ -f "$gradle_file" ]] || die "cannot read versionName, file not found: $gradle_file"
    version="$(
        sed -n 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$gradle_file" | head -n 1
    )"
fi
[[ -n "$version" ]] || die "could not read versionName from $root/app/build.gradle.kts"

mkdir -p "$out" || die "cannot create output directory: $out"
out="$(cd -- "$out" && pwd)"

if [[ -z "$list_file" ]]; then
    list_file="$out/asset-paths.txt"
fi

abis=(universal arm64-v8a armeabi-v7a)
server_binaries=(csqtt-linux-amd64 csqtt-linux-arm64 csqtt-linux-armv7)

require_input() {
    local path="$1"
    [[ -f "$path" ]] || die "missing release input: $path"
    [[ -s "$path" ]] || die "empty release input: $path"
}

copied=()
for abi in "${abis[@]}"; do
    src="$apk_dir/app-$version-$abi-release.apk"
    require_input "$src"
    dst="$out/CSQTT-$version-$abi.apk"
    cp -f "$src" "$dst" || die "cannot copy $src"
    copied+=("$dst")
done

for binary in "${server_binaries[@]}"; do
    src="$assets_dir/$binary"
    require_input "$src"
    dst="$out/$binary"
    cp -f "$src" "$dst" || die "cannot copy $src"
    copied+=("$dst")
done

(
    cd -- "$out" || exit 1
    sha256sum \
        "csqtt-linux-amd64" \
        "csqtt-linux-arm64" \
        "csqtt-linux-armv7" \
        "CSQTT-$version-universal.apk" \
        "CSQTT-$version-arm64-v8a.apk" \
        "CSQTT-$version-armeabi-v7a.apk" >SHA256SUMS
) || die "cannot compute SHA256SUMS in $out"

for path in "${copied[@]}"; do
    printf '[OK] %-40s [%s bytes]\n' "$(basename -- "$path")" "$(stat -c '%s' "$path")"
done

paths=("${copied[@]}" "$out/SHA256SUMS")
printf '%s\n' "${paths[@]}"
printf '%s\n' "${paths[@]}" >"$list_file"
