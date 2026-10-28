#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Локальный стенд релизного CI.
#
# Каждая секция — самостоятельный скрипт в .github/tests/<name>.sh:
# exit 0 — успех, ненулевой код — провал с сообщением в stderr.
# Диспетчер ничего не знает про содержимое секций: он их находит, запускает
# и собирает сводку. Секции обязаны писать только во временные каталоги
# (mktemp -d) и не трогать рабочее дерево.
#
#   bash .github/scripts/test-local.sh                 # все секции
#   bash .github/scripts/test-local.sh resolve-release-target   # одна секция
#   bash .github/scripts/test-local.sh list            # список секций
#   bash .github/scripts/test-local.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/.github/tests"

usage() {
    cat <<EOF
Usage: $(basename -- "$0") [section|all|list]

section  имя файла секции без расширения (например resolve-release-target)
all      все секции из .github/tests/*.sh (по умолчанию)
list     показать доступные секции
EOF
}

case "${1:-all}" in
    -h | --help)
        usage
        exit 0
        ;;
    list)
        shopt -s nullglob
        for script in "$TESTS_DIR"/*.sh; do
            basename -- "$script" .sh
        done
        exit 0
        ;;
esac

if [[ ! -d "$TESTS_DIR" ]]; then
    echo "Каталог тестов не найден: $TESTS_DIR" >&2
    exit 1
fi

shopt -s nullglob
if [[ "${1:-all}" == "all" ]]; then
    mapfile -t sections < <(
        for script in "$TESTS_DIR"/*.sh; do
            basename -- "$script" .sh
        done | LC_ALL=C sort
    )
else
    sections=("$1")
fi

if ((${#sections[@]} == 0)); then
    echo "Нет секций в $TESTS_DIR" >&2
    exit 1
fi

failed=()
for section in "${sections[@]}"; do
    script="$TESTS_DIR/$section.sh"
    if [[ ! -f "$script" ]]; then
        echo "FAIL $section (нет файла $script)" >&2
        failed+=("$section")
        continue
    fi
    echo "=== $section ==="
    if bash "$script"; then
        echo "PASS $section"
    else
        code=$?
        echo "FAIL $section (exit $code)" >&2
        failed+=("$section")
    fi
done

if ((${#failed[@]} > 0)); then
    printf 'FAILED: %s\n' "${failed[*]}" >&2
    exit 1
fi

echo "ALL PASS (${#sections[@]} секций)"
