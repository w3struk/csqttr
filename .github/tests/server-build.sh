#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# Exercise the copied producers, including the real preset/provenance checks,
# installer, hashes, jq and ELF parsing. Only external toolchain calls are faked.
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/.github/tests/fixtures/server-artifacts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p -- "$BIN"

cat >"$BIN/tool-mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
tool="${0##*/}"
entry="$(jq -cn --arg tool "$tool" --arg cwd "$PWD" \
    --arg targetDir "${CARGO_TARGET_DIR:-}" \
    --arg globalCache "${ZIG_GLOBAL_CACHE_DIR:-}" \
    --arg localCache "${ZIG_LOCAL_CACHE_DIR:-}" \
    --args '{tool: $tool, argv: $ARGS.positional, cwd: $cwd,
             targetDir: $targetDir, globalCache: $globalCache, localCache: $localCache}' -- "$@")"
printf '%s\n' "$entry" >>"${SERVER_BUILD_CALLS:?}"
reject() { printf 'unexpected %s invocation: %s\n' "$tool" "$*" >&2; exit 97; }

case "$tool" in
    rustup)
        case "$*" in
            'toolchain install 1.97.1 --profile minimal --component rustfmt --component clippy' | \
            'target add x86_64-unknown-linux-musl --toolchain 1.97.1') exit 0 ;;
            *) reject "$@" ;;
        esac
        ;;
    rustc)
        [[ "$*" == '+1.97.1 --version' ]] || reject "$@"
        printf 'rustc 1.97.1 (fixture)\n'
        ;;
    zig)
        [[ "$*" == version ]] || reject "$@"
        printf 'zig fixture\n'
        ;;
    cargo)
        [[ "$*" != 'zigbuild --help' ]] || exit 0
        [[ "${1:-}" == '+1.97.1' ]] || reject "$@"
        shift
        operation="${1:-}"
        case "$operation" in
            fmt)
                [[ "$*" == 'fmt --all -- --check' ]] || reject "$@"
                ;;
            clippy)
                case "$*" in
                    'clippy --release --target x86_64-unknown-linux-musl --all-targets -- -D warnings' | \
                    'clippy --release --target x86_64-unknown-linux-musl --features diagnostics --all-targets -- -D warnings') ;;
                    *) reject "$@" ;;
                esac
                ;;
            test)
                case "$*" in
                    'test --target x86_64-unknown-linux-musl --all-targets' | \
                    'test --target x86_64-unknown-linux-musl --features diagnostics --all-targets') ;;
                    *) reject "$@" ;;
                esac
                ;;
            zigbuild)
                [[ "${2:-}" == --release && "${3:-}" == --target && \
                    "${4:-}" == x86_64-unknown-linux-musl ]] || reject "$@"
                shift 4
                while (($#)); do
                    [[ "$1" == --features && $# -ge 2 && -n "$2" ]] || reject "$@"
                    shift 2
                done
                [[ "${SERVER_BUILD_CARGO_MODE:-ok}" != fail ]] || exit 17
                [[ "${SERVER_BUILD_CARGO_MODE:-ok}" != missing ]] || exit 0
                source "${SERVER_ARTIFACTS_HELPER:?}"
                output="${CARGO_TARGET_DIR:?}/x86_64-unknown-linux-musl/release/csqtt"
                write_server_elf "$output" 2 62 CSQTT-WIRE-3
                chmod 0755 "$output"
                ;;
            *) reject "$@" ;;
        esac
        ;;
    *) reject "$@" ;;
esac
MOCK
chmod 0755 "$BIN/tool-mock"
for tool in cargo rustup rustc zig; do
    ln -s tool-mock "$BIN/$tool"
done
export PATH="$BIN:$PATH"
export SERVER_ARTIFACTS_HELPER="$REPO_ROOT/.github/tests/fixtures/server-artifacts.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    local log
    for log in "${OUT:-}" "${ERR:-}" "${CALLS:-}"; do
        [[ -s "$log" ]] || continue
        printf -- '--- %s ---\n%s\n' "${log##*/}" "$(<"$log")" >&2
    done
    exit 1
}

make_fixture() {
    ROOT="$(mktemp -d "$TMP/server-root.XXXXXX")"
    make_server_root "$ROOT" || fail "could not copy server source inputs"
    ASSETS="$ROOT/app/build/generated/assets"
    DIST="$ROOT/rust-server/dist"
    MANIFEST="$ROOT/app/build/generated/provenance/csqtt-server.json"
    CARGO_BINARY="$ROOT/build/csqtt-uring-linux-csqtt-linux-amd64/x86_64-unknown-linux-musl/release/csqtt"
    OUT="$ROOT/stdout.txt" ERR="$ROOT/stderr.txt" CALLS="$ROOT/calls.jsonl"
    export SERVER_BUILD_CALLS="$CALLS" SERVER_BUILD_CARGO_MODE=ok
}

run_sut() {
    : >"$CALLS"
    if bash "$@" </dev/null >"$OUT" 2>"$ERR"; then STATUS=0; else STATUS=$?; fi
    printf '[RUN] bash'
    printf ' %q' "$@"
    printf ' (exit %s)\n' "$STATUS"
}

expect_success() {
    run_sut "$@"
    [[ "$STATUS" -eq 0 ]] || fail "expected producer success, got exit $STATUS"
}

# Literal boundary expectations, independent of the production arrays/helpers.
assert_calls() {
    local entry_point="$1" tests="$2" features="$3"
    python3 - "$CALLS" "$ROOT" "$entry_point" "$tests" "$features" <<'PY' || fail "toolchain argv/environment contract"
import json
import sys
from pathlib import Path

calls_path, root, entry_point, tests, features = sys.argv[1:]
calls = [json.loads(line) for line in Path(calls_path).read_text().splitlines()]
feature_args = [arg for feature in features.split(',') if feature for arg in ('--features', feature)]
payload = ['+1.97.1', 'zigbuild', '--release', '--target', 'x86_64-unknown-linux-musl', *feature_args]
cargo = [['zigbuild', '--help']]
if entry_point == 'producer':
    if tests == 'yes':
        cargo += [
            ['+1.97.1', 'fmt', '--all', '--', '--check'],
            ['+1.97.1', 'clippy', '--release', '--target', 'x86_64-unknown-linux-musl', *feature_args, '--all-targets', '--', '-D', 'warnings'],
            ['+1.97.1', 'test', '--target', 'x86_64-unknown-linux-musl', *feature_args, '--all-targets'],
        ]
    cargo += [['zigbuild', '--help']]
cargo += [payload]
assert [c['argv'] for c in calls if c['tool'] == 'cargo'] == cargo, calls
rustup = [] if entry_point == 'variants' else [
    ['toolchain', 'install', '1.97.1', '--profile', 'minimal', '--component', 'rustfmt', '--component', 'clippy'],
    ['target', 'add', 'x86_64-unknown-linux-musl', '--toolchain', '1.97.1'],
]
assert [c['argv'] for c in calls if c['tool'] == 'rustup'] == rustup, calls
assert [c['argv'] for c in calls if c['tool'] == 'rustc'] == ([] if entry_point == 'variants' else [['+1.97.1', '--version']]), calls
assert [c['argv'] for c in calls if c['tool'] == 'zig'] == ([] if entry_point == 'variants' else [['version']]), calls
builds = [c for c in calls if c['tool'] == 'cargo' and c['argv'] == payload]
assert len(builds) == 1, builds
build = builds[0]
assert build['cwd'] == root + '/rust-server', build
assert build['targetDir'] == root + '/build/csqtt-uring-linux-csqtt-linux-amd64', build
assert build['globalCache'] == root + '/build/zig-cache/csqtt-linux-amd64/global', build
assert build['localCache'] == root + '/build/zig-cache/csqtt-linux-amd64/local', build
PY
}

assert_payload() {
    local features="${1:-[]}" path sha size
    for path in "$CARGO_BINARY" "$ASSETS/csqtt-linux-amd64" "$DIST/csqtt-linux-amd64"; do
        [[ -f "$path" && "$(stat -c '%a' "$path")" == 755 ]] || fail "missing or non-0755 payload: $path"
        cmp -s -- "$CARGO_BINARY" "$path" || fail "copy differs from Cargo output: $path"
    done
    for path in "$ASSETS" "$DIST"; do
        [[ ! -e "$path/csqtt-linux-arm64" && ! -L "$path/csqtt-linux-arm64" && \
            ! -e "$path/csqtt-linux-armv7" && ! -L "$path/csqtt-linux-armv7" ]] || fail "stale ARM payload in $path"
    done
    sha="$(sha256sum "$CARGO_BINARY")"
    sha="${sha%% *}"
    sha="${sha^^}"
    size="$(stat -c '%s' "$CARGO_BINARY")"
    jq -e --argjson features "$features" --arg sha "$sha" --argjson size "$size" '
        .schema == "csqtt.server-asset-provenance.v4" and
        .marker == "CSQTT_RUST_SERVER_PRODUCTION_V1" and
        .producer == "rust-server/build_linux.sh" and .runtime == "rust" and
        .features == $features and (.artifacts | length) == 1 and
        .artifacts[0] == {assetName: "csqtt-linux-amd64", target: "x86_64-unknown-linux-musl",
                         elfClass: 2, elfMachine: 62, binarySize: $size, binarySha256: $sha}
    ' "$MANIFEST" >/dev/null || fail "expected one-entry amd64 manifest with real hash/size and correct features"
}

test_amd64_only_build() {
    make_fixture
    expect_success "$ROOT/rust-server/build_linux.sh" --no-tests
    assert_calls producer no ''
    assert_payload
    expect_success "$ROOT/scripts/server_asset_provenance.sh" verify
}

test_incremental_cleanup_preserves_foreign_files_and_caches() {
    make_fixture
    local path round asset
    local -a preserved=(
        app/build/generated/assets/keep.txt app/build/generated/assets/csqtt-linux-mips
        rust-server/dist/keep.txt rust-server/dist/csqtt-linux-mips rust-server/dist/csqtt
        build/csqtt-uring-linux-csqtt-linux-arm64/aarch64-unknown-linux-musl/release/csqtt
        build/csqtt-uring-linux-csqtt-linux-armv7/armv7-unknown-linux-musleabihf/release/csqtt
        build/zig-cache/csqtt-linux-arm64/global/keep.txt build/zig-cache/csqtt-linux-arm64/local/keep.txt
        build/zig-cache/csqtt-linux-armv7/global/keep.txt build/zig-cache/csqtt-linux-armv7/local/keep.txt
    )
    for path in "${preserved[@]}"; do
        mkdir -p -- "$(dirname -- "$ROOT/$path")" "$(dirname -- "$ROOT/expected/$path")"
        printf 'foreign sentinel\000%s\n' "$path" >"$ROOT/$path"
        cp -- "$ROOT/$path" "$ROOT/expected/$path"
    done
    for round in 1 2; do
        for path in "$ASSETS" "$DIST"; do
            if [[ "$round" == 1 ]]; then
                write_server_elf "$path/csqtt-linux-arm64" 2 183 CSQTT-WIRE-3
                write_server_elf "$path/csqtt-linux-armv7" 1 40 CSQTT-WIRE-3
            else
                for asset in csqtt-linux-arm64 csqtt-linux-armv7; do
                    ln -s "$ROOT/absent-$asset" "$path/$asset"
                done
            fi
        done
        printf 'obsolete assets-only name\n' >"$ASSETS/csqtt"
        expect_success "$ROOT/rust-server/build_linux.sh" --no-tests --jobs=2
        assert_calls producer no ''
        assert_payload
        [[ ! -e "$ASSETS/csqtt" ]] || fail "existing obsolete assets/csqtt cleanup was lost"
        for path in "${preserved[@]}"; do
            cmp -s -- "$ROOT/expected/$path" "$ROOT/$path" || fail "incremental build changed foreign file/cache: $path"
        done
        printf '[OK] incremental build %s: known ARM files removed; foreign files/caches byte-identical\n' "$round"
    done
    # With no producer invocation, the real verifier remains fail-closed.
    write_server_elf "$ASSETS/csqtt-linux-arm64" 2 183 CSQTT-WIRE-3
    run_sut "$ROOT/scripts/server_asset_provenance.sh" verify
    [[ "$STATUS" -eq 1 ]] && grep -qF 'stale ARM server asset' "$ERR" || fail "disabled producer must not bypass stale ARM verification"
}

test_legacy_cli_and_features() {
    local mode script arg
    local -a args
    for mode in sequential jobs tests default diagnostics; do
        make_fixture
        case "$mode" in
            sequential) args=(--no-tests --sequential) ;;
            jobs) args=(--no-tests --jobs=2) ;;
            tests) args=(--tests) ;;
            default) args=() ;;
            diagnostics) args=(--tests --diagnostics --jobs=2) ;;
        esac
        expect_success "$ROOT/rust-server/build_linux.sh" "${args[@]}"
        if [[ "$mode" == diagnostics ]]; then
            assert_calls producer yes diagnostics
            assert_payload '["diagnostics"]'
            run_sut "$ROOT/scripts/server_asset_provenance.sh" verify
            [[ "$STATUS" -eq 1 ]] && grep -qF "'diagnostics' cargo feature" "$ERR" || fail "production verify accepted diagnostics without opt-in"
            expect_success "$ROOT/scripts/server_asset_provenance.sh" verify --allow-feature=diagnostics
        else
            if [[ "$mode" == tests || "$mode" == default ]]; then
                assert_calls producer yes ''
            else
                assert_calls producer no ''
            fi
            assert_payload
        fi
    done
    make_fixture
    expect_success "$ROOT/rust-server/build_linux_variants.sh" --sequential --jobs=2 \
        --cargo-feature=diagnostics --cargo-feature=fixture-only
    assert_calls variants no diagnostics,fixture-only
    [[ -f "$CARGO_BINARY" ]] || fail "standalone variants entry point did not produce amd64"

    for script in build_linux.sh build_linux_variants.sh; do
        expect_success "$ROOT/rust-server/$script" --help
        [[ ! -s "$CALLS" ]] || fail "--help invoked the toolchain"
        for arg in --jobs=0 --jobs=invalid --unknown; do
            run_sut "$ROOT/rust-server/$script" "$arg"
            [[ "$STATUS" -eq 2 && ! -s "$CALLS" ]] || fail "$script changed invalid-CLI failure behavior: $arg"
        done
    done
}

