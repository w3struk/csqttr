#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Section test for .github/scripts/musl-zig-env.sh.
#
# The script is sourced, not executed: the test drives it from subshells with a
# fake "zig" on PATH and inspects the wrappers it generates. Everything runs
# inside mktemp -d; the working tree is never touched. Exit 0 means success.
#
# Every block that changes PATH or ZIG_SHIM_LOG runs in its own subshell on
# purpose: the changes must not leak back into this test process.

# shellcheck disable=SC2030,SC2031

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/.github/scripts/musl-zig-env.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOG="$TMP/zig.log"
export ZIG_SHIM_LOG="$LOG"
BIN="$TMP/bin"
WRAP="$TMP/wrap"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    if [[ -s "$LOG" ]]; then
        printf -- '--- zig log ---\n%s\n' "$(<"$LOG")" >&2
    fi
    exit 1
}

ok() {
    printf '[OK] %s\n' "$1"
}

expect_line() {
    local needle="$1" label="$2"
    grep -qxF -- "$needle" "$LOG" ||
        fail "$label: в логе zig нет строки '$needle'"
}

[[ -f "$SCRIPT" ]] || fail "нет скрипта $SCRIPT"

# --- Fake zig --------------------------------------------------------------

mkdir -p "$BIN"
cat >"$BIN/zig" <<'SHIM'
#!/usr/bin/env bash
# Records one line per invocation; never builds anything.
printf '%s\n' "$*" >>"${ZIG_SHIM_LOG:?}"
exit 0
SHIM
chmod +x "$BIN/zig"

# The wrappers call plain "zig" (recipe from BUILDING.md), so the shim must be
# on PATH everywhere in this test, including where wrappers are executed — not
# only inside the subshell that sources the script.
export PATH="$BIN:$PATH"

