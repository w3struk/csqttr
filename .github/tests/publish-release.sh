#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Тест .github/scripts/publish-release.sh против fake-`gh`.
#
# Настоящий gh на машине разработчика авторизован и нацелен на боевой
# репозиторий, поэтому тест изолируется жёстко: шим `gh` первым в PATH,
# собственный GH_CONFIG_DIR и проверка, что `command -v gh` действительно
# указывает в песочницу. Без этой проверки опечатка в PATH могла бы удалить
# настоящий релиз.
#
# fake-`gh` хранит состояние в $FAKE_GH_DIR/state.json и пишет каждый вызов
# одной строкой в $FAKE_GH_DIR/gh.log (переводы строк в аргументах
# экранируются как \n, чтобы тело описания осталось в одной строке лога).

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="$REPO_ROOT/.github/scripts/publish-release.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_DIR="$TMP/fake"
mkdir -p "$FAKE_DIR" "$TMP/bin" "$TMP/assets"
STATE="$FAKE_DIR/state.json"
LOG="$FAKE_DIR/gh.log"
: >"$LOG"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass=0
ok() {
    pass=$((pass + 1))
}

dump_log() {
    if [[ -s "$LOG" ]]; then
        printf 'gh log was:\n' >&2
        sed 's/^/  | /' "$LOG" >&2
    else
        printf 'gh log was empty\n' >&2
    fi
}

dump_err() {
    if [[ -s "$TMP/err.txt" ]]; then
        printf 'stderr was:\n' >&2
        sed 's/^/  | /' "$TMP/err.txt" >&2
    fi
    dump_log
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    [[ "$actual" == "$expected" ]] || fail "$msg (expected '$expected', got '$actual')"
    ok
}

assert_log() {
    grep -Fq -- "$1" "$LOG" || {
        dump_log
        fail "$SCENARIO: gh log has no '$1'"
    }
    ok
}

assert_log_regex() {
    local pattern="$1" msg="$2"
    grep -Eq -- "$pattern" "$LOG" || {
        dump_log
        fail "$SCENARIO: $msg (no log line matches /$pattern/)"
    }
    ok
}

assert_no_log_regex() {
    local pattern="$1" msg="$2"
    if grep -Eq -- "$pattern" "$LOG"; then
        dump_log
        fail "$SCENARIO: $msg (unexpected log line matches /$pattern/)"
    fi
    ok
}

log_line() {
    grep -nE -- "$1" "$LOG" | head -n1 | cut -d: -f1
}

# assert_before <pattern A> <pattern B> <message>
assert_before() {
    local a b
    a="$(log_line "$1")"
    b="$(log_line "$2")"
    [[ -n "$a" && -n "$b" ]] ||
        fail "$SCENARIO: $3 (one of /$1/, /$2/ is missing from the gh log)"
    ((a < b)) || fail "$SCENARIO: $3 (line $a comes after line $b)"
    ok
}

# ---------------------------------------------------------------- fake `gh`

cat >"$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
# Fake gh CLI for .github/tests/publish-release.sh.
set -euo pipefail

STATE="${FAKE_GH_DIR:?}/state.json"
LOG="${FAKE_GH_DIR:?}/gh.log"

escaped=()
for arg in "$@"; do
    escaped+=("${arg//$'\n'/\\n}")
done
printf '%s\n' "${escaped[*]}" >>"$LOG"

not_found() {
    printf 'gh: Not Found (HTTP 404)\n' >&2
    exit 1
}

# release_json <tag>: compact record on stdout, exit 1 with a 404 otherwise.
release_json() {
    local tag="$1" record
    record="$(jq -c --arg t "$tag" '.releases[$t] // empty' "$STATE")"
    [[ -n "$record" ]] || not_found
    printf '%s\n' "$record"
}

# release_by_id <id>: compact record on stdout, exit 1 with a 404 otherwise.
release_by_id() {
    local id="$1" record
    record="$(jq -c --arg id "$id" \
        '[.releases[] | select((.id | tostring) == $id)] | first // empty' "$STATE")"
    [[ -n "$record" ]] || not_found
    printf '%s\n' "$record"
}