test_failed_or_missing_cargo_output() {
    local script mode scheduling
    local -a args
    for script in build_linux.sh build_linux_variants.sh; do
        for scheduling in parallel sequential; do
            for mode in fail missing; do
                make_fixture
                args=()
                [[ "$script" != build_linux.sh ]] || args+=(--no-tests)
                [[ "$scheduling" != sequential ]] || args+=(--sequential)
                export SERVER_BUILD_CARGO_MODE="$mode"
                run_sut "$ROOT/rust-server/$script" "${args[@]}"
                [[ "$STATUS" -eq 1 ]] || fail "$script/$scheduling/$mode must fail, got exit $STATUS"
                if [[ "$mode" == fail ]]; then
                    grep -qF 'exit=17' "$OUT" || fail "cargo failure status disappeared from scheduler summary"
                else
                    grep -qF 'binary missing' "$OUT" || fail "successful cargo without binary was not reported"
                fi
                if [[ "$script" == build_linux.sh ]]; then assert_calls producer no ''; else assert_calls variants no ''; fi
                [[ ! -e "$ASSETS/csqtt-linux-amd64" && ! -e "$DIST/csqtt-linux-amd64" && ! -e "$MANIFEST" ]] ||
                    fail "failed/missing Cargo output reached copying or provenance"
            done
        done
    done
}

