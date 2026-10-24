#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# Writes or verifies the provenance manifest of the server binaries shipped in the
# APK. Both the binaries and the manifest live under app/build/generated/.
# Usage: server_asset_provenance.sh <write|verify> [--root DIR] [--assets a,b,c]
#                                         [--assets-dir DIR] [--manifest FILE]

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=""
ALL_ASSETS=(csqtt-linux-amd64 csqtt-linux-arm64 csqtt-linux-armv7)
ASSETS=("${ALL_ASSETS[@]}")
ASSET_DIR=""
MANIFEST=""
FEATURES=()
ALLOWED_FEATURES=()

SCHEMA="csqtt.server-asset-provenance.v4"
MARKER="CSQTT_RUST_SERVER_PRODUCTION_V1"
PRODUCER="rust-server/build_linux.sh"

usage() {
    printf 'Usage: %s <write|verify> [--root DIR] [--assets %s]\n' "$(basename "$0")" "${ALL_ASSETS[*]}" >&2
    printf '       [--assets-dir DIR] [--manifest FILE] [--features a,b]\n' >&2
    printf '       [--allow-feature NAME]...\n' >&2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while (($#)); do
    case "$1" in
        write | verify) MODE="$1" ;;
        --root)
            (($# >= 2)) || die "--root requires a value"
            ROOT="$2"
            shift
            ;;
        --assets)
            (($# >= 2)) || die "--assets requires a value"
            IFS=',' read -r -a ASSETS <<<"$2"
            shift
            ;;
        --assets=*)
            IFS=',' read -r -a ASSETS <<<"${1#--assets=}"
            ;;
        --assets-dir)
            (($# >= 2)) || die "--assets-dir requires a value"
            ASSET_DIR="$2"
            shift
            ;;
        --assets-dir=*) ASSET_DIR="${1#--assets-dir=}" ;;
        --features)
            (($# >= 2)) || die "--features requires a value"
            IFS=',' read -r -a FEATURES <<<"$2"
            shift
            ;;
        --features=*)
            IFS=',' read -r -a FEATURES <<<"${1#--features=}"
            ;;
        --allow-feature)
            (($# >= 2)) || die "--allow-feature requires a value"
            ALLOWED_FEATURES+=("$2")
            shift
            ;;
        --allow-feature=*) ALLOWED_FEATURES+=("${1#--allow-feature=}") ;;
        --manifest)
            (($# >= 2)) || die "--manifest requires a value"
            MANIFEST="$2"
            shift
            ;;
        --manifest=*) MANIFEST="${1#--manifest=}" ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

[[ -n "$MODE" ]] || {
    usage
    exit 2
}
ROOT="$(cd -- "$ROOT" && pwd)"

GENERATED_ROOT="$ROOT/app/build/generated"
[[ -n "$ASSET_DIR" ]] || ASSET_DIR="$GENERATED_ROOT/assets"
[[ -n "$MANIFEST" ]] || MANIFEST="$GENERATED_ROOT/provenance/csqtt-server.json"
CARGO_TOML="$ROOT/rust-server/Cargo.toml"
CARGO_LOCK="$ROOT/rust-server/Cargo.lock"
WIRE_REVISION_SOURCE="$ROOT/rust-server/main.rs"

valid_asset() {
    case "$1" in
        csqtt-linux-amd64 | csqtt-linux-arm64 | csqtt-linux-armv7) return 0 ;;
        *) return 1 ;;
    esac
}

asset_target() {
    case "$1" in
        csqtt-linux-amd64) printf 'x86_64-unknown-linux-musl\n' ;;
        csqtt-linux-arm64) printf 'aarch64-unknown-linux-musl\n' ;;
        csqtt-linux-armv7) printf 'armv7-unknown-linux-musleabihf\n' ;;
    esac
}

asset_elf_class() {
    case "$1" in
        csqtt-linux-armv7) printf '1\n' ;;
        *) printf '2\n' ;;
    esac
}

