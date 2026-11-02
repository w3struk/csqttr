#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Версия беты: база из app/build.gradle.kts плюс -beta.<short-sha>.
#
# Usage:
#   beta-version.sh --root DIR [--branch NAME]
#
# Выход (в $GITHUB_OUTPUT, если задан, иначе в stdout):
#   commit=, short=, base=, version=, suffix=, version-code=
#
# Тот же sed читает версию в build-version.sh, collect-release-assets.sh и
# scripts/build_apk.sh — форму строки versionName менять нельзя.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: beta-version.sh --root DIR [--branch NAME]

Prints commit=, short=, base=, version=, suffix=, version-code=
where version is <base>-beta.<short-sha>. Only the main branch is allowed.
EOF
}

die() {
    printf 'beta version: %s\n' "$1" >&2
    exit 1
}

root=""
branch=""

while (($#)); do
    case "$1" in
        --root)
            root="${2:?--root requires a value}"
            shift 2
            ;;
        --root=*)
            root="${1#--root=}"
            shift
            ;;
        --branch)
            branch="${2:?--branch requires a value}"
            shift 2
            ;;
        --branch=*)
            branch="${1#--branch=}"
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

root="${root:-$PWD}"

# Ручной запуск с фича-ветки отправил бы тестерам незамерженный код.
[[ -z "$branch" || "$branch" == "main" ]] ||
    die "бета собирается только с main, получено '$branch'"

gradle_file="$root/app/build.gradle.kts"
[[ -f "$gradle_file" ]] || die "нет файла $gradle_file"

base="$(sed -n 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$gradle_file" | head -n 1)"
[[ -n "$base" ]] || die "не удалось прочитать versionName из $gradle_file"

code="$(sed -n 's/^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' \
    "$gradle_file" | head -n 1)"
[[ -n "$code" ]] || die "не удалось прочитать versionCode из $gradle_file"

commit="$(git -C "$root" rev-parse HEAD 2>/dev/null)" ||
    die "не удалось прочитать HEAD репозитория $root"
short="$(git -C "$root" rev-parse --short=7 HEAD 2>/dev/null)" ||
    die "не удалось прочитать короткий хеш HEAD в $root"

version="${base}-beta.${short}"
suffix="-beta.${short}"

# version-code — не переопределение, а то же значение из файла: build.yml
# сверит его со своим чтением (expected-version-code). Поднимать код беты
# нельзя: релиз с меньшим кодом стал бы для тестера «понижением».
outputs=$(
    printf 'commit=%s\nshort=%s\nbase=%s\nversion=%s\nsuffix=%s\nversion-code=%s\n' \
        "$commit" "$short" "$base" "$version" "$suffix" "$code"
)
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$outputs" >>"$GITHUB_OUTPUT"
else
    printf '%s\n' "$outputs"
fi
