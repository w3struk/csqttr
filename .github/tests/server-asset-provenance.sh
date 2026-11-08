#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# Run the real provenance writer/verifier on copied source inputs and synthetic
# ELF data. No Cargo, toolchain, hashing, jq or verification logic is mocked.
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/.github/tests/fixtures/server-artifacts.sh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
OUT="$TMP/stdout.txt"
ERR="$TMP/stderr.txt"
WIRE_REVISION="CSQTT-WIRE-3"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    [[ ! -s "$OUT" ]] || printf -- '--- stdout ---\n%s\n' "$(<"$OUT")" >&2
    [[ ! -s "$ERR" ]] || printf -- '--- stderr ---\n%s\n' "$(<"$ERR")" >&2
    exit 1
}

run_sut() {
    if bash "$SUT" "$@" >"$OUT" 2>"$ERR"; then
        STATUS=0
    else
        STATUS=$?
    fi
}

expect_success() {
    local label="$1"
    shift
    run_sut "$@"
    [[ "$STATUS" -eq 0 ]] || fail "$label: expected exit 0, got $STATUS"
}

expect_failure() {
    local label="$1" fragment="$2"
    shift 2
    run_sut "$@"
    [[ "$STATUS" -ne 0 ]] || fail "$label: command unexpectedly succeeded"
    grep -qF -- "$fragment" "$ERR" || fail "$label: stderr does not mention '$fragment'"
    printf '[OK] %s (exit %s): %s\n' "$label" "$STATUS" "$(<"$ERR")"
}

# Every negative calls this before its mutation. Explicit amd64 write/verify
# also passes on the pre-change implementation, so missing ARM cannot hide an
# integrity failure. Each root is new, with real, freshly hashed source inputs.
restore_valid_fixture() {
    ROOT="$(mktemp -d "$TMP/server-root.XXXXXX")"
    make_server_root "$ROOT" || fail "could not copy server source inputs"
    SUT="$ROOT/scripts/server_asset_provenance.sh"
    PATH_ARGS=(--root "$ROOT")
    if [[ "${1:-default}" == custom ]]; then
        ASSET_DIR="$ROOT/chosen assets"
        MANIFEST="$ROOT/chosen provenance/server.json"
        PATH_ARGS+=(--assets-dir "$ASSET_DIR" --manifest "$MANIFEST")
    else
        ASSET_DIR="$ROOT/app/build/generated/assets"
        MANIFEST="$ROOT/app/build/generated/provenance/csqtt-server.json"
    fi
    AMD64="$ASSET_DIR/csqtt-linux-amd64"
    VALID_ARGS=("${PATH_ARGS[@]}" --assets=csqtt-linux-amd64)
    write_server_elf "$AMD64" 2 62 "$WIRE_REVISION" || fail "could not write amd64 ELF fixture"
    expect_success "restored fixture write" write "${VALID_ARGS[@]}"
    expect_success "restored fixture verify" verify "${VALID_ARGS[@]}"
}

assert_amd64_manifest() {
    local manifest="$1"
    jq -e '.schema == "csqtt.server-asset-provenance.v4" and (.artifacts | length) == 1 and .artifacts[0].assetName == "csqtt-linux-amd64" and .artifacts[0].target == "x86_64-unknown-linux-musl" and .artifacts[0].elfClass == 2 and .artifacts[0].elfMachine == 62' "$manifest" >/dev/null ||
        fail "manifest must describe exactly the amd64 production artifact"
    jq -e '.marker == "CSQTT_RUST_SERVER_PRODUCTION_V1" and .producer == "rust-server/build_linux.sh" and .runtime == "rust" and .features == []' "$manifest" >/dev/null ||
        fail "production identity and default features must be preserved"
}

rewrite_manifest() {
    jq "$@" "$MANIFEST" >"$MANIFEST.edit" || fail "could not mutate manifest fixture"
    mv -- "$MANIFEST.edit" "$MANIFEST"
}

