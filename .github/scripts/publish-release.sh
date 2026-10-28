#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Идемпотентная публикация GitHub-релиза протоколом
# «черновик → проверка → публикация».
#
# Почему так, а не «создать и проверить»: проверка после публикации оставляла
# бы видимый артефакт с неверным описанием, а опубликованный релиз по правилу
# «опубликованное не трогаем» уже не починить. Поэтому сначала всегда черновик,
# затем проверка тела и числа ассетов, и только потом снятие флага draft.
#
# Идемпотентность: 404 — создаём; черновик — удаляем по id и создаём заново
# (тег при этом остаётся: удаление идёт через API по id релиза, а не
# `gh release delete --cleanup-tag`); опубликованный релиз — exit 1 без
# единой записи.
#
# Usage:
#   publish-release.sh --tag TAG --title TITLE --note-file FILE
#                      --asset FILE [--asset FILE ...] [--dry-run]
#
# Env:
#   GITHUB_REPOSITORY             owner/repo, required
#   GH_TOKEN | GITHUB_TOKEN       token for the gh CLI, required
#   CSQTT_ALLOW_RELEASE_WRITES=1  opt-in for writes outside GitHub Actions
#                                 (inside CI GITHUB_ACTIONS=true is enough)
#
# Зависимости: bash, gh, jq (разбор записи релиза), git (best-effort поиск
# предыдущего тега; его отсутствие не ошибка).

set -euo pipefail

readonly NOTE_MARKER='<!-- CSQTT-TECH-NOTES-END -->'

usage() {
    cat <<'EOF'
Usage: publish-release.sh --tag TAG --title TITLE --note-file FILE
                          --asset FILE [--asset FILE ...] [--dry-run]

Creates the release as a draft, verifies its body (marker
<!-- CSQTT-TECH-NOTES-END -->) and asset count, then publishes it.

Required:
  --tag TAG         release tag, e.g. v2.5.1
  --title TITLE     release title, e.g. "CSQTT 2.5.1"
  --note-file FILE  file with the release body (from release-note.sh)
  --asset FILE      release asset; repeat for every asset (at least one)

Optional:
  --dry-run         create and verify the draft, then delete it; nothing
                    becomes public

Environment:
  GITHUB_REPOSITORY             owner/repo (required)
  GH_TOKEN or GITHUB_TOKEN      token for gh (required)
  CSQTT_ALLOW_RELEASE_WRITES=1  allow writes locally (CI sets GITHUB_ACTIONS)
EOF
}

die() {
    printf 'publish release: %s\n' "$1" >&2
    exit 1
}

tag=""
title=""
note_file=""
dry_run="false"
assets=()

assign() {
    case "$1" in
        --tag) tag="$2" ;;
        --title) title="$2" ;;
        --note-file) note_file="$2" ;;
        --asset) assets+=("$2") ;;
    esac
}