# source_env <dir> <out-file> [VAR=value ...]
# Sources the script in a subshell from <dir> and writes the exported variables
# as "NAME=value" lines to <out-file>. Extra VAR=value pairs are exported into
# the subshell first, simulating the caller's environment.
source_env() {
    local dir="$1" out="$2"
    shift 2
    (
        unset ZIG ZIG_WRAP_DIR RUNNER_TEMP CSQTT_ZIG_WRAP_DIR \
            CC_x86_64_unknown_linux_musl CXX_x86_64_unknown_linux_musl \
            AR_x86_64_unknown_linux_musl \
            CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER
        export PATH="$BIN:$PATH"
        export ZIG_SHIM_LOG="$LOG"
        if (($# > 0)); then
            for assignment in "$@"; do
                export "${assignment?}"
            done
        fi
        cd "$dir" || exit 99
        # shellcheck source=/dev/null
        source "$SCRIPT"
        printf 'CC=%s\n' "${CC_x86_64_unknown_linux_musl:-}"
        printf 'CXX=%s\n' "${CXX_x86_64_unknown_linux_musl:-}"
        printf 'AR=%s\n' "${AR_x86_64_unknown_linux_musl:-}"
        printf 'LINKER=%s\n' "${CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER:-}"
        printf 'WRAP=%s\n' "${CSQTT_ZIG_WRAP_DIR:-}"
    ) >"$out"
}

# --- 1. Wrappers call zig with the right sub-command -----------------------

mkdir -p "$WRAP"
source_env "$TMP" "$TMP/vars.txt" ZIG_WRAP_DIR="$WRAP" ||
    fail "source с шимом zig завершился с ошибкой"

CC="$(sed -n 's/^CC=//p' "$TMP/vars.txt")"
CXX="$(sed -n 's/^CXX=//p' "$TMP/vars.txt")"
AR="$(sed -n 's/^AR=//p' "$TMP/vars.txt")"
LINKER="$(sed -n 's/^LINKER=//p' "$TMP/vars.txt")"
WRAP_OUT="$(sed -n 's/^WRAP=//p' "$TMP/vars.txt")"

[[ -n "$CC" && -n "$CXX" && -n "$AR" && -n "$LINKER" && -n "$WRAP_OUT" ]] ||
    fail "не все переменные экспортированы: $(<"$TMP/vars.txt")"
ok "пять переменных экспортированы"

for path in "$CC" "$CXX" "$AR" "$LINKER"; do
    [[ -f "$path" && -x "$path" ]] || fail "переменная указывает на неисполняемый файл: $path"
done
ok "CC/CXX/AR/LINKER указывают на существующие исполняемые файлы"

[[ "$LINKER" == "$CC" ]] || fail "линкер ($LINKER) должен совпадать с zigcc ($CC)"
[[ "$(basename -- "$CC")" == "zigcc" ]] || fail "CC должен указывать на zigcc, получено $CC"
[[ "$WRAP_OUT" == "$WRAP" ]] || fail "CSQTT_ZIG_WRAP_DIR=$WRAP_OUT, ожидалось $WRAP"
ok "линкер = путь к zigcc, CSQTT_ZIG_WRAP_DIR = $WRAP"

: >"$LOG"
"$CC" --target=x86_64-unknown-linux-musl -c foo.c || fail "zigcc завершился с ошибкой"
expect_line "cc -target x86_64-linux-musl -c foo.c" "zigcc"
grep -qF 'unknown-' "$LOG" && fail "zigcc: 'unknown-' не вырезан из target"
ok "zigcc → cc, --target=x86_64-unknown-linux-musl превращён в -target x86_64-linux-musl"

: >"$LOG"
"$CXX" --target=x86_64-unknown-linux-musl -c foo.cc || fail "zigcxx завершился с ошибкой"
expect_line "c++ -target x86_64-linux-musl -c foo.cc" "zigcxx"
ok "zigcxx → c++"

: >"$LOG"
"$AR" --target=x86_64-unknown-linux-musl rcs libfoo.a foo.o || fail "zigar завершился с ошибкой"
expect_line "ar -target x86_64-linux-musl rcs libfoo.a foo.o" "zigar"
ok "zigar → ar"

# --- 2. Idempotence: a second source keeps the wrappers working ------------

cp "$CC" "$TMP/zigcc.before"
: >"$LOG"
(
    export PATH="$BIN:$PATH" ZIG_SHIM_LOG="$LOG" ZIG_WRAP_DIR="$WRAP"
    cd "$TMP" || exit 99
    # shellcheck source=/dev/null
    source "$SCRIPT"
    # shellcheck source=/dev/null
    source "$SCRIPT"
    "$CC_x86_64_unknown_linux_musl" --target=x86_64-unknown-linux-musl -c bar.c
) || fail "повторный source сломал обёртки"
expect_line "cc -target x86_64-linux-musl -c bar.c" "повторный source"
cmp -s "$TMP/zigcc.before" "$CC" || fail "повторный source перезаписал zigcc"
ok "повторный source не ломает и не перезаписывает обёртки"

# --- 3. Sourcing never kills the calling shell -----------------------------

survived="$(
    ZIG_SHIM_LOG="$LOG" ZIG_WRAP_DIR="$WRAP" PATH="$BIN:$PATH" \
        bash -c 'source "$1"; echo survived' _ "$SCRIPT"
)" || fail "source завершил вызывающий шелл с ошибкой"
[[ "$survived" == "survived" ]] ||
    fail "после source вызывающий шелл не продолжил работу (вывод: $survived)"
ok "source на успешном пути не убивает вызывающий шелл"

# --- 4. Missing zig fails the source without killing the caller ------------

missing_out="$(
    ZIG=/nonexistent/zig ZIG_WRAP_DIR="$TMP/wrap-missing" \
        bash -c 'source "$1" || echo failed; echo survived' _ "$SCRIPT" 2>"$TMP/missing.err"
)" || fail "bash -c с отсутствующим zig завершился неожиданно"
grep -qxF 'failed' <<<"$missing_out" || fail "source без zig вернул успех (вывод: $missing_out)"
grep -qxF 'survived' <<<"$missing_out" || fail "source без zig убил вызывающий шелл (вывод: $missing_out)"
[[ ! -d "$TMP/wrap-missing" ]] || fail "обёртки созданы, хотя zig не найден"
ok "без zig: source → ненулевой код, вызывающий шелл жив"

# --- 5. Result does not depend on the working directory --------------------

mkdir -p "$TMP/dir-a" "$TMP/dir-b"
source_env "$TMP/dir-a" "$TMP/vars-a.txt" ZIG_WRAP_DIR="$WRAP"
source_env "$TMP/dir-b" "$TMP/vars-b.txt" ZIG_WRAP_DIR="$WRAP"
cmp -s "$TMP/vars-a.txt" "$TMP/vars-b.txt" ||
    fail "результат зависит от рабочего каталога: $(diff -u "$TMP/vars-a.txt" "$TMP/vars-b.txt" || true)"
ok "два разных рабочих каталога → одинаковые пути и переменные"

printf 'musl-zig-env: все проверки пройдены\n'
