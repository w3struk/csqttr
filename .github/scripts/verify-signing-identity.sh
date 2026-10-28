#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Проверяет личность подписи релиза. Гейт тройной:
#
#   keytool ↔ scripts/release_signing_fingerprint.txt ↔ ANDROID_KEYSTORE_FINGERPRINT
#
# плюс, если переданы --apk, сверка каждого подписанного APK с отпечатком
# ключа из keystore. Сверка «keytool ↔ apksigner» сама по себе ничего не ловит
# (оба источника — один файл keystore), поэтому нужны два независимых
# ожидания: коммитируемая константа репозитория и секрет.
#
# Путь к константе репозитория — НЕ параметр: ни флага, ни переменной
# окружения для него нет. Скрипт выводит корень репозитория из собственного
# расположения, поэтому проверить подпись против произвольного файла нельзя.
#
# Пароль keystore никогда не принимается в argv: читается keytool'ом из
# переменной окружения, имя которой задаёт --storepass-env (keytool
# -storepass:env), поэтому он не всплывает в логах даже при ACTIONS_STEP_DEBUG.
#
# В stdout печатаются две машиночитаемые строки:
#   CN=<owner CN>
#   FINGERPRINT=<sha-256, uppercase, без двоеточий>
#
# Exit 0 — все сверки прошли; exit 1 — любое расхождение или ошибка формата.

set -euo pipefail

# Вывод keytool/apksigner локализуется, а парсеры ниже — английские.
export LC_ALL=C

readonly KEYTOOL='keytool'

usage() {
    cat <<'EOF'
Usage: verify-signing-identity.sh --keystore FILE --alias ALIAS [options]

Options:
  --keystore FILE              keystore to inspect (required)
  --alias ALIAS                key alias inside the keystore (required)
  --storepass-env VAR          environment variable holding the keystore
                               password (default: ANDROID_KEYSTORE_PASSWORD)
  --expected-fingerprint HEX   second opinion to compare against the
                               repository constant (usually the secret
                               ANDROID_KEYSTORE_FINGERPRINT); optional
  --apk FILE                   APK to verify; repeatable, one flag per APK
  --apksigner PATH             apksigner binary (default: apksigner from PATH)
  -h, --help                   show this help

The repository constant is always read from
<repo>/scripts/release_signing_fingerprint.txt, derived from this script's own
location. There is no flag and no environment variable for that path.
Positional arguments are rejected: pass each APK with its own --apk.

Prints:
  CN=<owner CN>
  FINGERPRINT=<sha-256, uppercase, no colons>
EOF
}

die() {
    printf 'verify-signing-identity: %s\n' "$1" >&2
    exit 1
}

# Одна и та же нормализация для всех трёх значений: без двоеточий и
# пробелов, uppercase. Поэтому форма входа не важна.
normalize() {
    tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]'
}

keytool_list() {
    "$KEYTOOL" -list -v -keystore "$KEYSTORE" -storepass:env "$STOREPASS_ENV" -alias "$ALIAS"
}

KEYSTORE=''
STOREPASS_ENV='ANDROID_KEYSTORE_PASSWORD'
ALIAS=''
EXPECTED_FP=''
EXPECTED_FP_SET=0
APKSIGNER='apksigner'
APKS=()

while (($# > 0)); do
    opt="$1"
    case "$opt" in
        -h | --help)
            usage
            exit 0
            ;;
        --keystore | --storepass-env | --alias | --apk | --apksigner | --expected-fingerprint)
            if (($# < 2)); then
                usage >&2
                die "option $opt requires a value"
            fi
            value="$2"
            case "$opt" in
                --keystore) KEYSTORE="$value" ;;
                --storepass-env) STOREPASS_ENV="$value" ;;
                --alias) ALIAS="$value" ;;
                --apk) APKS+=("$value") ;;
                --apksigner) APKSIGNER="$value" ;;
                --expected-fingerprint) EXPECTED_FP="$value"; EXPECTED_FP_SET=1 ;;
            esac
            shift 2
            ;;
        -*)
            usage >&2
            die "unknown option '$opt'"
            ;;
        *)
            # Глоб CSQTT-*.apk, переданный без --apk, развернулся бы в
            # позиционные аргументы — падать нужно здесь, до дорогой части.
            die "unexpected positional argument '$opt': pass each APK with its own --apk"
            ;;
    esac
done

