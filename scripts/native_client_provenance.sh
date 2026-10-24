#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# Writes or verifies the provenance manifest of one Android build variant.
# Artifacts live under app/build/generated/, manifests next to them, so nothing
# generated ever lands in the source tree.
# Usage: native_client_provenance.sh <write|verify> [--root DIR] [--abis a,b,c]
#                                      [--variant debug|release]
#                                      [--jni-libs-dir DIR] [--manifest FILE]

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=""
ALL_ABIS=(arm64-v8a armeabi-v7a x86_64)
ABIS=("${ALL_ABIS[@]}")
VARIANT="release"
JNILIBS_DIR=""
MANIFEST=""

SCHEMA="csqtt.native-client-provenance.v6"
MARKER="CSQTT_RUST_NATIVE_PRODUCTION_V1"
PRODUCER="rust-client/build_so.sh"
TRANSPORT="rust-turn-sans-io-rfc8656-channeldata"
TRANSPORT_MARKER="CSQTT_RUST_TURN_SANS_IO_V1"
NATIVE_CORE_ABI=1

usage() {
    printf 'Usage: %s <write|verify> [--root DIR] [--abis %s] [--variant debug|release]\n' \
        "$(basename "$0")" "${ALL_ABIS[*]}" >&2
    printf '       [--jni-libs-dir DIR] [--manifest FILE]\n' >&2
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
        --abis)
            (($# >= 2)) || die "--abis requires a value"
            IFS=',' read -r -a ABIS <<<"$2"
            shift
            ;;
        --abis=*)
            IFS=',' read -r -a ABIS <<<"${1#--abis=}"
            ;;
        --variant)
            (($# >= 2)) || die "--variant requires a value"
            VARIANT="$2"
            shift
            ;;
        --variant=*) VARIANT="${1#--variant=}" ;;
        --jni-libs-dir)
            (($# >= 2)) || die "--jni-libs-dir requires a value"
            JNILIBS_DIR="$2"
            shift
            ;;
        --jni-libs-dir=*) JNILIBS_DIR="${1#--jni-libs-dir=}" ;;
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

valid_variant() {
    case "$1" in
        debug | release) return 0 ;;
        *) return 1 ;;
    esac
}

valid_variant "$VARIANT" || die "unsupported variant: $VARIANT (expected debug or release)"

case "$VARIANT" in
    debug) CARGO_PROFILE="android-debug"; PROFILE_DIR="android-debug" ;;
    *) CARGO_PROFILE="release"; PROFILE_DIR="release" ;;
esac

# Android build variant "debug" maps to the Cargo "android-debug" profile, which
# inherits "dev" (opt-level = 1) and strips the DWARF sections - full debuginfo
# makes this binary ~200 MB per ABI. See rust-client/Cargo.toml.
GENERATED_ROOT="$ROOT/app/build/generated"
[[ -n "$JNILIBS_DIR" ]] || JNILIBS_DIR="$GENERATED_ROOT/jniLibs/$VARIANT"
[[ -n "$MANIFEST" ]] || MANIFEST="$GENERATED_ROOT/provenance/libclient.$VARIANT.json"
CARGO_TOML="$ROOT/rust-client/Cargo.toml"
CARGO_LOCK="$ROOT/rust-client/Cargo.lock"

valid_abi() {
    case "$1" in
        arm64-v8a | armeabi-v7a | x86_64) return 0 ;;
        *) return 1 ;;
    esac
}

abi_target() {
    case "$1" in
        arm64-v8a) printf 'aarch64-linux-android\n' ;;
        armeabi-v7a) printf 'armv7-linux-androideabi\n' ;;
        x86_64) printf 'x86_64-linux-android\n' ;;
    esac
}

abi_elf_class() {
    case "$1" in
        armeabi-v7a) printf '1\n' ;;
        *) printf '2\n' ;;
    esac
}

abi_elf_machine() {
    case "$1" in
        arm64-v8a) printf '183\n' ;;
        armeabi-v7a) printf '40\n' ;;
        x86_64) printf '62\n' ;;
    esac
}

abi_target_dir() {
    # Separate cargo target directory per Android variant: switching build types
    # must not throw away the dependency artifacts of the other profile.
    case "$1" in
        arm64-v8a) printf 'rust-client-android-%s-arm64\n' "$VARIANT" ;;
        armeabi-v7a) printf 'rust-client-android-%s-armv7\n' "$VARIANT" ;;
        x86_64) printf 'rust-client-android-%s-x86_64\n' "$VARIANT" ;;
    esac
}

production_path() {
    printf '%s/%s/libclient.so\n' "$JNILIBS_DIR" "$1"
}

cargo_path() {
    printf '%s/build/%s/%s/%s/client\n' "$ROOT" "$(abi_target_dir "$1")" "$(abi_target "$1")" "$PROFILE_DIR"
}

sha256_file() {
    sha256sum "$1" | awk '{print toupper($1)}'
}

sha256_stdin() {
    sha256sum | awk '{print toupper($1)}'
}

require_file() {
    [[ -f "$1" ]] || die "$2 not found: $1"
    [[ -s "$1" ]] || die "$2 is empty: $1"
}

