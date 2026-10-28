#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Определяет релизный target по тегу: проверяет имя тега, существование тега,
# достижимость его коммита из origin/main — и отдаёт выходы для workflow.
#
# Вход (env):
#   GITHUB_EVENT_NAME   push | workflow_dispatch
#   GITHUB_REF_TYPE     tag | branch
#   GITHUB_REF_NAME     имя тега (push) либо имя ветки (workflow_dispatch)
#   INPUT_TAG_NAME      имя существующего тега (только workflow_dispatch)
#   INPUT_DRY_RUN       true | false (только workflow_dispatch, опционально)
#   GITHUB_OUTPUT       файл для записи выходов (опционально)
#
# Выход (в GITHUB_OUTPUT, если задан, иначе в stdout):
#   tag=v2.5.1
#   version=2.5.1
#   commit=<полный sha коммита тега>
#   dry_run=false

set -euo pipefail

readonly RELEASE_TAG_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+$'

usage() {
    cat <<'EOF'
Usage: resolve-release-target.sh

Reads the release target from the environment and prints:
  tag=<vX.Y.Z>
  version=<X.Y.Z>
  commit=<sha>
  dry_run=<true|false>

Environment:
  GITHUB_EVENT_NAME   push | workflow_dispatch
  GITHUB_REF_TYPE     tag | branch
  GITHUB_REF_NAME     tag name (push) or branch name (dispatch)
  INPUT_TAG_NAME      existing tag name (workflow_dispatch only)
  INPUT_DRY_RUN       true | false (workflow_dispatch only, optional)
  GITHUB_OUTPUT       file to append the outputs to (optional)
EOF
}

die() {
    printf 'release target: %s\n' "$1" >&2
    exit 1
}

case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
    '') ;;
    *)
        usage >&2
        exit 1
        ;;
esac

event_name="${GITHUB_EVENT_NAME:-}"
ref_type="${GITHUB_REF_TYPE:-}"
ref_name="${GITHUB_REF_NAME:-}"

case "$event_name" in
    push)
        [[ "$ref_type" == "tag" ]] ||
            die "push must carry a tag ref (GITHUB_REF_TYPE=tag, got '$ref_type')"
        tag="$ref_name"
        dry_run="false"
        ;;
    workflow_dispatch)
        [[ "$ref_type" == "branch" ]] ||
            die "workflow_dispatch must run from a branch (GITHUB_REF_TYPE=branch, got '$ref_type')"
        [[ "$ref_name" == "main" ]] ||
            die "workflow_dispatch must run from the main branch (got '$ref_name')"
        tag="${INPUT_TAG_NAME:-}"
        dry_run="${INPUT_DRY_RUN:-false}"
        ;;
    *)
        die "unsupported event '$event_name' (expected push or workflow_dispatch)"
        ;;
esac

[[ -n "$tag" ]] || die "tag name is empty"
git check-ref-format "refs/tags/$tag" >/dev/null 2>&1 ||
    die "invalid tag name '$tag'"
[[ "$tag" =~ $RELEASE_TAG_PATTERN ]] ||
    die "tag '$tag' is not a release tag, expected $RELEASE_TAG_PATTERN"

if ! git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    # || true: under `set -e` a failing fetch would abort with a git error
    # instead of the "tag does not exist" message below. stderr is dropped
    # because "couldn't find remote ref" is the expected outcome here and
    # would only bury the real message.
    git fetch --quiet --no-tags origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null || true
fi
git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null ||
    die "tag '$tag' does not exist in the repository"

commit="$(git rev-parse "refs/tags/$tag^{commit}")"

if ! git rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
    git fetch --quiet --no-tags origin main:refs/remotes/origin/main || true
fi
git rev-parse --verify --quiet refs/remotes/origin/main >/dev/null ||
    die "origin/main is not available locally"
git merge-base --is-ancestor "$commit" refs/remotes/origin/main ||
    die "commit $commit of tag '$tag' is not reachable from origin/main"

version="${tag#v}"

outputs=$(
    printf 'tag=%s\nversion=%s\ncommit=%s\ndry_run=%s\n' \
        "$tag" "$version" "$commit" "$dry_run"
)
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$outputs" >>"$GITHUB_OUTPUT"
else
    printf '%s\n' "$outputs"
fi