test_default_amd64_manifest() {
    restore_valid_fixture
    printf 'unrelated asset\n' >"$ASSET_DIR/notes.txt"
    local unrelated_hash
    unrelated_hash="$(sha256sum "$ASSET_DIR/notes.txt")"
    # The copied script derives its root and generated paths without flags.
    expect_success "default amd64-only write" write
    assert_amd64_manifest "$MANIFEST"
    expect_success "default amd64-only verify" verify
    [[ "$(sha256sum "$ASSET_DIR/notes.txt")" == "$unrelated_hash" ]] ||
        fail "default write/verify changed an unrelated asset"

    restore_valid_fixture custom
    printf 'custom unrelated asset\n' >"$ASSET_DIR/csqtt-linux-mips"
    unrelated_hash="$(sha256sum "$ASSET_DIR/csqtt-linux-mips")"
    # Known ARM names outside the selected assets directory are irrelevant.
    write_server_elf "$ROOT/app/build/generated/assets/csqtt-linux-arm64" 2 183 "$WIRE_REVISION"
    expect_success "explicit amd64 and custom paths" write "${PATH_ARGS[@]}" --assets csqtt-linux-amd64
    assert_amd64_manifest "$MANIFEST"
    expect_success "equals-form assets and custom paths" verify --root "$ROOT" \
        --assets=csqtt-linux-amd64 --assets-dir="$ASSET_DIR" --manifest="$MANIFEST"
    [[ "$(sha256sum "$ASSET_DIR/csqtt-linux-mips")" == "$unrelated_hash" ]] ||
        fail "custom write/verify changed an unrelated asset"
}

test_invalid_asset_selection() {
    local selection form mode class machine
    local -a selection_args
    for selection in csqtt-linux-arm64 csqtt-linux-armv7 csqtt-linux-mips '' ',' \
        csqtt-linux-amd64,csqtt-linux-amd64 csqtt-linux-amd64,csqtt-linux-arm64 \
        csqtt-linux-amd64,csqtt-linux-arm64,csqtt-linux-armv7 \
        ,csqtt-linux-amd64 csqtt-linux-amd64, csqtt-linux-amd64,, \
        $'csqtt-linux-amd64\ncsqtt-linux-arm64'; do
        for form in split equals; do
            for mode in write verify; do
                restore_valid_fixture
                case "$selection" in
                    csqtt-linux-arm64 | csqtt-linux-armv7)
                        if [[ "$selection" == csqtt-linux-arm64 ]]; then
                            class=2 machine=183
                        else
                            class=1 machine=40
                        fi
                        # Give ARM a complete matching payload/record, not a
                        # missing file that could masquerade as selection denial.
                        write_server_elf "$ASSET_DIR/$selection" "$class" "$machine" "$WIRE_REVISION"
                        rewrite_manifest --arg name "$selection" --argjson class "$class" \
                            --argjson machine "$machine" \
                            --arg target "$([[ "$class" == 2 ]] && printf aarch64-unknown-linux-musl || printf armv7-unknown-linux-musleabihf)" \
                            --argjson size "$(stat -c '%s' "$ASSET_DIR/$selection")" \
                            --arg sha "$(sha256sum "$ASSET_DIR/$selection" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')" \
                            '.artifacts = [{assetName: $name, target: $target, elfClass: $class, elfMachine: $machine, binarySize: $size, binarySha256: $sha}]'
                        ;;
                esac
                if [[ "$form" == split ]]; then
                    selection_args=(--assets "$selection")
                else
                    selection_args=("--assets=$selection")
                fi
                expect_failure "$mode rejects $form selection '$selection'" "--assets" \
                    "$mode" "${PATH_ARGS[@]}" "${selection_args[@]}"
            done
        done
    done
    for mode in write verify; do
        restore_valid_fixture
        expect_failure "$mode rejects missing --assets value" "--assets requires a value" \
            "$mode" "${PATH_ARGS[@]}" --assets
    done
}

