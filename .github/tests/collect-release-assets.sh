#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Тест .github/scripts/collect-release-assets.sh на фейковом дереве сборки:
# три APK, один серверный бинарь, install.sh, bootstrap.sh, SHA256SUMS и
# список путей для публикации.

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
SERVER_NAMES=(csqtt-linux-amd64)
INSTALLER_NAME=install.sh
BOOTSTRAP_NAME=bootstrap.sh
EXPECTED_FILES=(
    "CSQTT-$VERSION-universal.apk"
    "CSQTT-$VERSION-arm64-v8a.apk"
    "CSQTT-$VERSION-armeabi-v7a.apk"
    csqtt-linux-amd64
    install.sh
    bootstrap.sh
    SHA256SUMS
)
# Independently computed SHA-256s of the literal fixture payloads below.
# Checksums keep the server first, then the three APKs in ABI order, then
# install.sh and bootstrap.sh.
EXPECTED_SUMS="8be94b089e9915c9dfac367b435ccbc245fa888215220e0b087d324bce6d06be  csqtt-linux-amd64
e00d98a5a52bc42b1d5fb81237c4fc3e7a3c0b7a14dc9683e7184e5f4d1f36e2  CSQTT-$VERSION-universal.apk
bd8e1f1d79a8ad2c3d2e44b573615a147ce4ce76635b35b602d665059602c58f  CSQTT-$VERSION-arm64-v8a.apk
63c676691e4cb64f74fb7344c49637ac228995a219070e155bdfe5fe74744de4  CSQTT-$VERSION-armeabi-v7a.apk
2ec21d5aaeda5bce18d844956d7256e3b75e8affda77b7c5c56f9f6a15b43e48  install.sh
30278bb38770b92b0b968cd42eb1230fa665211692b692bcd06777d3ef1a89b1  bootstrap.sh"

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

assert_same_bytes() {
    cmp -s -- "$1" "$2" || fail "$3"
    ok
}