api_call() {
    local method="GET" path="" filter=""
    local -a fields=()
    while (($#)); do
        case "$1" in
            --method | -X)
                method="$2"
                shift 2
                ;;
            --jq | -q)
                filter="$2"
                shift 2
                ;;
            -f | --field)
                fields+=("$2")
                shift 2
                ;;
            -*)
                printf 'fake gh: unsupported api flag: %s\n' "$1" >&2
                exit 1
                ;;
            *)
                path="$1"
                shift
                ;;
        esac
    done

    case "$method" in
        GET)
            case "$path" in
                repos/*/releases/tags/*)
                    local tag="${path##*/}"
                    local record
                    record="$(release_json "$tag")"
                    # Реальный API отдаёт 404 для черновика: по тегу видны только
                    # опубликованные релизы. Именно на этом упал первый живой
                    # прогон — черновик создан, а следующий вызов его не нашёл.
                    if [[ "$(jq -r '.draft' <<<"$record")" == "true" ]]; then
                        not_found
                    fi
                    case "$filter" in
                        "")
                            printf '%s\n' "$record"
                            ;;
                        ".body")
                            jq -r '.body' <<<"$record"
                            ;;
                        ".assets | length")
                            jq -r '.assets | length' <<<"$record"
                            ;;
                        *)
                            printf 'fake gh: unsupported --jq filter: %s\n' "$filter" >&2
                            exit 1
                            ;;
                    esac
                    ;;
                repos/*/releases\?per_page=100)
                    if [[ -n "${FAKE_GH_LIST_FAIL:-}" ]]; then
                        printf 'gh: Server Error (HTTP 502)\n' >&2
                        exit 1
                    fi
                    # filter: .[] | select(.tag_name == "<tag>") | "\(.id) \(.draft)"
                    local list_tag
                    list_tag="$(sed -n 's/.*select(\.tag_name == "\(.*\)").*/\1/p' <<<"$filter")"
                    if [[ -z "$list_tag" ]]; then
                        printf 'fake gh: unsupported list filter: %s\n' "$filter" >&2
                        exit 1
                    fi
                    jq -r --arg t "$list_tag" \
                        '.releases | to_entries[]
                         | select(.value.tag_name == $t)
                         | "\(.value.id) \(.value.draft)"' "$STATE"
                    ;;
                repos/*/releases/*)
                    local id="${path##*/}"
                    local record
                    record="$(release_by_id "$id")"
                    case "$filter" in
                        ".body")
                            jq -r '.body' <<<"$record"
                            ;;
                        ".assets | length")
                            jq -r '.assets | length' <<<"$record"
                            ;;
                        *)
                            printf 'fake gh: unsupported --jq filter: %s\n' "$filter" >&2
                            exit 1
                            ;;
                    esac
                    ;;
                *)
                    printf 'fake gh: unsupported api path: %s\n' "$path" >&2
                    exit 1
                    ;;
            esac
            ;;
        PATCH)
            case "$path" in
                repos/*/releases/*)
                    local id="${path##*/}"
                    release_by_id "$id" >/dev/null
                    local field draft=""
                    for field in ${fields[@]+"${fields[@]}"}; do
                        case "$field" in
                            draft=*) draft="${field#draft=}" ;;
                            *)
                                printf 'fake gh: unsupported field: %s\n' "$field" >&2
                                exit 1
                                ;;
                        esac
                    done
                    [[ -n "$draft" ]] || {
                        printf 'fake gh: PATCH without draft\n' >&2
                        exit 1
                    }
                    jq --arg id "$id" --argjson d "$draft" \
                        '.releases |= map_values(if (.id | tostring) == $id then .draft = $d else . end)' \
                        "$STATE" >"$STATE.tmp"
                    mv "$STATE.tmp" "$STATE"
                    ;;
                *)
                    printf 'fake gh: unsupported PATCH path: %s\n' "$path" >&2
                    exit 1
                    ;;
            esac
            ;;
        DELETE)
            case "$path" in
                repos/*/releases/*)
                    local id="${path##*/}"
                    if ! jq -e --arg id "$id" \
                        '[.releases[].id | tostring] | index($id) != null' "$STATE" >/dev/null; then
                        printf 'gh: Not Found (HTTP 404) for release id %s\n' "$id" >&2
                        exit 1
                    fi
                    jq --arg id "$id" \
                        '.releases |= with_entries(select((.value.id | tostring) != $id))' \
                        "$STATE" >"$STATE.tmp"
                    mv "$STATE.tmp" "$STATE"
                    ;;
                *)
                    printf 'fake gh: unsupported DELETE path: %s\n' "$path" >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            printf 'fake gh: unsupported method: %s\n' "$method" >&2
            exit 1
            ;;
    esac
}