test_legacy_manifest_rejected() {
    restore_valid_fixture
    local source_hash
    source_hash="$(jq -r '.buildInputSha256' "$MANIFEST")"
    # Append complete legacy records to a FRESH manifest; there are no stale ARM
    # files in ASSET_DIR, and its source/Cargo hashes remain valid.
    rewrite_manifest '.artifacts += [
        (.artifacts[0] | .assetName = "csqtt-linux-arm64" | .target = "aarch64-unknown-linux-musl" | .elfClass = 2 | .elfMachine = 183),
        (.artifacts[0] | .assetName = "csqtt-linux-armv7" | .target = "armv7-unknown-linux-musleabihf" | .elfClass = 1 | .elfMachine = 40)
    ]'
    [[ "$(jq -r '.buildInputSha256' "$MANIFEST")" == "$source_hash" ]] ||
        fail "legacy fixture mutation changed the fresh source hash"
    expect_failure "default verify rejects legacy three-record manifest" "artifact count mismatch" \
        verify "${PATH_ARGS[@]}"
}

test_stale_arm_assets_rejected() {
    local location asset content mode class machine stale_hash amd64_hash manifest_hash
    for location in default custom; do
        for asset in csqtt-linux-arm64 csqtt-linux-armv7; do
            for content in elf empty; do
                for mode in write verify; do
                    restore_valid_fixture "$location"
                    if [[ "$asset" == csqtt-linux-arm64 ]]; then
                        class=2 machine=183
                    else
                        class=1 machine=40
                    fi
                    write_server_elf "$ASSET_DIR/$asset" "$class" "$machine" "$WIRE_REVISION"
                    [[ "$content" != empty ]] || : >"$ASSET_DIR/$asset"
                    stale_hash="$(sha256sum "$ASSET_DIR/$asset")"
                    amd64_hash="$(sha256sum "$AMD64")"
                    manifest_hash="$(sha256sum "$MANIFEST")"
                    # Direct invocation has no producer: this gate must stand on
                    # its own even when Gradle's native producer is disabled.
                    expect_failure "$mode rejects $content stale $asset in $location assets" \
                        "stale ARM server asset" "$mode" "${VALID_ARGS[@]}"
                    [[ "$(sha256sum "$ASSET_DIR/$asset")" == "$stale_hash" ]] ||
                        fail "stale ARM check deleted or changed $asset"
                    [[ "$(sha256sum "$AMD64")" == "$amd64_hash" ]] ||
                        fail "stale ARM check changed amd64"
                    [[ "$(sha256sum "$MANIFEST")" == "$manifest_hash" ]] ||
                        fail "stale ARM check changed the manifest"
                done
            done
        done
    done
}