# Секрет, залитый через интерактивный промпт, легко приезжает с хвостовым
# пробелом или переводом строки. keytool такой alias не найдёт, а сообщение
# получится невнятным («keytool -list failed»). Алиас не может содержать
# пробелов, поэтому обрезаем края.
ALIAS="${ALIAS#"${ALIAS%%[![:space:]]*}"}"
ALIAS="${ALIAS%"${ALIAS##*[![:space:]]}"}"

[[ -n "$KEYSTORE" ]] || {
    usage >&2
    die "--keystore is required"
}
[[ -n "$ALIAS" ]] || {
    usage >&2
    die "--alias is required"
}
[[ -n "$STOREPASS_ENV" ]] || die "--storepass-env must not be empty"

# --- 1. Константа репозитория — первой, до keytool -------------------------
# Путь не параметр: он выводится из расположения самого скрипта.
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CONST_FILE="$REPO_ROOT/scripts/release_signing_fingerprint.txt"

[[ -f "$CONST_FILE" && -r "$CONST_FILE" ]] ||
    die "repository signing fingerprint file is missing or unreadable: $CONST_FILE (commit scripts/release_signing_fingerprint.txt)"

const_nonempty_lines=$(awk 'NF { count++ } END { print count + 0 }' "$CONST_FILE")
if [[ "$const_nonempty_lines" -eq 0 ]]; then
    die "repository signing fingerprint file is empty: $CONST_FILE"
fi
if [[ "$const_nonempty_lines" -ne 1 ]]; then
    die "repository signing fingerprint file must contain exactly one non-empty line, found $const_nonempty_lines: $CONST_FILE"
fi

const_fp=$(grep -m 1 '[^[:space:]]' "$CONST_FILE" | normalize)
[[ -n "$const_fp" ]] || die "repository signing fingerprint file is empty after normalization: $CONST_FILE"

# --- 2. Отпечаток и CN из keytool -----------------------------------------
pass_value="${!STOREPASS_ENV-}"
[[ -n "$pass_value" ]] || die "keystore password environment variable '$STOREPASS_ENV' is not set or empty"
unset pass_value

if ! keytool_out=$(keytool_list); then
    # keytool печатает причину в stdout: без этого в логе остаётся только
    # «failed», и не видно, виноват пароль, алиас или сам keystore.
    printf '%s\n' "$keytool_out" >&2
    die "keytool -list failed for keystore $KEYSTORE (alias '$ALIAS')"
fi

keystore_fp=$(sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' <<<"$keytool_out" | head -n 1 | normalize)
[[ -n "$keystore_fp" ]] ||
    die "could not read the SHA256 fingerprint from keytool output (keystore: $KEYSTORE, alias: '$ALIAS')"

cn=$(sed -n 's/^Owner: CN=\([^,]*\).*/\1/p' <<<"$keytool_out" | head -n 1)
[[ -n "$cn" ]] ||
    die "could not read the certificate owner CN from keytool output (keystore: $KEYSTORE, alias: '$ALIAS')"

# --- 3. keytool ↔ константа репозитория -----------------------------------
if [[ "$keystore_fp" != "$const_fp" ]]; then
    die "keystore fingerprint does not match repository constant (keystore ↔ repository): keystore=$keystore_fp repository=$const_fp file=$CONST_FILE"
fi

# --- 4. константа ↔ секрет (второе мнение) --------------------------------
# Условие — «флаг передан», а не «значение непустое»: пустой секрет иначе
# молча отключал бы третью сверку, то есть ровно ту, ради которой он заведён.
if ((EXPECTED_FP_SET)); then
    expected_norm=$(printf '%s' "$EXPECTED_FP" | normalize)
    [[ -n "$expected_norm" ]] ||
        die "ANDROID_KEYSTORE_FINGERPRINT is empty: the secret is not set, so the secret ↔ repository check cannot run"
    if [[ "$expected_norm" != "$const_fp" ]]; then
        die "repository constant does not match ANDROID_KEYSTORE_FINGERPRINT (secret ↔ repository): repository=$const_fp secret=$expected_norm file=$CONST_FILE"
    fi
fi

# --- 5. Каждый APK ↔ отпечаток ключа из keystore --------------------------
if ((${#APKS[@]} > 0)); then
    command -v "$APKSIGNER" >/dev/null 2>&1 || [[ -x "$APKSIGNER" ]] ||
        die "apksigner not found: $APKSIGNER"

    for apk in "${APKS[@]}"; do
        [[ -f "$apk" ]] || die "APK not found: $apk"

        if ! apksigner_out=$("$APKSIGNER" verify --print-certs "$apk" 2>&1); then
            die "apksigner verify failed for APK: $apk (invalid or unreadable signature)"
        fi

        # Парсим по хвосту строки: build-tools 37.0.0 печатает
        # "V3.0 Signer: certificate SHA-256 digest: <hex>", а старые версии —
        # "Signer #1 certificate SHA-256 digest: <hex>". Парсер по префиксу
        # "Signer #1" вернул бы пустую строку, и гейт прошёл бы вхолостую.
        apk_fp=$(sed -n 's/^.*certificate SHA-256 digest:[[:space:]]*//p' <<<"$apksigner_out" | head -n 1 | normalize)
        [[ -n "$apk_fp" ]] ||
            die "could not parse the certificate SHA-256 digest from apksigner output for APK: $apk"

        if [[ "$apk_fp" != "$keystore_fp" ]]; then
            die "APK signature does not match keystore fingerprint (apk ↔ keystore): apk=$apk apk_fingerprint=$apk_fp keystore=$keystore_fp"
        fi
        printf 'APK signature verified: %s\n' "$apk"
    done
fi

# --- 6. Человекочитаемый и машиночитаемый вывод ---------------------------
printf 'Signing identity check passed.\n'
printf 'Keystore: %s (alias %s)\n' "$KEYSTORE" "$ALIAS"
printf 'Repository constant: %s\n' "$CONST_FILE"
printf 'Certificate CN: %s\n' "$cn"
printf 'Certificate SHA-256: %s\n' "$keystore_fp"
if ((${#APKS[@]} > 0)); then
    printf 'APKs verified: %d\n' "${#APKS[@]}"
fi
printf 'CN=%s\n' "$cn"
printf 'FINGERPRINT=%s\n' "$keystore_fp"
