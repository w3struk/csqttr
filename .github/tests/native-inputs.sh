#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Контракт единого списка нативных входов: rust-client/native-inputs.txt —
# единственный источник правды для Gradle-входов и provenance-хеша. Тест не
# собирает нативную часть: он проверяет сам список и его потребителей.

set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$REPO_ROOT/rust-client/native-inputs.txt"
GRADLE="$REPO_ROOT/app/build.gradle.kts"
PROVENANCE="$REPO_ROOT/scripts/native_client_provenance.sh"

pass=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
ok() { pass=$((pass + 1)); }

[[ -f "$MANIFEST" ]] || fail "missing native inputs manifest: $MANIFEST"
ok

[[ -f "$GRADLE" ]] || fail "missing $GRADLE"
[[ -f "$PROVENANCE" ]] || fail "missing $PROVENANCE"

# Оба потребителя обязаны читать один и тот же манифест.
grep -qF 'rust-client/native-inputs.txt' "$GRADLE" ||
    fail "app/build.gradle.kts does not read rust-client/native-inputs.txt"
ok
grep -qF 'rust-client/native-inputs.txt' "$PROVENANCE" ||
    fail "native_client_provenance.sh does not read rust-client/native-inputs.txt"
ok

# Мёртвые записи, из-за которых список раньше расходился с реальностью.
if grep -qE '(^|[[:space:]])domains\.txt$' "$MANIFEST"; then
    fail "manifest still lists the removed domains.txt"
fi
if grep -qF '.cargo/config.toml' "$MANIFEST"; then
    fail "manifest lists a cargo config that does not exist"
fi
if grep -qF 'rust-client/.cargo/**' "$MANIFEST"; then
    fail "manifest lists rust-client/.cargo/** although the directory is absent"
fi
ok

# Каждая не-glob запись обязана существовать, а glob — что-то находить, если он
# не `<dir>/**`: иначе вход молча выпадает из хеша.
shopt -s nullglob globstar
count=0
while IFS= read -r line || [[ -n "$line" ]]; do
    pattern="${line%%#*}"
    pattern="$(printf '%s' "$pattern" | tr -d '[:space:]')"
    [[ -n "$pattern" ]] || continue
    count=$((count + 1))
    matches=0
    for path in "$REPO_ROOT"/$pattern; do
        [[ -f "$path" ]] || continue
        [[ "$path" == */target/* ]] && continue
        matches=$((matches + 1))
    done
    if [[ "$matches" -eq 0 ]] && [[ "$pattern" != *'**'* ]]; then
        fail "manifest entry matched nothing: $pattern"
    fi
done <"$MANIFEST"
shopt -u nullglob globstar
[[ "$count" -ge 10 ]] || fail "manifest looks truncated: only $count entries"
ok

# Манифест обязан попадать во входы Gradle и в хеш: иначе его правка ничего не
# инвалидирует.
grep -qF 'include("rust-client/native-inputs.txt")' "$GRADLE" ||
    fail "Gradle inputs do not include the manifest itself"
ok
grep -qF 'rust-client/native-inputs.txt' "$PROVENANCE" ||
    fail "provenance does not hash the manifest itself"
ok

# Клиент обязан объявлять per-ABI outputs и падать на лишних ABI в jniLibs.
grep -qF 'outputs.files(' "$GRADLE" ||
    fail "build task still declares outputs.dir instead of per-ABI files"
if grep -qF 'outputs.dir(jniLibsDir' "$GRADLE"; then
    fail "build task still declares outputs.dir(jniLibsDir(...))"
fi
ok
grep -qF 'ABIs do not match the requested set' "$PROVENANCE" ||
    fail "provenance has no client ABI count check"
ok
grep -qF 'cleanStaleNativeLibs' "$GRADLE" ||
    fail "Gradle has no stale native library cleanup"
ok

printf 'native-inputs: %d assertions OK\n' "$pass"