asset_elf_machine() {
    case "$1" in
        csqtt-linux-amd64) printf '62\n' ;;
        csqtt-linux-arm64) printf '183\n' ;;
        csqtt-linux-armv7) printf '40\n' ;;
    esac
}

asset_path() {
    printf '%s/%s\n' "$ASSET_DIR" "$1"
}

cargo_path() {
    printf '%s/build/csqtt-uring-linux-%s/%s/release/csqtt\n' "$ROOT" "$1" "$(asset_target "$1")"
}

sha256_file() {
    sha256sum "$1" | awk '{print toupper($1)}'
}

require_file() {
    [[ -f "$1" ]] || die "$2 not found: $1"
    [[ -s "$1" ]] || die "$2 is empty: $1"
}

cargo_package_field() {
    local key="$1"
    require_file "$CARGO_TOML" "Server Cargo.toml"
    awk -v key="$key" '
        /^\[package\][[:space:]]*$/ { inside = 1; next }
        inside && /^\[/ { exit }
        inside && $1 == key {
            line = $0
            sub(/^[^=]*=[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            print line
            exit
        }
    ' "$CARGO_TOML"
}

wire_protocol_revision() {
    local revision
    require_file "$WIRE_REVISION_SOURCE" "Wire protocol revision source"
    revision="$(sed -n 's/.*WIRE_PROTOCOL_REVISION[[:space:]]*:[[:space:]]*&str[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WIRE_REVISION_SOURCE" | sed -n '1p')"
    [[ -n "$revision" ]] || die "Wire protocol revision is missing"
    printf '%s\n' "$revision"
}

build_input_files() {
    local prefix
    printf '%s\n' \
        rust-server/build_linux.sh \
        rust-server/build_linux_variants.sh \
        rust-server/Cargo.toml \
        rust-server/Cargo.lock \
        rust-server/rust-toolchain.toml \
        app/src/main/assets/domains.txt \
        scripts/server_asset_provenance.sh

    find "$ROOT/rust-server" -maxdepth 1 -type f -name '*.rs' -printf 'rust-server/%P\n'
    find "$ROOT/shared" -maxdepth 1 -type f -name '*.rs' -printf 'shared/%P\n'

    # Cargo config files, same reasoning as on the client side: they set the build
    # target and the rustflags, and only existing files may be listed.
    for prefix in ".cargo" "rust-server/.cargo"; do
        [[ -d "$ROOT/$prefix" ]] || continue
        ( cd "$ROOT/$prefix" && find . -type f -printf "$prefix/%P\n" )
    done
}

canonical_build_input_hash() {
    local list tmp rel
    list="$(mktemp)"
    tmp="$(mktemp)"
    trap "rm -f '$list' '$tmp'" EXIT
    build_input_files | LC_ALL=C sort -u >"$list"
    [[ -s "$list" ]] || die "server build input list is empty"

    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        require_file "$ROOT/$rel" "Server build input"
        printf '%s:%s\n' "$rel" "$(sha256_file "$ROOT/$rel")"
    done <"$list" >"$tmp"

    sha256_file "$tmp"
    rm -f "$list" "$tmp"
    trap - EXIT
}

read_elf_bytes() {
    ELF_BYTES=()
    mapfile -t ELF_BYTES < <(od -An -v -tu1 -N20 "$1" | tr -s '[:space:]' '\n' | sed '/^$/d')
    ((${#ELF_BYTES[@]} >= 20)) || die "Invalid ELF header: $1"
}

assert_server_binary() {
    local asset="$1" revision="$2"
    local path class machine

    path="$(asset_path "$asset")"
    class="$(asset_elf_class "$asset")"
    machine="$(asset_elf_machine "$asset")"

    require_file "$path" "Linux server asset $asset"
    read_elf_bytes "$path"
    [[ "${ELF_BYTES[0]}" -eq 127 && "${ELF_BYTES[1]}" -eq 69 && "${ELF_BYTES[2]}" -eq 76 && "${ELF_BYTES[3]}" -eq 70 ]] ||
        die "Linux server asset $asset is not ELF"
    [[ "${ELF_BYTES[4]}" -eq "$class" && "${ELF_BYTES[5]}" -eq 1 ]] ||
        die "ELF class or endianness mismatch for $asset"

    local actual_machine=$((ELF_BYTES[18] + ELF_BYTES[19] * 256))
    [[ "$actual_machine" -eq "$machine" ]] ||
        die "ELF machine mismatch for $asset: expected $machine, got $actual_machine"
    grep -a -q -F -e "$revision" -- "$path" ||
        die "Linux server asset $asset does not expose wire protocol revision $revision"
}

artifact_size() {
    stat -c '%s' "$1"
}

write_manifest() {
    local package_name package_version revision build_input_hash artifacts entry asset size sha target class machine tmp
    require_file "$CARGO_LOCK" "Server Cargo.lock"

    package_name="$(cargo_package_field name)"
    package_version="$(cargo_package_field version)"
    [[ -n "$package_name" && -n "$package_version" ]] || die "Unable to read Rust server package identity"
    revision="$(wire_protocol_revision)"
    build_input_hash="$(canonical_build_input_hash)"

    artifacts='[]'
    for asset in "${ASSETS[@]}"; do
        assert_server_binary "$asset" "$revision"
        size="$(artifact_size "$(asset_path "$asset")")"
        sha="$(sha256_file "$(asset_path "$asset")")"
        target="$(asset_target "$asset")"
        class="$(asset_elf_class "$asset")"
        machine="$(asset_elf_machine "$asset")"
        artifacts="$(jq -c \
            --arg assetName "$asset" \
            --arg target "$target" \
            --argjson elfClass "$class" \
            --argjson elfMachine "$machine" \
            --argjson binarySize "$size" \
            --arg binarySha256 "$sha" \
            '. + [{assetName: $assetName, target: $target, elfClass: $elfClass, elfMachine: $elfMachine, binarySize: $binarySize, binarySha256: $binarySha256}]' <<<"$artifacts")"
    done

    mkdir -p "$(dirname "$MANIFEST")"
    tmp="$MANIFEST.tmp.$$"
    jq -n \
        --arg schema "$SCHEMA" \
        --arg marker "$MARKER" \
        --arg producer "$PRODUCER" \
        --arg package "$package_name" \
        --arg version "$package_version" \
        --arg wireProtocolRevision "$revision" \
        --arg buildInputSha256 "$build_input_hash" \
        --arg cargoTomlSha256 "$(sha256_file "$CARGO_TOML")" \
        --arg cargoLockSha256 "$(sha256_file "$CARGO_LOCK")" \
        --arg generatedAtUtc "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
        --argjson artifacts "$artifacts" \
        --argjson features "$(printf '%s\n' "${FEATURES[@]:-}" | sed '/^$/d' | jq -R . | jq -s .)" \
        '{
            schema: $schema,
            marker: $marker,
            producer: $producer,
            runtime: "rust",
            package: $package,
            version: $version,
            wireProtocolRevision: $wireProtocolRevision,
            buildInputSha256: $buildInputSha256,
            features: $features,
            cargoTomlSha256: $cargoTomlSha256,
            cargoLockSha256: $cargoLockSha256,
            artifacts: $artifacts,
            generatedAtUtc: $generatedAtUtc
        }' >"$tmp"
    mv "$tmp" "$MANIFEST"
    printf 'Wrote Rust server provenance: %s\n' "$MANIFEST"
}

verify_manifest() {
    local package_name package_version revision build_input_hash count expected_count entry asset
    local m_target m_class m_machine m_size m_sha

    require_file "$MANIFEST" "Rust server provenance"

    jq -e \
        --arg schema "$SCHEMA" \
        --arg marker "$MARKER" \
        --arg producer "$PRODUCER" \
        '(.schema == $schema) and
         (.marker == $marker) and
         (.producer == $producer) and
         (.runtime == "rust") and
         ((.features | type) == "array")' "$MANIFEST" >/dev/null ||
        die "Rust server provenance identity mismatch"

    # A diagnostics build is a different animal: it sniffs DPI on the wire. It must
    # never pass as a production payload unless the caller opted in explicitly.
    while IFS= read -r recorded; do
        [[ -n "$recorded" ]] || continue
        local allowed=false
        for candidate in ${ALLOWED_FEATURES[@]+"${ALLOWED_FEATURES[@]}"}; do
            [[ "$candidate" == "$recorded" ]] && {
                allowed=true
                break
            }
        done
        [[ "$allowed" == "true" ]] ||
            die "Rust server binary was built with the '$recorded' cargo feature. Re-build without it, or pass --allow-feature=$recorded to accept it deliberately."
    done < <(jq -r '.features[]?' "$MANIFEST")

    package_name="$(cargo_package_field name)"
    package_version="$(cargo_package_field version)"
    revision="$(wire_protocol_revision)"

    [[ "$(jq -r '.package' "$MANIFEST")" == "$package_name" ]] || die "Rust server package name does not match provenance"
    [[ "$(jq -r '.version' "$MANIFEST")" == "$package_version" ]] || die "Rust server version does not match provenance"
    [[ "$(jq -r '.wireProtocolRevision' "$MANIFEST")" == "$revision" ]] ||
        die "Rust server wire protocol revision does not match provenance"

    [[ "$(jq -r '.cargoTomlSha256' "$MANIFEST")" == "$(sha256_file "$CARGO_TOML")" ]] ||
        die "Cargo.toml changed after the production server build"
    [[ "$(jq -r '.cargoLockSha256' "$MANIFEST")" == "$(sha256_file "$CARGO_LOCK")" ]] ||
        die "Cargo.lock changed after the production server build"

    build_input_hash="$(canonical_build_input_hash)"
    [[ "$(jq -r '.buildInputSha256' "$MANIFEST")" == "$build_input_hash" ]] ||
        die "Rust server source changed after the production server build"

    count="$(jq -r '.artifacts | length' "$MANIFEST")"
    expected_count="${#ASSETS[@]}"
    [[ "$count" -eq "$expected_count" ]] ||
        die "Rust server provenance artifact count mismatch"

    for asset in "${ASSETS[@]}"; do
        entry="$(jq -r --arg asset "$asset" '
            [.artifacts[] | select(.assetName == $asset)] as $matches |
            if ($matches | length) != 1 then
                error("Rust server provenance is missing " + $asset)
            else
                $matches[0] | [.target, (.elfClass | tostring), (.elfMachine | tostring), (.binarySize | tostring), (.binarySha256 | ascii_upcase)] | @tsv
            end' "$MANIFEST")"
        IFS=$'\t' read -r m_target m_class m_machine m_size m_sha <<<"$entry"

        assert_server_binary "$asset" "$revision"

        [[ "$m_target" == "$(asset_target "$asset")" ]] || die "Rust server provenance target mismatch for $asset"
        [[ "$m_class" == "$(asset_elf_class "$asset")" ]] || die "Rust server provenance ELF class mismatch for $asset"
        [[ "$m_machine" == "$(asset_elf_machine "$asset")" ]] || die "Rust server provenance ELF machine mismatch for $asset"
        [[ "$m_size" == "$(artifact_size "$(asset_path "$asset")")" ]] || die "Rust server provenance size mismatch for $asset"
        [[ "$m_sha" == "$(sha256_file "$(asset_path "$asset")")" ]] || die "Rust server asset does not match provenance: $asset"
    done

    printf 'Rust server provenance verified: %s\n' "$MARKER"
}

for tool in jq sha256sum stat od mktemp; do
    require_cmd "$tool"
done

for asset in "${ASSETS[@]}"; do
    valid_asset "$asset" || die "unsupported server asset: $asset"
done

if [[ "$MODE" == "write" ]]; then
    write_manifest
else
    verify_manifest
fi
