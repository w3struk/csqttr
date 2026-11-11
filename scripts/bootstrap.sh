#!/bin/bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Тонкий вход установки: скачивает install.sh и SHA256SUMS последнего (или
# указанного) релиза, сверяет SHA-256 установщика и запускает его с
# проброшенными аргументами. install.sh (262 КБ) не влезает в
# `bash -c "$(curl …)"` из-за MAX_ARG_STRLEN в 128 КиБ, поэтому в one-liner'е
# живёт этот файл. CSQTT_RELEASE_BASE переопределяет базу релизов (тесты).

set -Eeuo pipefail

CSQTT_RELEASE_BASE="${CSQTT_RELEASE_BASE:-https://github.com/w3struk/csqttr}"
readonly EXIT_INVALID_ARGUMENT=2
readonly EXIT_PREFLIGHT_FAILED=20
readonly CURL_OPTS=(-fsSL --retry 3 --connect-timeout 10)

usage() {
    cat <<'EOF'
Usage: bootstrap.sh [--version <vX.Y.Z>] [install.sh arguments...]

Downloads install.sh and SHA256SUMS from the CSQTT release, verifies the
SHA-256 of the installer and runs it with the remaining arguments.

  --version <vX.Y.Z>  pin the release (default: the latest release)
  -h, --help          show this help and exit
  --                  stop option parsing; forward the rest to install.sh

Every other argument (--yes, --check, --mode docker, --host, ...) is passed
to install.sh unchanged. CSQTT_RELEASE_BASE overrides the release base URL.
EOF
}

die() {
    printf 'CSQTT bootstrap: %s\n' "$1" >&2
    exit "${2:-$EXIT_PREFLIGHT_FAILED}"
}

validate_tag() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "некорректный тег релиза: '$1' (ожидается vX.Y.Z)" "$EXIT_INVALID_ARGUMENT"
}

version=""
pinned=0
forward=()
while (($#)); do
    case "$1" in
        --version)
            (($# >= 2)) || die "--version требует значение vX.Y.Z" "$EXIT_INVALID_ARGUMENT"
            version="$2"
            pinned=1
            shift 2
            ;;
        --version=*)
            version="${1#--version=}"
            pinned=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            forward+=("$@")
            break
            ;;
        *)
            forward+=("$1")
            shift
            ;;
    esac
done

base="${CSQTT_RELEASE_BASE%/}"

# Минимальные системы (Debian minimal, контейнеры) часто приходят без curl, но
# с wget. Проверяем загрузчик до первого запроса: иначе пользователь увидит
# «curl: command not found» вместо того, что нужно сделать.
downloader=""
if command -v curl >/dev/null 2>&1; then
    downloader="curl"
elif command -v wget >/dev/null 2>&1; then
    downloader="wget"
else
    die "нужен curl или wget: apt-get update && apt-get install -y curl ca-certificates" \
        "$EXIT_PREFLIGHT_FAILED"
fi
command -v sha256sum >/dev/null 2>&1 ||
    die "нужен sha256sum (coreutils) для проверки установщика" "$EXIT_PREFLIGHT_FAILED"

# fetch <url> <dest> — единственное место, где bootstrap ходит в сеть.
fetch() {
    local url="$1" dest="$2"
    case "$downloader" in
        curl) curl "${CURL_OPTS[@]}" -o "$dest" "$url" ;;
        wget) wget -q --tries=3 --timeout=10 -O "$dest" "$url" ;;
    esac
}

if ((pinned)); then
    validate_tag "$version"
    release_url="${base}/releases/download/${version}"
else
    # GitHub отдаёт /releases/latest/download/<asset> редиректом на актуальный
    # тег, поэтому отдельный HEAD-запрос не нужен и wget-путь не требует
    # разбора заголовков. Точный тег нужен только для сообщения.
    release_url="${base}/releases/latest/download"
    if [[ "$downloader" == "curl" ]]; then
        effective="$(curl "${CURL_OPTS[@]}" -I -o /dev/null -w '%{url_effective}' \
            "${base}/releases/latest" 2>/dev/null || true)"
        case "$effective" in
            */tag/*) version="${effective##*/tag/}" ;;
            *) version="" ;;
        esac
        version="${version%%[?#]*}"
        version="${version%/}"
    fi
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/csqtt-bootstrap.XXXXXX")" ||
    die "не удалось создать временный каталог"
trap 'rm -rf -- "$work_dir"' EXIT

# Причины отказа различаются: иначе пользователь видит одно «не удалось скачать»
# и для 404, и для отсутствующих корневых сертификатов, и для DNS. Коды curl и
# wget для этих случаев стабильны: TLS — 60/5, HTTP-ошибка — 22/8.
fetch_failure_hint() {
    local asset="$1" rc="$2"
    case "${downloader}:${rc}" in
        curl:60 | wget:5)
            printf 'TLS: нет доверенных корневых сертификатов для %s. Установите: apt-get update && apt-get install -y ca-certificates' "$release_url"
            ;;
        curl:22 | wget:8)
            printf '%s: HTTP-ошибка %s — ассет не найден в %s (возможно, релиз ещё публикуется)' "$asset" "$rc" "$release_url"
            ;;
        curl:6 | wget:4)
            printf '%s: сеть недоступна, не удаётся разрешить или достичь %s (%s, код %s)' "$asset" "$release_url" "$downloader" "$rc"
            ;;
        *)
            printf '%s: не удалось скачать из %s (%s, код %s)' "$asset" "$release_url" "$downloader" "$rc"
            ;;
    esac
}

for asset in install.sh SHA256SUMS; do
    rc=0
    fetch "${release_url}/${asset}" "${work_dir}/${asset}" || rc=$?
    ((rc == 0)) || die "$(fetch_failure_hint "$asset" "$rc")" "$EXIT_PREFLIGHT_FAILED"
    [[ -s "${work_dir}/${asset}" ]] || die "скачанный ${asset} пуст" "$EXIT_PREFLIGHT_FAILED"
done

expected="$(awk '$2 == "install.sh" || $2 == "*install.sh" { print $1; exit }' \
    "${work_dir}/SHA256SUMS")"
[[ -n "$expected" ]] || die "в SHA256SUMS нет записи для install.sh" "$EXIT_PREFLIGHT_FAILED"
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "в SHA256SUMS некорректный SHA-256 для install.sh: ${expected}" "$EXIT_PREFLIGHT_FAILED"
actual="$(sha256sum -- "${work_dir}/install.sh" | awk '{print $1}')"
[[ "${actual,,}" == "${expected,,}" ]] ||
    die "несовпадение SHA-256 для install.sh: ожидалось ${expected}, получено ${actual}" \
        "$EXIT_PREFLIGHT_FAILED"

if ((pinned)); then
    label="$version"
elif [[ -n "$version" ]]; then
    label="(последний релиз ${version})"
else
    label="(последний релиз)"
fi
printf 'CSQTT bootstrap: запуск install.sh %s\n' "$label"

status=0
if ((pinned)); then
    bash "${work_dir}/install.sh" --version "$version" "${forward[@]}" || status=$?
else
    bash "${work_dir}/install.sh" "${forward[@]}" || status=$?
fi
exit "$status"
