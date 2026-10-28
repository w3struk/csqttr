#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Тест .github/scripts/release-note.sh против настоящего репозитория:
# versionName/versionCode читаются из app/build.gradle.kts тем же sed'ом, что
# и в скрипте, wire-ревизия — из rust-server/main.rs. Значения не
# хардкодятся: бамп версии не должен ломать тест.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="$REPO_ROOT/.github/scripts/release-note.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FINGERPRINT=9F2C0A1B2C3D4E5F60718293A4B5C6D7E8F90123A4B5C6D7E8F90123A4B5C6D7
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
VERSION="$(
    sed -n 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$REPO_ROOT/app/build.gradle.kts" | sed -n '1p'
)"
VERSION_CODE="$(
    sed -n 's/^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' \
        "$REPO_ROOT/app/build.gradle.kts" | sed -n '1p'
)"
WIRE_REVISION="$(
    sed -n 's/.*WIRE_PROTOCOL_REVISION[[:space:]]*:[[:space:]]*&str[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$REPO_ROOT/rust-server/main.rs" | sed -n '1p'
)"

[[ -n "$VERSION" && -n "$VERSION_CODE" && -n "$WIRE_REVISION" ]] ||
    {
        echo "FAIL: cannot read version/versionCode/WIRE_PROTOCOL_REVISION from the repository" >&2
        exit 1
    }

pass=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

ok() {
    pass=$((pass + 1))
}

# assert_line <file> <extended-regex> <message>
assert_line() {
    local file="$1" pattern="$2" msg="$3"
    if ! grep -Eq -- "$pattern" "$file"; then
        printf 'note was:\n' >&2
        sed 's/^/  | /' "$file" >&2
        fail "$msg (no line matches /$pattern/)"
    fi
    ok
}

assert_no_line() {
    local file="$1" pattern="$2" msg="$3"
    if grep -Eq -- "$pattern" "$file"; then
        fail "$msg (unexpected line matches /$pattern/)"
    fi
    ok
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$msg (expected '$expected', got '$actual')"
    ok
}

run_note() {
    local out="$1"
    shift
    bash "$SUT" \
        --root "$REPO_ROOT" \
        --tag v2.5.1 \
        --commit "$HEAD_SHA" \
        --duration-seconds 754 \
        --out "$out" \
        "$@"
}

# expect_fail <message> <expected stderr fragment> <command...>
expect_fail() {
    local msg="$1" fragment="$2"
    shift 2
    local stderr_file="$TMP/stderr.txt"
    : >"$stderr_file"
    if "$@" >/dev/null 2>"$stderr_file"; then
        fail "$msg: command unexpectedly succeeded"
    fi
    if [[ -n "$fragment" ]] && ! grep -qF -- "$fragment" "$stderr_file"; then
        printf 'stderr was:\n' >&2
        sed 's/^/  | /' "$stderr_file" >&2
        fail "$msg: stderr does not mention '$fragment'"
    fi
    ok
}

# ------------------------------------------------------------------ full note

NOTE="$TMP/note.md"
run_note "$NOTE" --fingerprint "$FINGERPRINT" --signer "Test Signer" >"$TMP/stdout.txt" ||
    fail "release-note.sh failed on a complete invocation"
ok

[[ -f "$NOTE" ]] || fail "note file was not created: $NOTE"
ok

assert_line "$NOTE" "^## CSQTT ${VERSION//./\\.}\$" "heading is the Gradle version"
assert_line "$NOTE" "^Тег: v2\.5\.1\$" "tag line"
assert_line "$NOTE" "^Версия: ${VERSION//./\\.} \(versionCode ${VERSION_CODE}\)\$" \
    "version and versionCode"
assert_line "$NOTE" "^Коммит: ${HEAD_SHA} \(${HEAD_SHA:0:7}\)\$" "commit line with short sha"
assert_line "$NOTE" '^Длительность сборки: 12m 34s$' "duration is formatted as Nm Ss"
assert_line "$NOTE" "^Wire-ревизия: ${WIRE_REVISION//./\\.}\$" "wire revision from rust-server/main.rs"
assert_line "$NOTE" "^Приложение:\$" "app section header"
assert_line "$NOTE" "^- CSQTT-${VERSION//./\\.}-universal\.apk\$" "universal APK listed"
assert_line "$NOTE" "^- CSQTT-${VERSION//./\\.}-arm64-v8a\.apk\$" "arm64 APK listed"
assert_line "$NOTE" "^- CSQTT-${VERSION//./\\.}-armeabi-v7a\.apk\$" "armeabi-v7a APK listed"
assert_line "$NOTE" '^Сервер:$' "server section header"
assert_line "$NOTE" '^- csqtt-linux-amd64$' "amd64 binary listed"
assert_line "$NOTE" '^- csqtt-linux-arm64$' "arm64 binary listed"
assert_line "$NOTE" '^- csqtt-linux-armv7$' "armv7 binary listed"
assert_line "$NOTE" '^Контрольные суммы: SHA256SUMS$' "checksums line"
assert_line "$NOTE" '^Права после скачивания: chmod \+x csqtt-linux-\*$' "chmod hint line"
assert_line "$NOTE" "^Подпись: CN=Test Signer, SHA-256 ${FINGERPRINT}\$" "signature line"

assert_eq "$(tail -n 1 "$NOTE")" '<!-- CSQTT-TECH-NOTES-END -->' \
    "last line is the tech notes marker"
assert_eq "$(cat "$NOTE")" "$(cat "$TMP/stdout.txt")" "note is echoed to stdout"

# The marker must be the marker for the last line only (one occurrence).
assert_eq "$(grep -cF -- '<!-- CSQTT-TECH-NOTES-END -->' "$NOTE")" "1" \
    "marker appears exactly once"

