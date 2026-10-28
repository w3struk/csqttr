#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Тест .github/scripts/collect-release-assets.sh на фейковом дереве сборки:
# три APK, три серверных бинаря, SHA256SUMS и список путей для публикации.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="$REPO_ROOT/.github/scripts/collect-release-assets.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VERSION=9.9.9
APK_NAMES=(
    "CSQTT-$VERSION-universal.apk"
    "CSQTT-$VERSION-arm64-v8a.apk"
    "CSQTT-$VERSION-armeabi-v7a.apk"
)
SERVER_NAMES=(csqtt-linux-amd64 csqtt-linux-arm64 csqtt-linux-armv7)
EXPECTED_FILES=("${APK_NAMES[@]}" "${SERVER_NAMES[@]}" SHA256SUMS)

pass=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

ok() {
    pass=$((pass + 1))
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$msg (expected '$expected', got '$actual')"
    ok
}

assert_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
    ok
}

# Builds the fake Gradle/asset tree under $1.
make_tree() {
    local root="$1"

    mkdir -p "$root/app/build/outputs/apk/release" "$root/app/build/generated/assets"

    printf 'android {\n    defaultConfig {\n        versionName = "%s"\n    }\n}\n' \
        "$VERSION" >"$root/app/build.gradle.kts"

    local abi
    for abi in universal arm64-v8a armeabi-v7a; do
        printf 'apk-payload-%s\n' "$abi" \
            >"$root/app/build/outputs/apk/release/app-$VERSION-$abi-release.apk"
    done

    local binary
    for binary in "${SERVER_NAMES[@]}"; do
        printf 'binary-payload-%s\n' "$binary" \
            >"$root/app/build/generated/assets/$binary"
    done
}

# expect_fail <message> <expected stderr fragment|''> <command...>
expect_fail() {
    local msg="$1" fragment="$2"
    shift 2

    local stderr_file="$TMP/stderr.txt"
    : >"$stderr_file"

    if "$@" 2>"$stderr_file"; then
        fail "$msg: command unexpectedly succeeded"
    fi

    if [[ -n "$fragment" ]] && ! grep -qF -- "$fragment" "$stderr_file"; then
        printf 'stderr was:\n' >&2
        sed 's/^/  | /' "$stderr_file" >&2
        fail "$msg: stderr does not mention '$fragment'"
    fi
    ok
}

# ---------------------------------------------------------------- positive run

ROOT="$TMP/root"
OUT="$TMP/out"
# The list file is kept outside --out so that the output directory holds
# exactly the seven published assets.
LIST_FILE="$TMP/asset-paths.txt"
make_tree "$ROOT"

stdout_file="$TMP/stdout.txt"
stderr_file="$TMP/stderr.out"
rm -f "$stdout_file" "$stderr_file" "$LIST_FILE"

bash "$SUT" --root "$ROOT" --out "$OUT" --list-file "$LIST_FILE" \
    >"$stdout_file" 2>"$stderr_file" ||
    {
        sed 's/^/  | /' "$stderr_file" >&2
        fail "collect-release-assets.sh failed on a complete tree"
    }
ok

