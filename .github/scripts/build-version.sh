#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Версия сборки: база из app/build.gradle.kts, опциональный суффикс (бета),
# versionCode и коммит — плюс сверка того, что ожидает вызывающий.
#
# Usage:
#   build-version.sh --root DIR [--version-name V] [--version-code C]
#                    [--expected-commit SHA]
#
# Выход (в $GITHUB_OUTPUT, если задан, иначе в stdout):
#   base=<X.Y.Z>
#   version=<X.Y.Z или X.Y.Z-suffix>
#   suffix=<-suffix или пусто>
#   version-code=<N>
#   commit=<полный sha>

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-version.sh --root DIR [--version-name V] [--version-code C]
                        [--expected-commit SHA]

Reads the base version and versionCode from app/build.gradle.kts and prints:
  base=, version=, suffix=, version-code=, commit=

  --version-name V       override versionName (must extend the base with -suffix)
  --version-code C       expected versionCode; mismatching the file fails
  --expected-commit SHA  expected HEAD; mismatching it fails
EOF
}

die() {
    printf 'build version: %s\n' "$1" >&2
    exit 1
}

root=""
version_name=""
expected_code=""
expected_commit=""

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
        --version-name)
            version_name="${2:?--version-name requires a value}"
            shift 2
            ;;
        --version-name=*)
            version_name="${1#--version-name=}"
            shift
            ;;
        --version-code)
            expected_code="${2:?--version-code requires a value}"
            shift 2
            ;;
        --version-code=*)
            expected_code="${1#--version-code=}"
            shift
            ;;
        --expected-commit)
            expected_commit="${2:?--expected-commit requires a value}"
            shift 2
            ;;
        --expected-commit=*)
            expected_commit="${1#--expected-commit=}"
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
gradle_file="$root/app/build.gradle.kts"
[[ -f "$gradle_file" ]] || die "не найден файл версии: $gradle_file"

# Канонические парсеры: те же sed'ы читают версию в scripts/build_apk.sh,
# scripts/install_apk.sh, collect-release-assets.sh, release-note.sh и в шаге
# "Verify APK identity". Литерал в build.gradle.kts остаётся первым именно
# поэтому.
base="$(sed -n 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$gradle_file" | head -n 1)"
code="$(sed -n 's/^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' \
    "$gradle_file" | head -n 1)"

[[ -n "$base" ]] || die "не удалось прочитать versionName из $gradle_file"
[[ -n "$code" ]] || die "не удалось прочитать versionCode из $gradle_file"

commit="$(git -C "$root" rev-parse HEAD 2>/dev/null)" ||
    die "не удалось прочитать HEAD репозитория $root"

version="${version_name:-$base}"
# Без этой проверки суффикс тихо стал бы всей строкой.
[[ "$version" == "$base"* ]] ||
    die "version '$version' does not start with the base '$base'"

suffix=""
if [[ "$version" != "$base" ]]; then
    suffix="${version#"$base"}"
fi
[[ -z "$suffix" || "$suffix" == -* ]] ||
    die "suffix '$suffix' must start with '-' (got version '$version', base '$base')"

[[ -z "$expected_code" || "$expected_code" == "$code" ]] ||
    die "versionCode mismatch: expected '$expected_code', $gradle_file has '$code'"
[[ -z "$expected_commit" || "$expected_commit" == "$commit" ]] ||
    die "commit mismatch: expected '$expected_commit', HEAD is '$commit'"

outputs=$(
    printf 'base=%s\nversion=%s\nsuffix=%s\nversion-code=%s\ncommit=%s\n' \
        "$base" "$version" "$suffix" "$code" "$commit"
)
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$outputs" >>"$GITHUB_OUTPUT"
else
    printf '%s\n' "$outputs"
fi