# ------------------------------------------------------------ duration corners

run_note "$TMP/59.md" --duration-seconds 59 >/dev/null
assert_line "$TMP/59.md" '^Длительность сборки: 0m 59s$' "59 seconds"
assert_no_line "$TMP/59.md" '^Подпись:' "no signature line without signer/fingerprint"
assert_eq "$(tail -n 1 "$TMP/59.md")" '<!-- CSQTT-TECH-NOTES-END -->' \
    "marker stays last without a signature line"

run_note "$TMP/3600.md" --duration-seconds 3600 >/dev/null
assert_line "$TMP/3600.md" '^Длительность сборки: 60m 0s$' "3600 seconds"

# -------------------------------------------------------- optional overrides

run_note "$TMP/wire.md" --duration-seconds 1 --wire-revision CSQTT-WIRE-9 >/dev/null
assert_line "$TMP/wire.md" '^Wire-ревизия: CSQTT-WIRE-9$' "--wire-revision overrides the source"
assert_line "$TMP/wire.md" '^Длительность сборки: 0m 1s$' "1 second"

# Only one half of the signature pair is not enough for the signature line.
run_note "$TMP/signer-only.md" --duration-seconds 1 --signer "Test Signer" >/dev/null
assert_no_line "$TMP/signer-only.md" '^Подпись:' "--signer alone prints no signature line"
run_note "$TMP/fp-only.md" --duration-seconds 1 --fingerprint "$FINGERPRINT" >/dev/null
assert_no_line "$TMP/fp-only.md" '^Подпись:' "--fingerprint alone prints no signature line"

# --------------------------------------------------------------- negative runs

expect_fail "missing --tag must fail with usage" "Usage:" \
    bash "$SUT" --root "$REPO_ROOT" --commit "$HEAD_SHA" \
    --duration-seconds 754 --out "$TMP/no-tag.md"

expect_fail "missing --commit must fail" "--commit is required" \
    bash "$SUT" --root "$REPO_ROOT" --tag v2.5.1 \
    --duration-seconds 754 --out "$TMP/no-commit.md"

expect_fail "missing --root must fail" "--root is required" \
    bash "$SUT" --tag v2.5.1 --commit "$HEAD_SHA" \
    --duration-seconds 754 --out "$TMP/no-root.md"

expect_fail "missing --duration-seconds must fail" "--duration-seconds is required" \
    bash "$SUT" --root "$REPO_ROOT" --tag v2.5.1 --commit "$HEAD_SHA" \
    --out "$TMP/no-duration.md"

expect_fail "missing --out must fail" "--out is required" \
    bash "$SUT" --root "$REPO_ROOT" --tag v2.5.1 --commit "$HEAD_SHA" \
    --duration-seconds 754

expect_fail "unknown flag must fail with usage" "Usage:" \
    bash "$SUT" --root "$REPO_ROOT" --tag v2.5.1 --commit "$HEAD_SHA" \
    --duration-seconds 754 --out "$TMP/unknown.md" --no-such-flag

expect_fail "non-numeric duration must fail" "duration" \
    bash "$SUT" --root "$REPO_ROOT" --tag v2.5.1 --commit "$HEAD_SHA" \
    --duration-seconds 12m --out "$TMP/bad-duration.md"

expect_fail "missing gradle file must fail" "build.gradle.kts" \
    bash "$SUT" --root "$TMP" --tag v2.5.1 --commit "$HEAD_SHA" \
    --duration-seconds 754 --out "$TMP/no-gradle.md"

# Gradle file without versionName/versionCode: exit 1, no note.
PARTIAL_ROOT="$TMP/partial"
mkdir -p "$PARTIAL_ROOT/app" "$PARTIAL_ROOT/rust-server"
printf 'android {\n}\n' >"$PARTIAL_ROOT/app/build.gradle.kts"
expect_fail "versionName missing must fail" "versionName" \
    bash "$SUT" --root "$PARTIAL_ROOT" --tag v2.5.1 --commit "$HEAD_SHA" \
    --duration-seconds 754 --out "$TMP/no-version.md"

# rust-server/main.rs missing and no --wire-revision: exit 1, names the source.
printf 'android {\n    versionCode = 7\n    versionName = "1.0.0"\n}\n' \
    >"$PARTIAL_ROOT/app/build.gradle.kts"
expect_fail "wire revision source missing must fail" "rust-server/main.rs" \
    bash "$SUT" --root "$PARTIAL_ROOT" --tag v2.5.1 --commit "$HEAD_SHA" \
    --duration-seconds 754 --out "$TMP/no-wire.md"

# ... and --wire-revision makes the same tree usable.
bash "$SUT" --root "$PARTIAL_ROOT" --tag v2.5.1 --commit "$HEAD_SHA" \
    --duration-seconds 754 --wire-revision CSQTT-WIRE-3 --out "$TMP/partial.md" >/dev/null ||
    fail "explicit --wire-revision must not need rust-server/main.rs"
ok
assert_line "$TMP/partial.md" '^## CSQTT 1\.0\.0$' "version from the partial Gradle file"
assert_line "$TMP/partial.md" '^Версия: 1\.0\.0 \(versionCode 7\)$' "versionCode from the partial Gradle file"

# A failed run must not leave a note behind for the publish step to upload.
[[ ! -f "$TMP/no-gradle.md" ]] || fail "failed run left a note file behind"
ok

printf 'release-note: %d assertions OK (version %s, versionCode %s, %s)\n' \
    "$pass" "$VERSION" "$VERSION_CODE" "$WIRE_REVISION"
