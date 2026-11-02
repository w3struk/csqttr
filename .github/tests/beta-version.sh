#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Секция стенда для .github/scripts/beta-version.sh.
#
# Форма строки versionName в фикстуре — как в живом app/build.gradle.kts:
# литерал первым, суффикс приклеен выражением. На этой форме держатся все
# sed-парсеры версии в репозитории.

set -euo pipefail
export LC_ALL=C

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/.github/scripts/beta-version.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
ok() {
    pass=$((pass + 1))
    printf '[OK] %s\n' "$1"
}

assert_key() {
    local out="$1" key="$2" expected="$3" msg="$4" value
    value="$(printf '%s\n' "$out" | sed -n "s/^${key}=//p" | head -n 1)"
    [[ "$value" == "$expected" ]] ||
        fail "$msg: ожидалось ${key}=${expected}, получено '${value}'"
    ok "$msg"
}

# --- изолированный репозиторий -------------------------------------------
git -c init.defaultBranch=main init -q "$TMP/repo"
mkdir -p "$TMP/repo/app"
printf 'android {\n    defaultConfig {\n        versionCode = 231\n        versionName = "2.5.1" +\n            (providers.gradleProperty("csqtt.versionSuffix").orNull ?: "")\n    }\n}\n' \
    >"$TMP/repo/app/build.gradle.kts"
git -C "$TMP/repo" -c user.email=test@example.com -c user.name=test add -A
git -C "$TMP/repo" -c user.email=test@example.com -c user.name=test commit -qm init

HEAD_SHA="$(git -C "$TMP/repo" rev-parse HEAD)"
SHORT="$(git -C "$TMP/repo" rev-parse --short=7 HEAD)"

# --- 1. базовый прогон ----------------------------------------------------
out="$("$SCRIPT" --root "$TMP/repo")"
assert_key "$out" base "2.5.1" "base из фикстуры"
assert_key "$out" commit "$HEAD_SHA" "commit = HEAD"
assert_key "$out" short "$SHORT" "short = 7 символов"
assert_key "$out" suffix "-beta.${SHORT}" "suffix"
assert_key "$out" version "2.5.1-beta.${SHORT}" "version = base-beta.short"
assert_key "$out" version-code "231" "version-code из фикстуры"

[[ ${#SHORT} -eq 7 ]] || fail "short не из 7 символов: '$SHORT'"
ok "short ровно 7 символов"

[[ "2.5.1-beta.${SHORT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9a-f]{7}$ ]] ||
    fail "version не совпадает с ожидаемой формой: '2.5.1-beta.${SHORT}'"
ok "version совпадает с ^X.Y.Z-beta.<7 hex>$"

# --- 2. ветка -------------------------------------------------------------
if ! "$SCRIPT" --root "$TMP/repo" --branch main >/dev/null; then
    fail "--branch main должен проходить"
fi
ok "--branch main разрешён"

rc=0
"$SCRIPT" --root "$TMP/repo" --branch feature/x >"$TMP/out" 2>"$TMP/err" || rc=$?
((rc != 0)) || fail "--branch feature/x должен падать"
grep -qF main "$TMP/err" || fail "сообщение об отказе не упоминает main"
ok "--branch feature/x отвергнут"

# --- 3. нет каталога ------------------------------------------------------
rc=0
"$SCRIPT" --root "$TMP/none" >"$TMP/out" 2>"$TMP/err" || rc=$?
((rc != 0)) || fail "несуществующий --root должен падать"
ok "несуществующий --root отвергнут"

# --- 4. живой репозиторий -------------------------------------------------
LIVE_BASE="$(sed -n 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$REPO_ROOT/app/build.gradle.kts" | head -n 1)"
out="$("$SCRIPT" --root "$REPO_ROOT" --branch main)"
assert_key "$out" base "$LIVE_BASE" "живой репозиторий: base совпадает с sed-парсером"

printf 'beta-version: %d assertions OK (base %s)\n' "$pass" "$LIVE_BASE"
