#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Отправка файла в Telegram-канал через Bot API (sendDocument).
#
# Usage:
#   telegram-send.sh --document FILE (--caption-file FILE | --caption TEXT)
#
# Окружение:
#   TELEGRAM_BOT_TOKEN   токен бота (обязателен)
#   TELEGRAM_CHAT_ID     id канала вида -100… (обязателен)
#   TELEGRAM_API_BASE    адрес API; по умолчанию прод-адрес, нужен тестам
#
# `set -x` здесь запрещён: токен живёт в URL, и трассировка вывела бы его в лог.
# `--retry` у curl не используется: POST sendDocument не идемпотентен, повтор
# отправил бы в канал второе сообщение.

set -euo pipefail

readonly MAX_DOCUMENT_BYTES=$((50 * 1024 * 1024)) # Bot API: 50 MiB (50 × 1024 × 1024 байт)
readonly MAX_CAPTION_CHARS=1024

api_base="${TELEGRAM_API_BASE:-https://api.telegram.org}"

usage() {
    cat <<'EOF'
Usage: telegram-send.sh --document FILE (--caption-file FILE | --caption TEXT)

Sends the file to the Telegram channel and prints message_id=<id> on success.
EOF
}

die() {
    printf 'telegram: %s\n' "$1" >&2
    exit 1
}

document=""
caption_file=""
caption_text=""
caption_set=0

while (($#)); do
    case "$1" in
        --document)
            document="${2:?--document requires a value}"
            shift 2
            ;;
        --document=*)
            document="${1#--document=}"
            shift
            ;;
        --caption-file)
            caption_file="${2:?--caption-file requires a value}"
            caption_set=$((caption_set + 1))
            shift 2
            ;;
        --caption-file=*)
            caption_file="${1#--caption-file=}"
            caption_set=$((caption_set + 1))
            shift
            ;;
        --caption)
            caption_text="${2:?--caption requires a value}"
            caption_set=$((caption_set + 1))
            shift 2
            ;;
        --caption=*)
            caption_text="${1#--caption=}"
            caption_set=$((caption_set + 1))
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
done

[[ -n "$document" ]] || {
    usage >&2
    exit 1
}
((caption_set == 1)) ||
    die "нужен ровно один из --caption-file и --caption"

[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || die "TELEGRAM_BOT_TOKEN не задан"
[[ -n "${TELEGRAM_CHAT_ID:-}" ]] || die "TELEGRAM_CHAT_ID не задан"
[[ -f "$document" && -s "$document" ]] || die "документ не найден или пуст: $document"

if [[ -n "$caption_file" ]]; then
    [[ -f "$caption_file" ]] || die "файл caption не найден: $caption_file"
    # Присваивание явно: ниже нужен ровно один аргумент, а не разбор по словам.
    caption="$(<"$caption_file")"
else
    caption="$caption_text"
fi

document_bytes="$(stat -c '%s' "$document")"
((document_bytes <= MAX_DOCUMENT_BYTES)) ||
    die "документ больше 50 MiB: $document_bytes байт"

caption_chars="$(printf '%s' "$caption" | wc -m)"
((caption_chars <= MAX_CAPTION_CHARS)) ||
    die "caption длиннее 1024 символов: $caption_chars"

response="$(
    curl --silent --show-error --connect-timeout 20 --max-time 300 \
        --write-out '\n%{http_code}' \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "document=@${document}" \
        --form-string "caption=${caption}" \
        "${api_base}/bot${TELEGRAM_BOT_TOKEN}/sendDocument"
)" || die "curl не смог отправить запрос"

http_code="${response##*$'\n'}"
body="${response%$'\n'*}"

error_code="$(jq -r '.error_code // "нет"' <<<"$body" 2>/dev/null || echo "нет")"
description="$(jq -r '.description // "нет описания"' <<<"$body" 2>/dev/null || echo "нет описания")"

[[ "$http_code" == "200" ]] ||
    die "Telegram API ответил HTTP $http_code (error_code=$error_code): $description"
jq -e '.ok == true' <<<"$body" >/dev/null 2>&1 ||
    die "Telegram API ответил ok=false (error_code=$error_code): $description"

printf 'message_id=%s\n' "$(jq -r '.result.message_id' <<<"$body")"