# Builds the fake Gradle/asset tree under $1.
make_tree() {
    local root="$1"

    mkdir -p "$root/app/build/outputs/apk/release" "$root/app/build/generated/assets" \
        "$root/scripts"

    printf 'android {\n    defaultConfig {\n        versionName = "%s"\n    }\n}\n' \
        "$VERSION" >"$root/app/build.gradle.kts"

    printf 'installer-payload-v1\n' >"$root/scripts/$INSTALLER_NAME"
    printf 'bootstrap-payload-v1\n' >"$root/scripts/$BOOTSTRAP_NAME"

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

    local stderr_file="$TMP/stderr.txt" code
    : >"$stderr_file"

    if "$@" >/dev/null 2>"$stderr_file"; then
        fail "$msg: command unexpectedly succeeded"
    else
        code=$?
    fi
    assert_eq "$code" "1" "$msg exits with 1"

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
# Legacy inputs must not become published assets. They also let an old
# collector reach the count assertion instead of a missing input.
printf 'legacy-arm64-input\n' >"$ROOT/app/build/generated/assets/csqtt-linux-arm64"
printf 'legacy-armv7-input\n' >"$ROOT/app/build/generated/assets/csqtt-linux-armv7"

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

# The installer must be checksummed under exactly its own name, not a lookalike.
grep -Eq '^[0-9a-f]{64}  install\.sh$' "$OUT/SHA256SUMS" ||
    fail "SHA256SUMS has no exact install.sh entry"
ok

# The bootstrap entry is what the documented one-liner fetches first.
grep -Eq '^[0-9a-f]{64}  bootstrap\.sh$' "$OUT/SHA256SUMS" ||
    fail "SHA256SUMS has no exact bootstrap.sh entry"
ok

assert_eq "$(<"$OUT/SHA256SUMS")" "$EXPECTED_SUMS" \
    "SHA256SUMS has the six independent digests and bare names in order"

verify_out="$TMP/verify.txt"
if ! (cd "$OUT" && sha256sum -c SHA256SUMS) >"$verify_out" 2>&1; then
    sed 's/^/  | /' "$verify_out" >&2
    fail "sha256sum -c SHA256SUMS failed"
fi
assert_eq "$(grep -c ': OK$' "$verify_out" || true)" "6" "sha256sum -c reports six OK lines"
printf 'sha256sum -c SHA256SUMS (clean out):\n%s\n' "$(<"$verify_out")"

# Every published payload must be a byte-for-byte copy, not a regenerated file.
assert_same_bytes "$ROOT/app/build/outputs/apk/release/app-$VERSION-universal-release.apk" \
    "$OUT/CSQTT-$VERSION-universal.apk" \
    "renamed universal APK is a byte-for-byte copy"
assert_same_bytes "$ROOT/app/build/outputs/apk/release/app-$VERSION-arm64-v8a-release.apk" \
    "$OUT/CSQTT-$VERSION-arm64-v8a.apk" \
    "renamed arm64 APK is a byte-for-byte copy"
assert_same_bytes "$ROOT/app/build/outputs/apk/release/app-$VERSION-armeabi-v7a-release.apk" \
    "$OUT/CSQTT-$VERSION-armeabi-v7a.apk" \
    "renamed armeabi-v7a APK is a byte-for-byte copy"
assert_same_bytes "$ROOT/app/build/generated/assets/csqtt-linux-amd64" \
    "$OUT/csqtt-linux-amd64" \
    "amd64 server binary is a byte-for-byte copy"
assert_same_bytes "$ROOT/scripts/$INSTALLER_NAME" \
    "$OUT/install.sh" \
    "install.sh is a byte-for-byte copy of the repository installer"
assert_same_bytes "$ROOT/scripts/$BOOTSTRAP_NAME" \
    "$OUT/bootstrap.sh" \
    "bootstrap.sh is a byte-for-byte copy of the repository bootstrap"

# stdout: the seven absolute paths in order, SHA256SUMS last. The script also
# prints "[OK] <name> [N bytes]" progress lines (build_apk.sh style), so the
# path lines are selected by their leading '$OUT/'.
mapfile -t stdout_paths < <(grep -E "^${OUT//./\\.}/[^/]+$" "$stdout_file")
assert_eq "${#stdout_paths[@]}" "7" "stdout lists seven paths"
expected_paths=(
    "$OUT/CSQTT-$VERSION-universal.apk"
    "$OUT/CSQTT-$VERSION-arm64-v8a.apk"
    "$OUT/CSQTT-$VERSION-armeabi-v7a.apk"
    "$OUT/csqtt-linux-amd64"
    "$OUT/install.sh"
    "$OUT/bootstrap.sh"
    "$OUT/SHA256SUMS"
)
assert_eq "${stdout_paths[*]}" "${expected_paths[*]}" "stdout paths are absolute, in order"
for path in "${stdout_paths[@]}"; do
    [[ "$path" == /* ]] || fail "stdout path is not absolute: '$path'"
    assert_file "$path"
done
assert_eq "${stdout_paths[6]}" "$OUT/SHA256SUMS" "SHA256SUMS is the last stdout path"
assert_eq "${stdout_paths[5]}" "$OUT/bootstrap.sh" "bootstrap.sh is the last published asset path"
assert_eq "${stdout_paths[4]}" "$OUT/install.sh" "install.sh precedes bootstrap.sh"
assert_eq "$(basename -- "${stdout_paths[0]}")" "${APK_NAMES[0]}" \
    "first stdout path is the universal APK"

# List file: the same seven absolute paths, SHA256SUMS last, no self-reference.
assert_file "$LIST_FILE"
assert_eq "$(wc -l <"$LIST_FILE" | tr -d ' ')" "7" "list file has seven lines"
assert_eq "$(<"$LIST_FILE")" "$(printf '%s\n' "${expected_paths[@]}")" \
    "list file has exactly the independently expected paths in order"
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
mapfile -t default_files < <(find "$TMP/out-default" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
mapfile -t expected_default_files < <(printf '%s\n' "${EXPECTED_FILES[@]}" asset-paths.txt | LC_ALL=C sort)
assert_eq "${#default_files[@]}" "8" "default out has seven assets and the service list file"
assert_eq "${default_files[*]}" "${expected_default_files[*]}" "default out has exactly the expected files"
assert_eq "$(<"$TMP/out-default/asset-paths.txt")" "$(printf '%s\n' \
    "$TMP/out-default/CSQTT-$VERSION-universal.apk" \
    "$TMP/out-default/CSQTT-$VERSION-arm64-v8a.apk" \
    "$TMP/out-default/CSQTT-$VERSION-armeabi-v7a.apk" \
    "$TMP/out-default/csqtt-linux-amd64" \
    "$TMP/out-default/install.sh" \
    "$TMP/out-default/bootstrap.sh" \
    "$TMP/out-default/SHA256SUMS")" "default list publishes only the seven assets in order"

# Reused out: remove only the two known stale ARM servers. Foreign files,
# including an APK and an unknown server-like name, must retain their bytes.
# make_tree supplies only amd64 here: absent ARM inputs must not be required.
REUSED_ROOT="$TMP/reused-root"
REUSED_OUT="$TMP/out-reused"
REUSED_LIST="$TMP/reused-asset-paths.txt"
make_tree "$REUSED_ROOT"
mkdir -p "$REUSED_OUT"
printf 'stale-arm64-output\n' >"$REUSED_OUT/csqtt-linux-arm64"
printf 'stale-armv7-output\n' >"$REUSED_OUT/csqtt-linux-armv7"
printf 'foreign-payload-must-survive\n' >"$TMP/foreign-payload"
for name in keep.txt foreign.apk csqtt-linux-other; do
    cp -- "$TMP/foreign-payload" "$REUSED_OUT/$name"
done

bash "$SUT" --root "$REUSED_ROOT" --out "$REUSED_OUT" --list-file "$REUSED_LIST" \
    >"$TMP/reused-stdout.txt" 2>"$TMP/reused-stderr.txt" || {
    sed 's/^/  | /' "$TMP/reused-stderr.txt" >&2
    fail "reused out must succeed with only amd64 input"
}
ok
[[ ! -e "$REUSED_OUT/csqtt-linux-arm64" ]] || fail "reused out retained stale arm64 server"
ok
[[ ! -e "$REUSED_OUT/csqtt-linux-armv7" ]] || fail "reused out retained stale armv7 server"
ok
for name in keep.txt foreign.apk csqtt-linux-other; do
    assert_same_bytes "$TMP/foreign-payload" "$REUSED_OUT/$name" "reused out changed foreign file $name"
done
mapfile -t reused_files < <(find "$REUSED_OUT" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
mapfile -t expected_reused_files < <(printf '%s\n' "${EXPECTED_FILES[@]}" keep.txt foreign.apk csqtt-linux-other | LC_ALL=C sort)
assert_eq "${reused_files[*]}" "${expected_reused_files[*]}" "reused out holds the release assets and untouched foreign files only"
expected_reused_paths=(
    "$REUSED_OUT/CSQTT-$VERSION-universal.apk"
    "$REUSED_OUT/CSQTT-$VERSION-arm64-v8a.apk"
    "$REUSED_OUT/CSQTT-$VERSION-armeabi-v7a.apk"
    "$REUSED_OUT/csqtt-linux-amd64"
    "$REUSED_OUT/install.sh"
    "$REUSED_OUT/bootstrap.sh"
    "$REUSED_OUT/SHA256SUMS"
)
mapfile -t reused_stdout_paths < <(grep -E "^${REUSED_OUT//./\\.}/[^/]+$" "$TMP/reused-stdout.txt")
assert_eq "${#reused_stdout_paths[@]}" "7" "reused out stdout lists seven paths"
assert_eq "${reused_stdout_paths[*]}" "${expected_reused_paths[*]}" "reused out stdout lists exactly the release paths in order"
assert_eq "$(<"$REUSED_LIST")" "$(printf '%s\n' "${expected_reused_paths[@]}")" \
    "reused out list excludes stale ARM and every foreign file"
assert_eq "$(wc -l <"$REUSED_OUT/SHA256SUMS" | tr -d ' ')" "6" "reused out SHA256SUMS has six lines"
assert_eq "$(<"$REUSED_OUT/SHA256SUMS")" "$EXPECTED_SUMS" \
    "reused out SHA256SUMS has only the six expected entries in order"
if ! (cd "$REUSED_OUT" && sha256sum -c SHA256SUMS) >"$TMP/reused-verify.txt" 2>&1; then
    sed 's/^/  | /' "$TMP/reused-verify.txt" >&2
    fail "reused out sha256sum -c SHA256SUMS failed"
fi
assert_eq "$(grep -c ': OK$' "$TMP/reused-verify.txt" || true)" "6" "reused out sha256sum -c reports six OK lines"
printf 'sha256sum -c SHA256SUMS (reused out):\n%s\n' "$(<"$TMP/reused-verify.txt")"

# --------------------------------------------------------------- negative runs

# Missing APK: exit 1, stderr names the full path.
MISSING_ROOT="$TMP/missing-apk"
make_tree "$MISSING_ROOT"
rm -f "$MISSING_ROOT/app/build/outputs/apk/release/app-$VERSION-arm64-v8a-release.apk"
expect_fail "missing arm64 APK must fail" \
    "$MISSING_ROOT/app/build/outputs/apk/release/app-$VERSION-arm64-v8a-release.apk" \
    bash "$SUT" --root "$MISSING_ROOT" --out "$TMP/out-missing-apk"

# Empty APK: exit 1, stderr names the full path.
EMPTY_APK_ROOT="$TMP/empty-apk"
make_tree "$EMPTY_APK_ROOT"
: >"$EMPTY_APK_ROOT/app/build/outputs/apk/release/app-$VERSION-universal-release.apk"
expect_fail "empty universal APK must fail" \
    "$EMPTY_APK_ROOT/app/build/outputs/apk/release/app-$VERSION-universal-release.apk" \
    bash "$SUT" --root "$EMPTY_APK_ROOT" --out "$TMP/out-empty-apk"

# Missing amd64 server: exit 1, stderr names the full path.
MISSING_BINARY_ROOT="$TMP/missing-binary"
make_tree "$MISSING_BINARY_ROOT"
rm -f "$MISSING_BINARY_ROOT/app/build/generated/assets/csqtt-linux-amd64"
expect_fail "missing csqtt-linux-amd64 must fail" \
    "$MISSING_BINARY_ROOT/app/build/generated/assets/csqtt-linux-amd64" \
    bash "$SUT" --root "$MISSING_BINARY_ROOT" --out "$TMP/out-missing-binary"

# Empty amd64 server: exit 1, stderr names the full path.
EMPTY_ROOT="$TMP/empty-binary"
make_tree "$EMPTY_ROOT"
: >"$EMPTY_ROOT/app/build/generated/assets/csqtt-linux-amd64"
expect_fail "empty csqtt-linux-amd64 must fail" \
    "$EMPTY_ROOT/app/build/generated/assets/csqtt-linux-amd64" \
    bash "$SUT" --root "$EMPTY_ROOT" --out "$TMP/out-empty-binary"

# Missing install.sh: exit 1, stderr names the full path.
MISSING_INSTALLER_ROOT="$TMP/missing-installer"
make_tree "$MISSING_INSTALLER_ROOT"
rm -f "$MISSING_INSTALLER_ROOT/scripts/install.sh"
expect_fail "missing scripts/install.sh must fail" \
    "$MISSING_INSTALLER_ROOT/scripts/install.sh" \
    bash "$SUT" --root "$MISSING_INSTALLER_ROOT" --out "$TMP/out-missing-installer"

# Missing bootstrap.sh: exit 1, stderr names the full path.
MISSING_BOOTSTRAP_ROOT="$TMP/missing-bootstrap"
make_tree "$MISSING_BOOTSTRAP_ROOT"
rm -f "$MISSING_BOOTSTRAP_ROOT/scripts/bootstrap.sh"
expect_fail "missing scripts/bootstrap.sh must fail" \
    "$MISSING_BOOTSTRAP_ROOT/scripts/bootstrap.sh" \
    bash "$SUT" --root "$MISSING_BOOTSTRAP_ROOT" --out "$TMP/out-missing-bootstrap"

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