test_integrity_and_features_fail_closed() {
    local mode mutation fragment feature
    for mode in write verify; do
        for mutation in missing empty short non-elf magic class endianness machine machine-high-byte wire; do
            restore_valid_fixture
            case "$mutation" in
                missing)
                    rm -- "$AMD64"
                    fragment="Linux server asset csqtt-linux-amd64 not found"
                    ;;
                empty)
                    : >"$AMD64"
                    fragment="Linux server asset csqtt-linux-amd64 is empty"
                    ;;
                short)
                    printf '\177ELF\002\001' >"$AMD64"
                    fragment="Invalid ELF header"
                    ;;
                non-elf)
                    printf 'substituted non-ELF server payload\n' >"$AMD64"
                    fragment="is not ELF"
                    ;;
                magic)
                    printf 'BAD!' | dd of="$AMD64" bs=1 count=4 conv=notrunc status=none
                    fragment="is not ELF"
                    ;;
                class)
                    write_server_elf "$AMD64" 1 62 "$WIRE_REVISION"
                    fragment="ELF class or endianness mismatch"
                    ;;
                endianness)
                    printf '\002' | dd of="$AMD64" bs=1 seek=5 count=1 conv=notrunc status=none
                    fragment="ELF class or endianness mismatch"
                    ;;
                machine)
                    write_server_elf "$AMD64" 2 183 "$WIRE_REVISION"
                    fragment="ELF machine mismatch"
                    ;;
                machine-high-byte)
                    write_server_elf "$AMD64" 2 318 "$WIRE_REVISION"
                    fragment="expected 62, got 318"
                    ;;
                wire)
                    write_server_elf "$AMD64" 2 62 CSQTT-WIRE-X
                    fragment="does not expose wire protocol revision $WIRE_REVISION"
                    ;;
            esac
            expect_failure "$mode rejects $mutation amd64 payload" "$fragment" "$mode" "${VALID_ARGS[@]}"
        done
    done

    for mutation in payload-size payload-sha size sha target elf-class elf-machine source-hash source cargo-toml cargo-lock; do
        restore_valid_fixture
        case "$mutation" in
            payload-size)
                printf 'extra payload bytes\n' >>"$AMD64"
                fragment="provenance size mismatch"
                ;;
            payload-sha)
                printf 'X' | dd of="$AMD64" bs=1 seek=32 count=1 conv=notrunc status=none
                fragment="asset does not match provenance"
                ;;
            size)
                rewrite_manifest '.artifacts[0].binarySize += 1'
                fragment="provenance size mismatch"
                ;;
            sha)
                rewrite_manifest '.artifacts[0].binarySha256 = "0000000000000000000000000000000000000000000000000000000000000000"'
                fragment="asset does not match provenance"
                ;;
            target)
                rewrite_manifest '.artifacts[0].target = "aarch64-unknown-linux-musl"'
                fragment="provenance target mismatch"
                ;;
            elf-class)
                rewrite_manifest '.artifacts[0].elfClass = 1'
                fragment="provenance ELF class mismatch"
                ;;
            elf-machine)
                rewrite_manifest '.artifacts[0].elfMachine = 183'
                fragment="provenance ELF machine mismatch"
                ;;
            source-hash)
                rewrite_manifest '.buildInputSha256 = "0000000000000000000000000000000000000000000000000000000000000000"'
                fragment="source changed after the production server build"
                ;;
            source)
                printf '\n// provenance fixture mutation\n' >>"$ROOT/rust-server/main.rs"
                fragment="source changed after the production server build"
                ;;
            cargo-toml)
                printf '\n# provenance fixture mutation\n' >>"$ROOT/rust-server/Cargo.toml"
                fragment="Cargo.toml changed after the production server build"
                ;;
            cargo-lock)
                printf '\n# provenance fixture mutation\n' >>"$ROOT/rust-server/Cargo.lock"
                fragment="Cargo.lock changed after the production server build"
                ;;
        esac
        expect_failure "verify rejects $mutation integrity mutation" "$fragment" verify "${VALID_ARGS[@]}"
    done

    for feature in diagnostics fixture-only; do
        restore_valid_fixture
        expect_success "record $feature with --features" write "${VALID_ARGS[@]}" --features "$feature"
        expect_failure "verify rejects unapproved $feature" "'$feature' cargo feature" verify "${VALID_ARGS[@]}"
        if [[ "$feature" == diagnostics ]]; then
            expect_success "allow diagnostics with equals form" verify "${VALID_ARGS[@]}" --allow-feature=diagnostics
            expect_success "allow diagnostics with split form" verify "${VALID_ARGS[@]}" --allow-feature diagnostics
        fi
    done

    restore_valid_fixture
    expect_success "record two features with equals form" write "${VALID_ARGS[@]}" --features=diagnostics,fixture-only
    expect_failure "allowing diagnostics does not authorize another recorded feature" "'fixture-only' cargo feature" \
        verify "${VALID_ARGS[@]}" --allow-feature=diagnostics
}

# Keep running the named cases during red so default/selection failures are
# visible alongside the unchanged fail-closed integrity behavior.
failed=0
for test_case in test_default_amd64_manifest test_invalid_asset_selection \
    test_legacy_manifest_rejected test_stale_arm_assets_rejected test_integrity_and_features_fail_closed; do
    set +e
    ( trap - EXIT; set -e; "$test_case" )
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        printf '[PASS] %s\n' "$test_case"
    else
        printf '[FAIL] %s (exit %s)\n' "$test_case" "$status" >&2
        failed=$((failed + 1))
    fi
done
[[ "$failed" -eq 0 ]] || exit 1
printf 'server-asset-provenance: 5 cases OK\n'