release_create() {
    local tag="" notes="" body="" draft="false" title=""
    local -a assets=()
    while (($#)); do
        case "$1" in
            -R | --repo)
                shift 2
                ;;
            --verify-tag | --generate-notes)
                shift
                ;;
            --draft)
                draft="true"
                shift
                ;;
            --title | --notes | --notes-start-tag)
                case "$1" in
                    --title) title="$2" ;;
                    --notes) notes="$2" ;;
                    --notes-start-tag) : ;;
                esac
                shift 2
                ;;
            -*)
                printf 'fake gh: unsupported release create flag: %s\n' "$1" >&2
                exit 1
                ;;
            *)
                if [[ -z "$tag" ]]; then
                    tag="$1"
                else
                    assets+=("$(basename -- "$1")")
                fi
                shift
                ;;
        esac
    done

    [[ -n "$tag" ]] || {
        printf 'fake gh: release create without a tag\n' >&2
        exit 1
    }
    if jq -e --arg t "$tag" '.releases[$t] != null' "$STATE" >/dev/null; then
        printf 'gh: Release with tag %s already exists\n' "$tag" >&2
        exit 1
    fi
    [[ -n "$title" ]] || {
        printf 'fake gh: release create without --title\n' >&2
        exit 1
    }

    body="${FAKE_GH_BODY_OVERRIDE-$notes}"

    local override_count="${FAKE_GH_ASSET_COUNT:-}"
    if [[ -n "$override_count" ]]; then
        assets=()
        local i=0
        while ((i < override_count)); do
            assets+=("fake-asset-$i")
            i=$((i + 1))
        done
    fi

    local assets_json='[]'
    if ((${#assets[@]})); then
        assets_json="$(printf '%s\n' "${assets[@]}" | jq -R . | jq -s -c .)"
    fi

    local id
    id="$(jq -r '.next_id' "$STATE")"
    jq --arg t "$tag" --argjson id "$id" --arg body "$body" --argjson assets "$assets_json" \
        --argjson draft "$draft" \
        '.releases[$t] = {id: $id, tag_name: $t, draft: $draft, body: $body, assets: $assets}
         | .next_id = ($id + 1)' "$STATE" >"$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}

release_delete() {
    local tag=""
    while (($#)); do
        case "$1" in
            -R | --repo)
                shift 2
                ;;
            --yes | --cleanup-tag)
                shift
                ;;
            -*)
                printf 'fake gh: unsupported release delete flag: %s\n' "$1" >&2
                exit 1
                ;;
            *)
                tag="$1"
                shift
                ;;
        esac
    done
    release_json "$tag" >/dev/null
    jq --arg t "$tag" 'del(.releases[$t])' "$STATE" >"$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}

release_edit() {
    local tag="" draft=""
    while (($#)); do
        case "$1" in
            -R | --repo)
                shift 2
                ;;
            --draft=*)
                draft="${1#--draft=}"
                shift
                ;;
            --draft)
                draft="$2"
                shift 2
                ;;
            -*)
                printf 'fake gh: unsupported release edit flag: %s\n' "$1" >&2
                exit 1
                ;;
            *)
                tag="$1"
                shift
                ;;
        esac
    done
    [[ -n "$draft" ]] || {
        printf 'fake gh: release edit without --draft\n' >&2
        exit 1
    }
    release_json "$tag" >/dev/null
    jq --arg t "$tag" --argjson d "$draft" '.releases[$t].draft = $d' \
        "$STATE" >"$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}

(($#)) || {
    printf 'fake gh: no arguments\n' >&2
    exit 1
}

command="$1"
shift
case "$command" in
    api) api_call "$@" ;;
    release)
        (($#)) || {
            printf 'fake gh: release needs a subcommand\n' >&2
            exit 1
        }
        sub="$1"
        shift
        case "$sub" in
            create) release_create "$@" ;;
            delete) release_delete "$@" ;;
            edit) release_edit "$@" ;;
            *)
                printf 'fake gh: unsupported release subcommand: %s\n' "$sub" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        printf 'fake gh: unsupported command: %s\n' "$command" >&2
        exit 1
        ;;