# Exactly the seven expected files, nothing else (a stray or misnamed copy
# would show up here).
mapfile -t out_files < <(find "$OUT" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
assert_eq "${#out_files[@]}" "7" "output directory holds exactly seven files"
mapfile -t out_files_sorted < <(printf '%s\n' "${EXPECTED_FILES[@]}" | LC_ALL=C sort)
assert_eq "${out_files[*]}" "${out_files_sorted[*]}" "output directory holds exactly the release assets"

for name in "${EXPECTED_FILES[@]}"; do
    assert_file "$OUT/$name"
done

ls_out="$TMP/ls.txt"
ls "$OUT"/*.apk >"$ls_out"
assert_eq "$(wc -l <"$ls_out" | tr -d ' ')" "3" "exactly three APKs in the output directory"

# SHA256SUMS: six lines, each "<64 hex>  <bare name>", sha256sum -c clean.
assert_eq "$(wc -l <"$OUT/SHA256SUMS" | tr -d ' ')" "6" "SHA256SUMS has six lines"
while IFS= read -r line; do
    [[ "$line" =~ ^[0-9a-f]{64}\ \ [^/]+$ ]] ||
        fail "malformed SHA256SUMS line: '$line'"
done <"$OUT/SHA256SUMS"
ok

mapfile -t sums_names < <(sed 's/^[0-9a-f]\{64\}  //' "$OUT/SHA256SUMS" | LC_ALL=C sort)
mapfile -t expected_sums_names < <(printf '%s\n' "${APK_NAMES[@]}" "${SERVER_NAMES[@]}" | LC_ALL=C sort)
assert_eq "${sums_names[*]}" "${expected_sums_names[*]}" \
    "SHA256SUMS covers the six assets by bare name"

verify_out="$TMP/verify.txt"
if ! (cd "$OUT" && sha256sum -c SHA256SUMS) >"$verify_out" 2>&1; then
    sed 's/^/  | /' "$verify_out" >&2
    fail "sha256sum -c SHA256SUMS failed"
fi
assert_eq "$(grep -c ': OK$' "$verify_out" || true)" "6" "sha256sum -c reports six OK lines"

# The six digests must match the payloads that were actually copied.
assert_eq "$(sha256sum "$ROOT/app/build/outputs/apk/release/app-$VERSION-universal-release.apk" | cut -d' ' -f1)" \
    "$(sha256sum "$OUT/CSQTT-$VERSION-universal.apk" | cut -d' ' -f1)" \
    "renamed universal APK is a byte-for-byte copy"
assert_eq "$(sha256sum "$ROOT/app/build/generated/assets/csqtt-linux-armv7" | cut -d' ' -f1)" \
    "$(sha256sum "$OUT/csqtt-linux-armv7" | cut -d' ' -f1)" \
    "server binary is a byte-for-byte copy"

# stdout: the seven absolute paths in order, SHA256SUMS last. The script also
# prints "[OK] <name> [N bytes]" progress lines (build_apk.sh style), so the
# path lines are selected by their leading '$OUT/'.
mapfile -t stdout_paths < <(grep -E "^${OUT//./\\.}/[^/]+$" "$stdout_file")
assert_eq "${#stdout_paths[@]}" "7" "stdout lists seven paths"
mapfile -t expected_paths < <(
    for name in "${APK_NAMES[@]}" "${SERVER_NAMES[@]}" SHA256SUMS; do
        printf '%s/%s\n' "$OUT" "$name"
    done
)
assert_eq "${stdout_paths[*]}" "${expected_paths[*]}" "stdout paths are absolute, in order"
for path in "${stdout_paths[@]}"; do
    [[ "$path" == /* ]] || fail "stdout path is not absolute: '$path'"
    assert_file "$path"
done
assert_eq "${stdout_paths[6]}" "$OUT/SHA256SUMS" "SHA256SUMS is the last stdout path"
assert_eq "$(basename -- "${stdout_paths[0]}")" "${APK_NAMES[0]}" \
    "first stdout path is the universal APK"

# List file: same seven absolute paths, SHA256SUMS last, no self-reference.
assert_file "$LIST_FILE"
assert_eq "$(wc -l <"$LIST_FILE" | tr -d ' ')" "7" "list file has seven lines"
assert_eq "$(cat "$LIST_FILE")" "$(printf '%s\n' "${stdout_paths[@]}")" \
    "list file matches the path lines printed to stdout"
assert_eq "$(tail -n 1 "$LIST_FILE")" "$OUT/SHA256SUMS" "SHA256SUMS is the last list entry"
if grep -qF 'asset-paths.txt' "$LIST_FILE"; then
    fail "list file references itself"
fi
ok

# Defaults: --root alone derives the Gradle paths, and the list file defaults
# to <out>/asset-paths.txt.
DEFAULT_ROOT="$TMP/defaults"
make_tree "$DEFAULT_ROOT"
( cd "$DEFAULT_ROOT" && bash "$SUT" --out "$TMP/out-default" ) >/dev/null ||
    fail "collect-release-assets.sh failed with default paths"
ok
assert_file "$TMP/out-default/asset-paths.txt"
assert_eq "$(wc -l <"$TMP/out-default/asset-paths.txt" | tr -d ' ')" "7" \
    "default list file has seven lines"
assert_eq "$(tail -n 1 "$TMP/out-default/asset-paths.txt")" "$TMP/out-default/SHA256SUMS" \
    "default list file ends with SHA256SUMS"

# --------------------------------------------------------------- negative runs

# Missing APK: exit 1, stderr names the full path.
MISSING_ROOT="$TMP/missing-apk"
make_tree "$MISSING_ROOT"
rm -f "$MISSING_ROOT/app/build/outputs/apk/release/app-$VERSION-arm64-v8a-release.apk"
expect_fail "missing arm64 APK must fail" \
    "$MISSING_ROOT/app/build/outputs/apk/release/app-$VERSION-arm64-v8a-release.apk" \
    bash "$SUT" --root "$MISSING_ROOT" --out "$TMP/out-missing-apk"

# Empty server binary: exit 1, stderr names the full path.
EMPTY_ROOT="$TMP/empty-binary"
make_tree "$EMPTY_ROOT"
: >"$EMPTY_ROOT/app/build/generated/assets/csqtt-linux-armv7"
expect_fail "empty csqtt-linux-armv7 must fail" \
    "$EMPTY_ROOT/app/build/generated/assets/csqtt-linux-armv7" \
    bash "$SUT" --root "$EMPTY_ROOT" --out "$TMP/out-empty-binary"

# Aborted runs must not leave a half-built SHA256SUMS behind.
if [[ -f "$TMP/out-empty-binary/SHA256SUMS" ]]; then
    fail "failed run left a SHA256SUMS behind"
fi
ok

# --version that matches no input files: exit 1.
VERSION_ROOT="$TMP/bad-version"
make_tree "$VERSION_ROOT"
expect_fail "--version with no matching inputs must fail" \
    "1.2.3" \
    bash "$SUT" --root "$VERSION_ROOT" --version 1.2.3 --out "$TMP/out-bad-version"

# Unknown flag: exit 1 plus usage on stderr.
expect_fail "unknown flag must fail with usage" \
    "Usage:" \
    bash "$SUT" --root "$ROOT" --out "$TMP/out-unknown" --no-such-flag

# Missing --out: exit 1 plus usage.
expect_fail "missing --out must fail with usage" \
    "Usage:" \
    bash "$SUT" --root "$ROOT"

printf 'collect-release-assets: %d assertions OK\n' "$pass"