while (($#)); do
    case "$1" in
        --tag | --title | --note-file | --asset)
            if (($# < 2)); then
                printf 'publish release: %s requires a value\n' "$1" >&2
                usage >&2
                exit 1
            fi
            assign "$1" "$2"
            shift 2
            ;;
        --tag=* | --title=* | --note-file=* | --asset=*)
            assign "${1%%=*}" "${1#*=}"
            shift
            ;;
        --dry-run)
            dry_run="true"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'publish release: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

[[ -n "$tag" ]] || {
    printf 'publish release: --tag is required\n' >&2
    usage >&2
    exit 1
}
[[ -n "$title" ]] || {
    printf 'publish release: --title is required\n' >&2
    usage >&2
    exit 1
}
[[ -n "$note_file" ]] || {
    printf 'publish release: --note-file is required\n' >&2
    usage >&2
    exit 1
}
((${#assets[@]} >= 1)) || {
    printf 'publish release: at least one --asset is required\n' >&2
    usage >&2
    exit 1
}
[[ -f "$note_file" && -r "$note_file" ]] ||
    die "cannot read the release note: $note_file"

# --- write guards ----------------------------------------------------------
#
# Скрипт запускается и локально (отладка), где gh авторизован на настоящий
# репозиторий. Запись в релизы там закрыта, пока её не открыли явно.

repo="${GITHUB_REPOSITORY:-}"
[[ -n "$repo" ]] ||
    die "GITHUB_REPOSITORY is empty; refusing to guess the repository from the local git remote"

[[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]] ||
    die "no token: set GH_TOKEN or GITHUB_TOKEN"

if [[ "${GITHUB_ACTIONS:-}" != "true" && "${CSQTT_ALLOW_RELEASE_WRITES:-}" != "1" ]]; then
    die "запись в релизы закрыта; выставьте CSQTT_ALLOW_RELEASE_WRITES=1 (в GitHub Actions выставляется автоматически)"
fi

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

note_body="$(cat "$note_file")"

# find_release <tag> — печатает "<id> <draft>" для релиза с этим тегом, либо
# пусто. Именно список, а не /releases/tags/<tag>: эндпоинт по тегу отдаёт 404
# для черновиков, и на этом падал первый настоящий прогон — черновик создан, а
# следующий же вызов его «не находил».
find_release() {
    local out
    out="$(gh api "repos/$repo/releases?per_page=100" \
        --jq ".[] | select(.tag_name == \"$1\") | \"\(.id) \(.draft)\"" 2>>"$err_file")" || return 1
    printf '%s\n' "$out" | head -n 1
}

# delete_release_by_id <id> <reason>
#
# Удаление — только по id: `gh release delete <tag>` умеет уносить и тег
# (--cleanup-tag), а тег обязан пережить пересоздание черновика.
delete_release_by_id() {
    local id="$1" reason="$2"
    printf 'publish release: deleting %s release id=%s (tag %s)\n' "$reason" "$id" "$tag"
    gh api --method DELETE "repos/$repo/releases/$id" >/dev/null
}

# --- 1. look at what is there already --------------------------------------

if ! existing="$(find_release "$tag")"; then
    die "cannot list the releases of $repo: $(tr '\n' ' ' <"$err_file")"
fi

if [[ -n "$existing" ]]; then
    read -r release_id draft <<<"$existing"
    case "$draft" in
        true)
            delete_release_by_id "$release_id" "stale draft"
            ;;
        false)
            die "Release for tag $tag already exists and is published; it is never modified. Use a new tag, or delete it manually."
            ;;
        *)
            die "cannot parse the release for tag $tag: unexpected draft flag '$draft'"
            ;;
    esac
else
    printf 'publish release: no release for tag %s yet\n' "$tag"
fi

# --- 2. create the draft ---------------------------------------------------

# Best-effort: предыдущий semver-тег ограничивает автогенерируемый changelog
# вместо всей истории. Его отсутствие — не ошибка.
prev_tag=""
if prev_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$tag^" 2>/dev/null)"; then
    :
else
    prev_tag=""
fi

create_args=(
    release create "$tag"
    -R "$repo"
    --verify-tag
    --generate-notes
    --draft
    --title "$title"
    --notes "$note_body"
)
if [[ -n "$prev_tag" ]]; then
    create_args+=(--notes-start-tag "$prev_tag")
fi
create_args+=("${assets[@]}")

printf 'publish release: creating draft %s with %d asset(s)\n' "$tag" "${#assets[@]}"
gh "${create_args[@]}"

# --- 3. verify the draft before it becomes public --------------------------

# Дальше работаем по id: черновик по тегу не находится (см. find_release).
created="$(find_release "$tag")"
[[ -n "$created" ]] ||
    die "the draft for tag $tag was not found right after creation"
read -r release_id _ <<<"$created"

body="$(gh api "repos/$repo/releases/$release_id" --jq '.body')"
[[ -n "${body//[[:space:]]/}" ]] ||
    die "draft verification failed: the release body for tag $tag is empty"

[[ "$body" == *"$NOTE_MARKER"* ]] ||
    die "draft verification failed: the release body for tag $tag does not contain $NOTE_MARKER"

asset_count="$(gh api "repos/$repo/releases/$release_id" --jq '.assets | length')"
[[ "$asset_count" =~ ^[0-9]+$ ]] ||
    die "draft verification failed: cannot read the asset count for tag $tag (got '$asset_count')"
[[ "$asset_count" == "${#assets[@]}" ]] ||
    die "draft verification failed: expected ${#assets[@]} asset(s), the release has $asset_count"

printf 'publish release: draft %s verified (body has the marker, %s asset(s))\n' \
    "$tag" "$asset_count"

# --- 4. publish, or discard the draft in dry-run ---------------------------

if [[ "$dry_run" == "true" ]]; then
    delete_release_by_id "$release_id" "dry-run draft"
    printf 'publish release: dry run for %s done; no public release was created\n' "$tag"
    exit 0
fi

# Публикация — тоже по id: `gh release edit <tag> --draft=false` ищет релиз по
# тегу и на черновике получает тот же 404.
gh api --method PATCH "repos/$repo/releases/$release_id" -f draft=false >/dev/null
printf 'publish release: released %s\n' "$tag"