# Narrow source contract complement (not a replacement) to the parent's real
# Gradle-graph and APK packaging gates: the APK ships the Rust client only, and
# the server is built by rust-server/build_linux.sh outside Gradle.
test_gradle_client_only_contract() {
    python3 - "$REPO_ROOT/app/build.gradle.kts" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()

def block(text, marker):
    start = text.index('{', text.index(marker))
    depth = 1
    end = start + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start + 1:end - 1]

for banned in (
    'buildNativeServer',
    'verifyNativeServer',
    'rustAssetsDir',
    'serverNativeInputs',
    'serverCargoArtifacts',
    'syncInstallerAsset',
    'installerAssetsDir',
    'server_asset_provenance.sh',
):
    assert banned not in source, f'{banned} must be gone: the APK no longer packages the server'
assert 'assets.directories.add' not in source, 'the APK must not add generated assets'

assert re.search(
    r'tasks\.register<Exec>\("buildNativeClient\$\{capitalised\(variant\)\}"\)', source
), 'client build task lost'
assert re.search(
    r'tasks\.register<Exec>\("verifyNativeClient\$\{capitalised\(variant\)\}"\)', source
), 'client verify task lost'
assert re.search(
    r'"mergeDebugJniLibFolders"\s*->\s*dependsOn\(verifyNativeClientDebug\)', source
), 'debug client merge verification dependency lost'
assert re.search(
    r'"mergeReleaseJniLibFolders"\s*->\s*dependsOn\(verifyNativeClientRelease\)', source
), 'release client merge verification dependency lost'

install = block(source, 'tasks.register<Exec>("installCsqtt$capitalisedVariant")')
assert 'assemble$capitalisedVariant' in install, install
assert 'verifyNativeClientRelease' in install and 'verifyNativeClientDebug' in install, install
assert 'verifyNativeServer' not in install, install

aggregate = block(source, 'tasks.register("verifyNativeArtifacts")')
assert re.search(
    r'dependsOn\(verifyNativeClientDebug,\s*verifyNativeClientRelease\)', aggregate
), aggregate
PY
}

failed=0
for test_case in test_amd64_only_build test_incremental_cleanup_preserves_foreign_files_and_caches \
    test_legacy_cli_and_features test_failed_or_missing_cargo_output test_gradle_client_only_contract; do
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
printf 'server-build: 5 cases OK\n'