esac
SHIM
chmod +x "$TMP/bin/gh"

# --------------------------------------------------------------- fixtures

NOTE_FILE="$TMP/note.md"
cat >"$NOTE_FILE" <<'EOF'
## CSQTT 9.9.9

Тег: v9.9.9
Wire-ревизия: CSQTT-WIRE-3

<!-- CSQTT-TECH-NOTES-END -->
EOF

ASSET_ARGS=()
for asset in CSQTT-9.9.9-universal.apk CSQTT-9.9.9-arm64-v8a.apk csqtt-linux-amd64; do
    printf 'payload\n' >"$TMP/assets/$asset"
    ASSET_ARGS+=(--asset "$TMP/assets/$asset")
done

note_body="$(cat "$NOTE_FILE")"
NOTE_ESCAPED="${note_body//$'\n'/\\n}"

# --------------------------------------------------------------- harness

SCENARIO=""
TAG="v9.9.9"
CONFIG_DIR=""
SUT_REPO=""
SUT_ALLOW=""
FAKE_BODY_OVERRIDE=""
FAKE_ASSET_COUNT=""

new_scenario() {
    SCENARIO="$1"
    printf '\n--- %s\n' "$1"
    : >"$LOG"
    printf '%s\n' '{"next_id": 100, "releases": {}}' >"$STATE"
    CONFIG_DIR="$(mktemp -d "$TMP/config.XXXXXX")"
    SUT_REPO="o/r"
    SUT_ALLOW="1"
    FAKE_BODY_OVERRIDE=""
    FAKE_ASSET_COUNT=""

    # Изоляция от настоящего GitHub — проверка, а не формальность.
    local resolved
    resolved="$(PATH="$TMP/bin:$PATH" command -v gh)"
    [[ "$resolved" == "$TMP/bin/gh" ]] ||
        fail "$SCENARIO: gh is not isolated (command -v gh = '$resolved')"
    case "$CONFIG_DIR" in
        "$TMP"/*) ;;
        *) fail "$SCENARIO: GH_CONFIG_DIR is not inside the sandbox: $CONFIG_DIR" ;;
    esac
}

# seed_release <tag> <id> <draft true|false> <body> <asset count>
seed_release() {
    jq --arg t "$1" --argjson id "$2" --argjson draft "$3" --arg body "$4" \
        --argjson count "$5" \
        '.releases[$t] = {
             id: $id,
             tag_name: $t,
             draft: $draft,
             body: $body,
             assets: [range(0; $count) | "asset-\(.)"]
         }' "$STATE" >"$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}

run_sut() {
    # env treats everything before the first NAME=VALUE as options, so every -u
    # must be collected up front.
    local -a env_opts=(-u GITHUB_ACTIONS)
    local -a env_args=(
        PATH="$TMP/bin:$PATH"
        GH_CONFIG_DIR="$CONFIG_DIR"
        FAKE_GH_DIR="$FAKE_DIR"
        GH_TOKEN=x
        GITHUB_REPOSITORY="$SUT_REPO"
    )
    if [[ "$SUT_ALLOW" == "1" ]]; then
        env_args+=(CSQTT_ALLOW_RELEASE_WRITES=1)
    else
        env_opts+=(-u CSQTT_ALLOW_RELEASE_WRITES)
    fi
    if [[ -n "$FAKE_BODY_OVERRIDE" ]]; then
        env_args+=("FAKE_GH_BODY_OVERRIDE=$FAKE_BODY_OVERRIDE")
    else
        env_opts+=(-u FAKE_GH_BODY_OVERRIDE)
    fi
    if [[ -n "$FAKE_ASSET_COUNT" ]]; then
        env_args+=("FAKE_GH_ASSET_COUNT=$FAKE_ASSET_COUNT")
    else
        env_opts+=(-u FAKE_GH_ASSET_COUNT)
    fi

    env "${env_opts[@]}" "${env_args[@]}" bash "$SUT" \
        --tag "$TAG" \
        --title "CSQTT 9.9.9" \
        --note-file "$NOTE_FILE" \
        "${ASSET_ARGS[@]}" \
        "$@"
}

expect_sut_ok() {
    if ! run_sut "$@" >"$TMP/out.txt" 2>"$TMP/err.txt"; then
        dump_err
        fail "$SCENARIO: the script failed where it had to succeed"
    fi
    ok
}

expect_sut_fail() {
    local fragment="$1"
    shift
    local rc=0
    run_sut "$@" >"$TMP/out.txt" 2>"$TMP/err.txt" || rc=$?
    ((rc != 0)) || {
        dump_log
        fail "$SCENARIO: the script succeeded where it had to fail"
    }
    if [[ -n "$fragment" ]] && ! grep -qF -- "$fragment" "$TMP/err.txt"; then
        dump_err
        fail "$SCENARIO: stderr does not mention '$fragment'"
    fi
    ok
}

# ------------------------------------------------- 1. 404, full protocol

new_scenario "404: full protocol"
TAG="v9.9.9"
expect_sut_ok

assert_log_regex '^release create v9\.9\.9 -R o/r --verify-tag --generate-notes --draft ' \
    "the draft is created with -R, --verify-tag, --generate-notes and --draft"
assert_log "--title CSQTT 9.9.9"
assert_log "--notes $NOTE_ESCAPED"
for asset in CSQTT-9.9.9-universal.apk CSQTT-9.9.9-arm64-v8a.apk csqtt-linux-amd64; do
    assert_log "$TMP/assets/$asset"
done
assert_no_log_regex 'cleanup-tag' "the tag must never be deleted with the draft"
# Черновик по тегу не виден (реальный API отдаёт 404), поэтому скрипт обязан
# ходить в список и по id. Возврат к releases/tags снова всё сломает.
assert_no_log_regex 'releases/tags' "the tag endpoint must not be used: drafts are invisible there"

assert_before '^release create ' 'releases/[0-9]+ --jq \.body$' \
    "the body is checked after the draft is created"
assert_before 'releases/[0-9]+ --jq \.body$' 'releases/[0-9]+ --jq \.assets \| length$' \
    "the asset count is checked after the body"
assert_before 'releases/[0-9]+ --jq \.assets \| length$' \
    '^api --method PATCH repos/o/r/releases/[0-9]+ -f draft=false$' \
    "the draft is published only after both checks"

assert_eq "$(jq -r '.releases["v9.9.9"].draft' "$STATE")" "false" \
    "the release is public in the end"
assert_eq "$(jq -r '.releases["v9.9.9"].assets | length' "$STATE")" "3" \
    "all three assets were attached"
assert_eq "$(jq -r '.releases["v9.9.9"].body' "$STATE")" "$note_body" \
    "the release body is the note file"
assert_eq "$(grep -cE '^api --method PATCH ' "$LOG")" "1" "the draft is published exactly once"

# ------------------------------- 2. body with the marker and the right count

new_scenario "marker + asset count: publish"
TAG="v9.9.10"
expect_sut_ok

assert_log_regex '^release create v9\.9\.10 ' "the draft is created"
assert_log_regex 'releases/[0-9]+ --jq \.body$' "the body is read back"
assert_log_regex '^api --method PATCH repos/o/r/releases/[0-9]+ -f draft=false$' "the draft is published"
assert_eq "$(jq -r '.releases["v9.9.10"].draft' "$STATE")" "false" \
    "the release is public"

# ------------------------------------------------ 3. body without the marker

new_scenario "body without the marker: no publication"
TAG="v9.9.11"
FAKE_BODY_OVERRIDE="$(
    printf '## CSQTT 9.9.11\n\nТело без маркера.\n'
)"
expect_sut_fail "does not contain"

assert_log_regex '^release create v9\.9\.11 ' "the draft is still created"
assert_no_log_regex '^api --method PATCH ' "a draft with a bad body is never published"
assert_eq "$(jq -r '.releases["v9.9.11"].draft' "$STATE")" "true" \
    "the release stays a draft"

# ------------------------------------------------- 4. wrong number of assets

new_scenario "asset count mismatch: no publication"
TAG="v9.9.12"
FAKE_ASSET_COUNT="2"
expect_sut_fail "the release has 2"

assert_log_regex '^release create v9\.9\.12 ' "the draft is still created"
assert_no_log_regex '^api --method PATCH ' "a draft with a wrong asset count is never published"
assert_eq "$(jq -r '.releases["v9.9.12"].draft' "$STATE")" "true" \
    "the release stays a draft"

# ------------------------------------------- 5. stale draft: delete and redo

new_scenario "stale draft: deleted by id, then recreated"
TAG="v9.9.13"
seed_release "v9.9.13" 777 true "старое тело" 1
expect_sut_ok

assert_log_regex '^api --method DELETE repos/o/r/releases/777$' \
    "the stale draft is deleted through the API by release id"
assert_no_log_regex 'cleanup-tag' "the tag survives the delete"
assert_no_log_regex '^release delete ' "the delete is not tag-based"
assert_before '^api --method DELETE repos/o/r/releases/777$' '^release create v9\.9\.13 ' \
    "the stale draft is deleted before the new one is created"
assert_before '^release create v9\.9\.13 ' '^api --method PATCH repos/o/r/releases/[0-9]+ -f draft=false$' \
    "the new draft is published after it is created"

assert_eq "$(jq -r '.releases["v9.9.13"].draft' "$STATE")" "false" \
    "the recreated release is public"
assert_eq "$(jq -r '[.releases[].id] | length' "$STATE")" "1" \
    "only one release record is left"

# --------------------------------------------- 6. published release untouched

new_scenario "published release: never modified"
TAG="v9.9.14"
seed_release "v9.9.14" 900 false "$note_body" 3
expect_sut_fail "never modified"

assert_no_log_regex '^release ' "a published release sees no create, edit or delete"
assert_eq "$(jq -r '.releases["v9.9.14"].draft' "$STATE")" "false" \
    "the published release is untouched"
assert_eq "$(jq -r '.releases["v9.9.14"].body' "$STATE")" "$note_body" \
    "the published body is untouched"

# ------------------------------------------------------- 7. no write opt-in

new_scenario "no write opt-in: writes are closed"
TAG="v9.9.15"
SUT_ALLOW="0"
expect_sut_fail "CSQTT_ALLOW_RELEASE_WRITES"

[[ ! -s "$LOG" ]] || {
    dump_log
    fail "$SCENARIO: gh was called without the write opt-in"
}
ok
assert_eq "$(jq -r '.releases | length' "$STATE")" "0" "nothing was created"

# ---------------------------------------------------------------- 8. dry run

new_scenario "dry run: draft created, verified, removed"
TAG="v9.9.16"
expect_sut_ok --dry-run

assert_log_regex '^release create v9\.9\.16 ' "the draft is created in dry run"
assert_log_regex 'releases/[0-9]+ --jq \.body$' "the body is verified in dry run"
assert_log_regex '^api --method DELETE repos/o/r/releases/100$' \
    "the dry-run draft is deleted by id"
assert_no_log_regex '^api --method PATCH ' "dry run never publishes"

assert_before 'releases/[0-9]+ --jq \.assets \| length$' \
    '^api --method DELETE repos/o/r/releases/100$' \
    "the dry-run draft is removed only after the checks"
assert_eq "$(jq -r '.releases | length' "$STATE")" "0" \
    "dry run leaves no release behind"
grep -qF -- "no public release was created" "$TMP/out.txt" || {
    sed 's/^/  | /' "$TMP/out.txt" >&2
    fail "$SCENARIO: the script does not say that nothing was published"
}
ok

# --------------------------------------------------- 9. empty repository name

new_scenario "empty GITHUB_REPOSITORY: refused"
TAG="v9.9.17"
SUT_REPO=""
expect_sut_fail "GITHUB_REPOSITORY"

[[ ! -s "$LOG" ]] || {
    dump_log
    fail "$SCENARIO: gh was called with an empty repository"
}
ok

# ------------------------------------------------------------ 10. bad flag

new_scenario "unknown flag: usage and exit 1"
TAG="v9.9.18"
expect_sut_fail "Usage:" --no-such-flag

[[ ! -s "$LOG" ]] || {
    dump_log
    fail "$SCENARIO: gh was called before the arguments were parsed"
}
ok

# ------------------------------------------- 11. list call fails (API down)

new_scenario "release list fails: clear error"
TAG="v9.9.19"
export FAKE_GH_LIST_FAIL=1
expect_sut_fail "cannot list the releases"
unset FAKE_GH_LIST_FAIL
ok

printf '\npublish-release: %d assertions OK\n' "$pass"
