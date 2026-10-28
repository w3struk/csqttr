#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Section test for .github/scripts/verify-signing-identity.sh.
#
# keytool is real (a throw-away keystore is generated under mktemp -d).
# apksigner is a shim that can print either the legacy "Signer #1 ..." digest
# line or the real build-tools 37.0.0 "V3.0 Signer: ..." line, and can be told
# to fail or to print an empty digest.
#
# The script under test derives the repository constant from its own location,
# so every run uses a COPY of the script inside a sandbox repository
# ($TMP/repo/...). The real scripts/release_signing_fingerprint.txt is never
# modified; its sha256 is asserted unchanged at the end.

set -euo pipefail
export LC_ALL=C

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/.github/scripts/verify-signing-identity.sh"
REAL_CONST="$REPO_ROOT/scripts/release_signing_fingerprint.txt"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/stdout.txt"
ERR="$TMP/stderr.txt"
STATUS=0

before_real_const=$(sha256sum "$REAL_CONST" | awk '{ print $1 }')

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    if [[ -s "$OUT" ]]; then
        printf -- '--- stdout ---\n%s\n' "$(<"$OUT")" >&2
    fi
    if [[ -s "$ERR" ]]; then
        printf -- '--- stderr ---\n%s\n' "$(<"$ERR")" >&2
    fi
    exit 1
}

ok() {
    printf '[OK] %s\n' "$1"
}

skip() {
    printf '[SKIP] %s\n' "$1"
}

# --- keystore and fingerprint ----------------------------------------------
KEYSTORE="$TMP/t.jks"
KEYSTORE_PASS='changeit'

keytool -genkeypair -keystore "$KEYSTORE" -storepass "$KEYSTORE_PASS" \
    -keypass "$KEYSTORE_PASS" -alias test -keyalg RSA -keysize 2048 \
    -dname 'CN=Test Signer' >/dev/null 2>&1 ||
    fail "keytool -genkeypair не создал тестовый keystore"

FP=$(keytool -list -v -keystore "$KEYSTORE" -storepass "$KEYSTORE_PASS" -alias test |
    sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' | head -n 1 | tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]')
[[ "$FP" =~ ^[0-9A-F]{64}$ ]] || fail "не удалось прочитать SHA256 тестового keystore (получено '$FP')"
ok "тестовый keystore: $FP"

COLON_FP=$(printf '%s' "$FP" | sed 's/../&:/g; s/:$//')
LOWER_COLON_FP=$(printf '%s' "$COLON_FP" | tr '[:upper:]' '[:lower:]')
ZERO_FP=$(printf '0%.0s' {1..64})
OTHER_FP=$(printf 'A%.0s' {1..64})

# --- sandbox repository with a copy of the script and a constant -----------
mkdir -p "$TMP/repo/.github/scripts" "$TMP/repo/scripts" "$TMP/bin"
cp "$SCRIPT" "$TMP/repo/.github/scripts/verify-signing-identity.sh"
SUT="$TMP/repo/.github/scripts/verify-signing-identity.sh"
CONST="$TMP/repo/scripts/release_signing_fingerprint.txt"

set_const() {
    printf '%s\n' "$1" >"$CONST"
}

set_const "$FP"

# --- apksigner shim --------------------------------------------------------
cat >"$TMP/bin/apksigner" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
apk="${!#}"
case "${APKSIGNER_MODE:-ok}" in
    fail) exit 2 ;;
    empty) printf 'V3.0 Signer: certificate SHA-256 digest: \n'; exit 0 ;;
    # Only the APK named in APKSIGNER_BAD_APK carries the foreign digest, so a
    # run with several --apk fails on that one file and names it.
    other)
        if [[ "$apk" == "${APKSIGNER_BAD_APK:-}" ]]; then
            printf 'V3.0 Signer: certificate SHA-256 digest: %s\n' "${APKSIGNER_OTHER_FP}"
            exit 0
        fi
        ;;
esac
case "${APKSIGNER_FIXTURE:-real}" in
    old) printf 'Signer #1 certificate SHA-256 digest: %s\n' "${APKSIGNER_FP}" ;;
    real) printf 'V3.0 Signer: certificate SHA-256 digest: %s\n' "${APKSIGNER_FP}" ;;
    *) exit 3 ;;
esac
SHIM
chmod +x "$TMP/bin/apksigner"

# --- APK fixtures: the script only requires readable files -----------------
for name in a b c bad; do
    printf 'not really an apk: %s\n' "$name" >"$TMP/$name.apk"
done