require_dir() {
    [[ -d "$1" ]] || die "$2 not found: $1"
}

cargo_package_field() {
    local key="$1"
    require_file "$CARGO_TOML" "Cargo.toml"
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

build_input_files() {
    local prefix
    printf '%s\n' \
        rust-client/build_so.sh \
        rust-client/build_android_abis.sh \
        rust-client/Cargo.toml \
        rust-client/Cargo.lock \
        rust-client/rust-toolchain.toml \
        domains.txt \
        scripts/android_env.sh \
        scripts/native_client_provenance.sh

    # Cargo config files: they pick the target and the rustflags, so they change
    # the binary. Listed only when present, because every entry below is required
    # to exist by canonical_build_input_hash.
    for prefix in ".cargo" "rust-client/.cargo"; do
        [[ -d "$ROOT/$prefix" ]] || continue
        ( cd "$ROOT/$prefix" && find . -type f -printf "$prefix/%P\n" )
    done

    require_dir "$ROOT/rust-client/vendor/primp" "Vendored primp sources"
    (
        cd "$ROOT/rust-client/vendor/primp"
        find . -type f -printf 'rust-client/vendor/primp/%P\n'
    )

    require_dir "$ROOT/rust-client/vendor/netstack-smoltcp" "Vendored netstack-smoltcp sources"
    (
        cd "$ROOT/rust-client/vendor/netstack-smoltcp"
        find . -type f -printf 'rust-client/vendor/netstack-smoltcp/%P\n'
    )
}

canonical_build_input_hash() {
    local list tmp rel
    list="$(mktemp)"
    tmp="$(mktemp)"
    trap "rm -f '$list' '$tmp'" EXIT
    build_input_files | LC_ALL=C sort -u >"$list"
    [[ -s "$list" ]] || die "native build input list is empty"

    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        require_file "$ROOT/$rel" "Native build input"
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

assert_elf() {
    local path="$1" expected_class="$2" expected_machine="$3" label="$4"
    local etype machine

    read_elf_bytes "$path"
    [[ "${ELF_BYTES[0]}" -eq 127 && "${ELF_BYTES[1]}" -eq 69 && "${ELF_BYTES[2]}" -eq 76 && "${ELF_BYTES[3]}" -eq 70 ]] ||
        die "Production artifact is not ELF for $label: $path"
    [[ "${ELF_BYTES[4]}" -eq "$expected_class" && "${ELF_BYTES[5]}" -eq 1 ]] ||
        die "ELF class or endianness mismatch for $label: $path"

    etype=$((ELF_BYTES[16] + ELF_BYTES[17] * 256))
    machine=$((ELF_BYTES[18] + ELF_BYTES[19] * 256))
    [[ "$etype" -eq 3 ]] || die "Production artifact is not an Android PIE/ET_DYN for $label: $path"
    [[ "$machine" -eq "$expected_machine" ]] ||
        die "ELF machine mismatch for $label: expected $expected_machine, got $machine"
}

assert_artifact() {
    local abi="$1" require_cargo_match="$2"
    local prod cargo class machine

    prod="$(production_path "$abi")"
    cargo="$(cargo_path "$abi")"
    class="$(abi_elf_class "$abi")"
    machine="$(abi_elf_machine "$abi")"

    require_file "$prod" "$abi production artifact"
    assert_elf "$prod" "$class" "$machine" "$abi"

    if grep -a -q -F -e 'Go buildinf:' -- "$prod"; then
        die "Go build metadata detected in production artifact for $abi"
    fi
    if ! grep -a -q -F -e "$TRANSPORT_MARKER" -- "$prod"; then
        die "Rust TURN transport identity is missing for $abi"
    fi

    if [[ "$require_cargo_match" == "true" ]]; then
        require_file "$cargo" "$abi Cargo artifact"
        [[ "$(sha256_file "$prod")" == "$(sha256_file "$cargo")" ]] ||
            die "Production artifact does not match the Cargo output for $abi"
    fi
}

artifact_size() {
    stat -c '%s' "$1"
}

write_manifest() {
    local package_name package_version build_input_hash artifacts entry abi prod size sha target tmp
    require_file "$CARGO_LOCK" "Cargo.lock"

    package_name="$(cargo_package_field name)"
    package_version="$(cargo_package_field version)"
    [[ -n "$package_name" && -n "$package_version" ]] || die "Unable to read Rust package identity from $CARGO_TOML"
    build_input_hash="$(canonical_build_input_hash)"

    artifacts='[]'
    for abi in "${ABIS[@]}"; do
        assert_artifact "$abi" true
        prod="$(production_path "$abi")"
        size="$(artifact_size "$prod")"
        sha="$(sha256_file "$prod")"
        target="$(abi_target "$abi")"
        artifacts="$(jq -c \
            --arg abi "$abi" \
            --arg target "$target" \
            --argjson size "$size" \
            --arg sha256 "$sha" \
            '. + [{abi: $abi, target: $target, size: $size, sha256: $sha256}]' <<<"$artifacts")"
    done

    mkdir -p "$(dirname "$MANIFEST")"
    tmp="$MANIFEST.tmp.$$"
    jq -n \
        --arg schema "$SCHEMA" \
        --arg marker "$MARKER" \
        --arg producer "$PRODUCER" \
        --arg transport "$TRANSPORT" \
        --arg transportMarker "$TRANSPORT_MARKER" \
        --argjson nativeCoreAbi "$NATIVE_CORE_ABI" \
        --arg package "$package_name" \
        --arg version "$package_version" \
        --arg buildInputSha256 "$build_input_hash" \
        --arg cargoTomlSha256 "$(sha256_file "$CARGO_TOML")" \
        --arg cargoLockSha256 "$(sha256_file "$CARGO_LOCK")" \
        --arg generatedAtUtc "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
        --argjson artifacts "$artifacts" \
        --arg variant "$VARIANT" \
        --arg cargoProfile "$CARGO_PROFILE" \
        '{
            schema: $schema,
            marker: $marker,
            producer: $producer,
            runtime: "rust",
            buildSystem: "cargo-ndk",
            variant: $variant,
            profile: $cargoProfile,
            transport: $transport,
            transportMarker: $transportMarker,
            nativeCoreAbi: $nativeCoreAbi,
            package: $package,
            version: $version,
            buildInputSha256: $buildInputSha256,
            cargoTomlSha256: $cargoTomlSha256,
            cargoLockSha256: $cargoLockSha256,
            generatedAtUtc: $generatedAtUtc,
            artifacts: $artifacts
        }' >"$tmp"
    mv "$tmp" "$MANIFEST"
    printf 'Wrote Rust native provenance: %s\n' "$MANIFEST"
}

verify_manifest() {
    local package_name package_version build_input_hash entry abi
    local m_target m_size m_sha prod

    require_file "$MANIFEST" "Rust native provenance"

    jq -e \
        --arg schema "$SCHEMA" \
        --arg marker "$MARKER" \
        --arg producer "$PRODUCER" \
        --arg transport "$TRANSPORT" \
        --arg transportMarker "$TRANSPORT_MARKER" \
        --argjson nativeCoreAbi "$NATIVE_CORE_ABI" \
        --arg variant "$VARIANT" \
        --arg cargoProfile "$CARGO_PROFILE" \
        '(.schema == $schema) and
         (.marker == $marker) and
         (.producer == $producer) and
         (.runtime == "rust") and
         (.buildSystem == "cargo-ndk") and
         (.variant == $variant) and
         (.profile == $cargoProfile) and
         (.transport == $transport) and
         (.transportMarker == $transportMarker) and
         (.nativeCoreAbi == $nativeCoreAbi)' "$MANIFEST" >/dev/null ||
        die "Rust native provenance identity mismatch: $MANIFEST"

    package_name="$(cargo_package_field name)"
    package_version="$(cargo_package_field version)"
    [[ "$(jq -r '.package' "$MANIFEST")" == "$package_name" ]] || die "Rust package name does not match provenance"
    [[ "$(jq -r '.version' "$MANIFEST")" == "$package_version" ]] || die "Rust package version does not match provenance"

    [[ "$(jq -r '.cargoTomlSha256' "$MANIFEST")" == "$(sha256_file "$CARGO_TOML")" ]] ||
        die "Cargo.toml changed after the production native build"
    [[ "$(jq -r '.cargoLockSha256' "$MANIFEST")" == "$(sha256_file "$CARGO_LOCK")" ]] ||
        die "Cargo.lock changed after the production native build"

    build_input_hash="$(canonical_build_input_hash)"
    [[ "$(jq -r '.buildInputSha256' "$MANIFEST")" == "$build_input_hash" ]] ||
        die "Rust native source changed after the production native build"

    for abi in "${ABIS[@]}"; do
        entry="$(jq -r --arg abi "$abi" '
            [.artifacts[] | select(.abi == $abi)] as $matches |
            if ($matches | length) != 1 then
                error("Rust native provenance must contain one entry for " + $abi)
            else
                $matches[0] | [.target, (.size | tostring), (.sha256 | ascii_upcase)] | @tsv
            end' "$MANIFEST")"
        IFS=$'\t' read -r m_target m_size m_sha <<<"$entry"

        prod="$(production_path "$abi")"
        assert_artifact "$abi" true

        [[ "$m_target" == "$(abi_target "$abi")" ]] || die "Rust native provenance target mismatch for $abi"
        [[ "$m_size" == "$(artifact_size "$prod")" ]] || die "Rust native provenance size mismatch for $abi"
        [[ "$m_sha" == "$(sha256_file "$prod")" ]] || die "Rust native provenance hash mismatch for $abi"
    done

    printf 'Rust native provenance verified: %s (%s variant, cargo %s)\n' "$MARKER" "$VARIANT" "$CARGO_PROFILE"
}

for tool in jq sha256sum stat od mktemp; do
    require_cmd "$tool"
done

for abi in "${ABIS[@]}"; do
    valid_abi "$abi" || die "unsupported ABI: $abi"
done

if [[ "$MODE" == "write" ]]; then
    write_manifest
else
    verify_manifest
fi
