#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Сверяет версию во всех местах, где она продублирована.
#
# База — литерал в первой части `versionName` в app/build.gradle.kts.
# Скрипт только читает файлы, ничего не пишет и не ходит в сеть.
# При любом расхождении печатает все несовпавшие места и выходит с кодом 1.
#
#   bash scripts/check_versions.sh                    # корень = текущий каталог
#   bash scripts/check_versions.sh --root /path/repo
#   bash scripts/check_versions.sh --root . --tag v2.5.2
#
# Тег контейнерного образа сверяется в docker/compose.yml и docker/.env.example
# рядом с локальным тегом установщика (`CSQTT_DOCKER_IMAGE` в scripts/install.sh).

set -euo pipefail

ROOT="."
TAG=""

usage() {
    cat <<'EOF'
Usage: scripts/check_versions.sh [--root PATH] [--tag vX.Y.Z]

  --root PATH   каталог репозитория (по умолчанию .)
  --tag vX.Y.Z  дополнительно сверить тег релиза с versionName

Проверяет versionCode и все места, где продублирована версия:
app/build.gradle.kts, rust-client/Cargo.{toml,lock},
rust-server/Cargo.{toml,lock}, scripts/install.sh,
rust-server/main.rs, rust-server/web_panel.rs,
docker/compose.yml и docker/.env.example.
EOF
}

while (($# > 0)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "check_versions: --root требует путь" >&2; exit 2; }
            ROOT="$2"
            shift 2
            ;;
        --tag)
            [[ $# -ge 2 ]] || { echo "check_versions: --tag требует значение" >&2; exit 2; }
            TAG="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "check_versions: неизвестный аргумент: $1" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$ROOT" ]]; then
    echo "check_versions: корень не найден: $ROOT" >&2
    exit 2
fi

errors=0

fail() {
    local location="$1" expected="$2" actual="$3"
    printf 'FAIL %s: ожидалось %q, получено %q\n' "$location" "$expected" "$actual" >&2
    errors=$((errors + 1))
}

fail_missing() {
    printf 'FAIL %s: файл не найден\n' "$1" >&2
    errors=$((errors + 1))
}

require_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        fail_missing "$path"
        return 1
    fi
    return 0
}

# --- База: versionName и versionCode из Gradle ------------------------------

GRADLE="$ROOT/app/build.gradle.kts"
VERSION_NAME=""
VERSION_CODE=""
if require_file "$GRADLE"; then
    VERSION_NAME=$(sed -n 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$GRADLE" | head -n 1)
    VERSION_CODE=$(sed -n 's/^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$GRADLE" | head -n 1)
fi

if [[ -z "$VERSION_NAME" ]]; then
    echo "FAIL app/build.gradle.kts: не удалось прочитать versionName" >&2
    exit 1
fi

if [[ ! "$VERSION_CODE" =~ ^[0-9]+$ ]]; then
    fail "app/build.gradle.kts versionCode" "целое число" "${VERSION_CODE:-<пусто>}"
fi

# --- Сравнение версии в конкретном файле ------------------------------------

check_version() {
    local location="$1" actual="$2"
    if [[ "$actual" != "$VERSION_NAME" ]]; then
        fail "$location" "$VERSION_NAME" "${actual:-<пусто>}"
    fi
}

# Первое поле version в [package] Cargo.toml.
cargo_toml_version() {
    sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# Версия пакета с заданным именем в Cargo.lock.
cargo_lock_version() {
    awk -v want="$2" '
        /^\[\[package\]\]/ { matched = 0 }
        /^name = "/ {
            matched = ($0 == "name = \"" want "\"") ? 1 : 0
        }
        matched && /^version = "/ {
            line = $0
            sub(/^version = "/, "", line)
            sub(/"$/, "", line)
            print line
            exit
        }
    ' "$1"
}

# Тег контейнерного образа из строки с `recsqtt:<tag>`.
# compose:     image: ${CSQTT_IMAGE:-ghcr.io/w3struk/recsqtt:2.5.4}
# .env:        CSQTT_IMAGE=ghcr.io/w3struk/recsqtt:2.5.4
# Тег — всё после последнего `:`; у compose-формы сначала отрезается `}`.
image_tag() {
    local path="$1" line value
    # Anchor on the assignment itself: a comment or an unrelated line
    # mentioning `recsqtt:` must not satisfy the gate.
    line=$(sed -n -E 's/^[[:space:]]*image:[[:space:]]*(.*)$/\1/p;
                      s/^[[:space:]]*CSQTT_IMAGE=(.*)$/\1/p' "$path" | head -n 1)
    # Compose uses ${CSQTT_IMAGE:-...}, quoted forms are possible as well.
    value=$(printf '%s' "$line" | sed -E 's/[[:space:]]+$//; s/[}"'"'"']+$//')
    printf '%s' "${value##*:}"
}

# --- Каждое продублированное место ------------------------------------------

check_cargo_toml() {
    local path="$1"
    if require_file "$path"; then
        check_version "$path" "$(cargo_toml_version "$path")"
    fi
}

check_cargo_lock() {
    local path="$1" package="$2"
    if require_file "$path"; then
        check_version "$path ($package)" "$(cargo_lock_version "$path" "$package")"
    fi
}

check_image_tag() {
    local path="$1" label="$2"
    if require_file "$path"; then
        check_version "$label" "$(image_tag "$path")"
    fi
}

check_cargo_toml "$ROOT/rust-client/Cargo.toml"
check_cargo_lock "$ROOT/rust-client/Cargo.lock" "csqtt-client"
check_cargo_toml "$ROOT/rust-server/Cargo.toml"
check_cargo_lock "$ROOT/rust-server/Cargo.lock" "csqtt"

INSTALL_SH="$ROOT/scripts/install.sh"
if require_file "$INSTALL_SH"; then
    check_version "$INSTALL_SH SCRIPT_VERSION" \
        "$(sed -n 's/^readonly SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$INSTALL_SH" | head -n 1)"
    check_version "$INSTALL_SH CSQTT_DOCKER_IMAGE" \
        "$(sed -n 's/^readonly CSQTT_DOCKER_IMAGE="csqtt:\([^"]*\)".*/\1/p' "$INSTALL_SH" | head -n 1)"
fi

MAIN_RS="$ROOT/rust-server/main.rs"
if require_file "$MAIN_RS"; then
    check_version "$MAIN_RS (баннер)" \
        "$(sed -n 's/.* reCSQTT Server \([0-9][0-9.]*\).*/\1/p' "$MAIN_RS" | head -n 1)"
fi

WEB_PANEL="$ROOT/rust-server/web_panel.rs"
if require_file "$WEB_PANEL"; then
    check_version "$WEB_PANEL (CACHE_NAME)" \
        "$(sed -n "s/.*CACHE_NAME = 'csqtt-panel-shell-\([0-9][0-9.]*\)-pwa[0-9]*'.*/\1/p" "$WEB_PANEL" | head -n 1)"
fi

check_image_tag "$ROOT/docker/compose.yml" "docker/compose.yml (тег образа)"
check_image_tag "$ROOT/docker/.env.example" "docker/.env.example (тег образа)"

# --- Необязательный тег ------------------------------------------------------

if [[ -n "$TAG" ]]; then
    check_version "тег $TAG" "${TAG#v}"
fi

if ((errors > 0)); then
    printf 'check_versions: FAIL (%d расхождений; база %s / versionCode %s)\n' \
        "$errors" "$VERSION_NAME" "$VERSION_CODE" >&2
    exit 1
fi

printf 'check_versions: OK (%s / versionCode %s)\n' "$VERSION_NAME" "$VERSION_CODE"