# --- runner ---------------------------------------------------------------
# run_sut [VAR=value ...] -- <script args>
run_sut() {
    local -a env_pairs=()
    while (($# > 0)) && [[ "$1" != "--" ]]; do
        env_pairs+=("$1")
        shift
    done
    (($# > 0)) && shift

    set +e
    env PATH="$TMP/bin:$PATH" KEYSTORE_PASS="$KEYSTORE_PASS" \
        APKSIGNER_FP="$COLON_FP" APKSIGNER_OTHER_FP="$OTHER_FP" \
        "${env_pairs[@]}" \
        bash "$SUT" "$@" >"$OUT" 2>"$ERR"
    STATUS=$?
    set -e
}

expect_status() {
    local want="$1" label="$2"
    [[ "$STATUS" -eq "$want" ]] ||
        fail "$label: ожидался exit $want, получен exit $STATUS"
}

expect_stderr() {
    local needle="$1" label="$2"
    grep -qF -- "$needle" "$ERR" || fail "$label: в stderr нет '$needle'"
}

expect_stdout() {
    local needle="$1" label="$2"
    grep -qF -- "$needle" "$OUT" || fail "$label: в stdout нет '$needle'"
}

BASE_ARGS=(--keystore "$KEYSTORE" --storepass-env KEYSTORE_PASS --alias test)

# --- 1. positives: all three values agree, both apksigner formats ----------
for fixture in old real; do
    set_const "$FP"
    run_sut "APKSIGNER_FIXTURE=$fixture" -- "${BASE_ARGS[@]}" \
        --expected-fingerprint "$FP" \
        --apk "$TMP/a.apk" --apk "$TMP/b.apk" --apk "$TMP/c.apk"
    expect_status 0 "позитив (формат $fixture, три --apk)"
    expect_stdout "CN=Test Signer" "позитив (формат $fixture)"
    expect_stdout "FINGERPRINT=$FP" "позитив (формат $fixture)"
    ok "позитив: формат apksigner '$fixture', три --apk"
done

# Lowercase + colons in --expected-fingerprint must normalize to the same value.
set_const "$FP"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" \
    --expected-fingerprint "$LOWER_COLON_FP" --apk "$TMP/a.apk"
expect_status 0 "позитив: --expected-fingerprint в нижнем регистре и с двоеточиями"
ok "позитив: нормализация --expected-fingerprint"

# A lowercase/colon-form constant in the file must also normalize.
set_const "$LOWER_COLON_FP"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint "$FP"
expect_status 0 "позитив: константа в нижнем регистре и с двоеточиями"
ok "позитив: нормализация константы репозитория"

# No --apk at all: keytool-only mode (used before the build).
set_const "$FP"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint "$FP"
expect_status 0 "позитив: без --apk (keytool-часть до сборки)"
ok "позитив: режим без --apk"

# --- 2. negative A: repository constant != keytool -------------------------
set_const "$ZERO_FP"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint "$FP"
expect_status 1 "негатив A (keystore ↔ repository)"
expect_stderr "keystore ↔ repository" "негатив A"
expect_stderr "$CONST" "негатив A (путь к файлу константы)"
ok "негатив A: константа репозитория ≠ keytool"

# --- 3. negative B: secret != repository constant --------------------------
set_const "$FP"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint "$ZERO_FP"
expect_status 1 "негатив B (secret ↔ repository)"
expect_stderr "secret ↔ repository" "негатив B"
ok "негатив B: секрет ≠ константа репозитория"

# --- 4. negative C: constant file missing ---------------------------------
set_const "$FP"
rm -f "$CONST"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint "$FP"
expect_status 1 "негатив C (файла константы нет)"
expect_stderr "$CONST" "негатив C (путь к файлу константы)"
if ! grep -qE 'missing|unreadable' "$ERR"; then
    fail "негатив C: в stderr нет 'missing'/'unreadable'"
fi
ok "негатив C: файл константы отсутствует"

# --- 5. negative D: constant file empty / whitespace only -----------------
: >"$CONST"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint "$FP"
expect_status 1 "негатив D (пустой файл константы)"
expect_stderr "empty" "негатив D"
expect_stderr "$CONST" "негатив D (путь к файлу константы)"
ok "негатив D: пустой файл константы"

printf '   \n\t\n' >"$CONST"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint "$FP"
expect_status 1 "негатив D (файл из одних пробелов)"
expect_stderr "empty" "негатив D (пробелы)"
ok "негатив D: файл из одних пробелов"

# --- 6. negative D2: constant file with two lines -------------------------
printf '%s\n%s\n' "$FP" "$OTHER_FP" >"$CONST"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint "$FP"
expect_status 1 "негатив D2 (две строки в файле константы)"
expect_stderr "exactly one non-empty line" "негатив D2"
expect_stderr "$CONST" "негатив D2 (путь к файлу константы)"
ok "негатив D2: две строки в файле константы"

# --- 7. negative E: constant file unreadable ------------------------------
if [[ "$EUID" -ne 0 ]]; then
    set_const "$FP"
    chmod 000 "$CONST"
    run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint "$FP"
    chmod 644 "$CONST"
    expect_status 1 "негатив E (файл константы нечитаем)"
    expect_stderr "$CONST" "негатив E (путь к файлу константы)"
    ok "негатив E: файл константы нечитаем"
else
    skip "негатив E: под root -r всегда истинно, тест был бы ложноположительным"
fi

# --- 8. negative F: an APK signed with a different digest -----------------
set_const "$FP"
run_sut "APKSIGNER_FIXTURE=real" "APKSIGNER_MODE=other" "APKSIGNER_BAD_APK=$TMP/bad.apk" -- \
    "${BASE_ARGS[@]}" --expected-fingerprint "$FP" --apk "$TMP/a.apk" --apk "$TMP/bad.apk"
expect_status 1 "негатив F (APK с другим дайджестом)"
expect_stderr "$TMP/bad.apk" "негатив F (имя APK в сообщении)"
ok "негатив F: APK с другим дайджестом"

# --- 9. negative G: apksigner reports an invalid signature ----------------
set_const "$FP"
run_sut "APKSIGNER_FIXTURE=real" "APKSIGNER_MODE=fail" -- "${BASE_ARGS[@]}" \
    --expected-fingerprint "$FP" --apk "$TMP/a.apk"
expect_status 1 "негатив G (apksigner exit 2)"
expect_stderr "$TMP/a.apk" "негатив G (имя APK в сообщении)"
ok "негатив G: apksigner вернул ошибку"

# --- 10. negative H: empty digest from apksigner --------------------------
set_const "$FP"
run_sut "APKSIGNER_FIXTURE=real" "APKSIGNER_MODE=empty" -- "${BASE_ARGS[@]}" \
    --expected-fingerprint "$FP" --apk "$TMP/a.apk"
expect_status 1 "негатив H (пустой дайджест)"
expect_stderr "could not parse the certificate SHA-256 digest" "негатив H"
expect_stderr "$TMP/a.apk" "негатив H (имя APK в сообщении)"
ok "негатив H: пустой дайджест из apksigner — падение, а не no-op"

# --- 11. negative I: positional argument instead of --apk -----------------
set_const "$FP"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint "$FP" "$TMP/a.apk"
expect_status 1 "негатив I (позиционный аргумент)"
expect_stderr "positional argument" "негатив I"
expect_stderr "--apk" "негатив I (подсказка про --apk)"
ok "негатив I: позиционный аргумент отвергнут"

# --- 12. negative J: unknown flag and missing required options ------------
set_const "$FP"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --bogus value
expect_status 1 "негатив J (неизвестный флаг)"
expect_stderr "unknown option" "негатив J"
ok "негатив J: неизвестный флаг отвергнут"

run_sut "APKSIGNER_FIXTURE=real" -- --keystore "$KEYSTORE" --alias test
expect_status 1 "негатив J (не задан --storepass-env → переменная не найдена)"
ok "негатив J: незаданная переменная пароля отвергнута"

# --- 14. alias с пробелами по краям (реальный инцидент в CI) --------------
# Секрет, залитый через интерактивный промпт, приехал как "csqtt_release_key ",
# и keytool не нашёл алиас. Скрипт обязан обрезать края, а не падать.
set_const "$FP"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --alias " test  " \
    --expected-fingerprint "$FP"
expect_status 0 "алиас с пробелами по краям должен обрезаться и находиться"
expect_stdout "CN=Test Signer" "алиас с пробелами: CN из keytool"
ok "алиас с пробелами по краям обрезается"

# --- 15. пустой секрет отпечатка обязан падать, а не отключать сверку -----
# Ровно этот случай был в CI: ANDROID_KEYSTORE_FINGERPRINT пуст, и раньше
# третья сверка (константа репозитория ↔ секрет) молча пропускалась.
set_const "$FP"
run_sut "APKSIGNER_FIXTURE=real" -- "${BASE_ARGS[@]}" --expected-fingerprint ""
expect_status 1 "пустой --expected-fingerprint обязан падать"
expect_stderr "ANDROID_KEYSTORE_FINGERPRINT is empty" "пустой секрет отпечатка"
ok "пустой секрет отпечатка — падение, а не молчаливое отключение сверки"

# --- 16. real repository constant: format and untouched -------------------
line_count=$(wc -l <"$REAL_CONST")
[[ "$line_count" -eq 1 ]] ||
    fail "scripts/release_signing_fingerprint.txt: ожидалась ровно 1 строка, найдено $line_count"
real_value=$(tr -d '\n' <"$REAL_CONST")
[[ "$real_value" =~ ^[0-9A-F]{64}$ ]] ||
    fail "scripts/release_signing_fingerprint.txt: ожидалось 64 hex-символа uppercase, получено '$real_value'"
after_real_const=$(sha256sum "$REAL_CONST" | awk '{ print $1 }')
[[ "$before_real_const" == "$after_real_const" ]] ||
    fail "тест изменил настоящий scripts/release_signing_fingerprint.txt"
ok "настоящий scripts/release_signing_fingerprint.txt: формат верен и не изменён"

printf 'гейт подписи: все проверки пройдены\n'
