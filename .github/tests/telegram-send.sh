#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Секция стенда для .github/scripts/telegram-send.sh.
#
# curl подменён шимом: тест не должен ходить в сеть и не должен знать
# настоящий токен. Токен в тесте синтетический — тогда `grep -F` на утечку
# честный.

set -euo pipefail
export LC_ALL=C

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/.github/scripts/telegram-send.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    [[ -s "$TMP/out" ]] && { printf -- '--- stdout ---\n%s\n' "$(<"$TMP/out")" >&2; }
    [[ -s "$TMP/err" ]] && { printf -- '--- stderr ---\n%s\n' "$(<"$TMP/err")" >&2; }
    exit 1
}
ok() {
    pass=$((pass + 1))
    printf '[OK] %s\n' "$1"
}

TOKEN='123456789:AAHtest-token-not-real'
CHAT='-1001234567890'

mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${SHIM_ARGS:?}"
cat "${SHIM_BODY:?}"
printf '\n%s' "${SHIM_CODE:-200}"
SHIM
chmod +x "$TMP/bin/curl"

printf '{"ok":true,"result":{"message_id":42,"chat":{"id":-1001234567890}}}' >"$TMP/body-ok.json"
printf '{"ok":false,"error_code":403,"description":"Forbidden: bot is not a member of the channel chat"}' >"$TMP/body-err.json"

printf 'CSQTT 2.5.1-beta.abc1234 | коммит abc1234' >"$TMP/caption.txt"
printf 'apk-bytes' >"$TMP/beta.apk"

export PATH="$TMP/bin:$PATH"
export TELEGRAM_BOT_TOKEN="$TOKEN"
export TELEGRAM_CHAT_ID="$CHAT"
export TELEGRAM_API_BASE="https://api.telegram.test"
export SHIM_ARGS="$TMP/args"
export SHIM_BODY="$TMP/body-ok.json"
export SHIM_CODE=200

run() {
    "$SCRIPT" "$@" >"$TMP/out" 2>"$TMP/err"
}

expect_fail() {
    local msg="$1" fragment="$2"
    shift 2
    local rc=0
    "$SCRIPT" "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?
    ((rc != 0)) || fail "$msg: скрипт завершился успешно"
    [[ -z "$fragment" ]] || grep -qF -- "$fragment" "$TMP/err" ||
        fail "$msg: stderr не содержит '$fragment'"
    ok "$msg"
}

# --- 1. успешная отправка -------------------------------------------------
if ! run --document "$TMP/beta.apk" --caption-file "$TMP/caption.txt"; then
    fail "успешная отправка: скрипт упал"
fi
grep -q '^message_id=42$' "$TMP/out" || fail "успех: нет message_id=42 в stdout"
ok "успех: message_id=42"

for needle in sendDocument "chat_id=${CHAT}" "document=@${TMP}/beta.apk" --form-string --silent "--connect-timeout" 20 "/bot${TOKEN}/sendDocument"; do
    grep -qF -- "$needle" "$TMP/args" || fail "успех: в аргументах curl нет '$needle'"
done
ok "успех: URL, chat_id, документ, флаги curl"

grep -q -- '^--form-string$' "$TMP/args" ||
    fail "caption отправлен не через --form-string"
grep -qF -- "caption=$(<"$TMP/caption.txt")" "$TMP/args" ||
    fail "caption не совпадает с содержимым файла"
ok "успех: caption через --form-string, без интерпретации"

for forbidden in -v --verbose -x --trace; do
    grep -qx -- "$forbidden" "$TMP/args" && fail "в аргументах есть запрещённый '$forbidden'"
done
ok "успех: трассировки в аргументах нет"

# --- 2. нет TELEGRAM_CHAT_ID ---------------------------------------------
rc=0
env -u TELEGRAM_CHAT_ID "$SCRIPT" --document "$TMP/beta.apk" --caption-file "$TMP/caption.txt" \
    >"$TMP/out" 2>"$TMP/err" || rc=$?
((rc != 0)) || fail "без TELEGRAM_CHAT_ID скрипт завершился успешно"
grep -qF 'TELEGRAM_CHAT_ID' "$TMP/err" || fail "без TELEGRAM_CHAT_ID нет сообщения про переменную"
ok "без TELEGRAM_CHAT_ID — отказ"

# --- 3. нет TELEGRAM_BOT_TOKEN, токен не утёк ----------------------------
rc=0
env -u TELEGRAM_BOT_TOKEN TELEGRAM_BOT_TOKEN= "$SCRIPT" --document "$TMP/beta.apk" \
    --caption-file "$TMP/caption.txt" >"$TMP/out" 2>"$TMP/err" || rc=$?
((rc != 0)) || fail "без TELEGRAM_BOT_TOKEN скрипт завершился успешно"
ok "без TELEGRAM_BOT_TOKEN — отказ"

# --- 4. несуществующий документ ------------------------------------------
expect_fail "несуществующий документ отвергнут" "" --document "$TMP/nope.apk" \
    --caption-file "$TMP/caption.txt"

# --- 5. документ больше 50 MiB -------------------------------------------
truncate -s $((50 * 1024 * 1024 + 1)) "$TMP/big.apk"
expect_fail "документ больше 50 MiB отвергнут" "50 MiB" --document "$TMP/big.apk" \
    --caption-file "$TMP/caption.txt"

# --- 6. caption длиннее 1024 символов ------------------------------------
python3 -c "print('x' * 1025, end='')" >"$TMP/long.txt"
expect_fail "слишком длинный caption отвергнут" "1024" --document "$TMP/beta.apk" \
    --caption-file "$TMP/long.txt"

# --- 7. спецсимволы в caption не интерпретируются ------------------------
printf 'Собрано: 12:30; @all <b>тест</b>\n' >"$TMP/special.txt"
if ! run --document "$TMP/beta.apk" --caption-file "$TMP/special.txt"; then
    fail "caption со спецсимволами: скрипт упал"
fi
grep -qF -- 'caption=Собрано: 12:30; @all <b>тест</b>' "$TMP/args" ||
    fail "caption со спецсимволами уехал искажённым"
ok "caption со спецсимволами уходит дословно"

# --- 8. ok:false / HTTP 403 ----------------------------------------------
rc=0
SHIM_BODY="$TMP/body-err.json" SHIM_CODE=403 "$SCRIPT" --document "$TMP/beta.apk" \
    --caption-file "$TMP/caption.txt" >"$TMP/out" 2>"$TMP/err" || rc=$?
((rc != 0)) || fail "ответ ok:false не привёл к отказу"
grep -qF 'Forbidden' "$TMP/err" || fail "в ошибке нет description из ответа"
grep -qF 'error_code=403' "$TMP/err" || fail "в ошибке нет error_code=403"
ok "ok:false: описание и error_code в сообщении"

grep -qF -- "$TOKEN" "$TMP/out" && fail "токен утёк в stdout"
grep -qF -- "$TOKEN" "$TMP/err" && fail "токен утёк в stderr"
ok "токен не попадает ни в stdout, ни в stderr"

# --- 9. без --document и без caption -------------------------------------
expect_fail "запуск без --document отвергнут" "" --caption-file "$TMP/caption.txt"
expect_fail "запуск без caption отвергнут" "" --document "$TMP/beta.apk"

printf 'telegram-send: %d assertions OK\n' "$pass"
