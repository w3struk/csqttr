#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Section test for .github/scripts/resolve-release-target.sh.
#
# Everything runs inside a throw-away sandbox under mktemp -d: a bare origin
# repository plus one clone. The working tree of this repository is never
# touched. Exit 0 means all scenarios passed.

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/.github/scripts/resolve-release-target.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/stdout.txt"
ERR="$TMP/stderr.txt"
STATUS=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    if [[ -s "$OUT" ]]; then
        printf -- '--- stdout ---\n%s\n' "$(<"$OUT")" >&2
    fi
    if [[ -s "$ERR" ]]; then
        printf -- '--- stderr ---\n%s\n' "$(<"$ERR")" >&2
    fi
    exit 1
}

ok() {
    printf '[OK] %s\n' "$1"
}

# run_resolve <dir> [VAR=value ...]
# Runs the script in <dir> with a scrubbed GITHUB_* / INPUT_* environment:
# only the pairs passed as arguments are visible to the script.
run_resolve() {
    local dir="$1"
    shift
    set +e
    (
        cd "$dir" || exit 99
        unset GITHUB_EVENT_NAME GITHUB_REF_TYPE GITHUB_REF_NAME \
            INPUT_TAG_NAME INPUT_DRY_RUN GITHUB_OUTPUT
        env "$@" bash "$SCRIPT"
    ) >"$OUT" 2>"$ERR"
    STATUS=$?
    set -e
}

expect_status() {
    local want="$1" label="$2"
    [[ "$STATUS" -eq "$want" ]] ||
        fail "$label: ожидался exit $want, получен exit $STATUS"
}

expect_line() {
    local needle="$1" label="$2"
    grep -qxF -- "$needle" "$OUT" ||
        fail "$label: stdout не содержит строку '$needle'"
}

expect_err_fixed() {
    local needle="$1" label="$2"
    grep -qF -- "$needle" "$ERR" ||
        fail "$label: stderr не содержит '$needle'"
}

expect_err_re() {
    local pattern="$1" label="$2"
    grep -qE -- "$pattern" "$ERR" ||
        fail "$label: stderr не соответствует регулярке '$pattern'"
}

expect_count() {
    local pattern="$1" want="$2" file="$3" label="$4"
    local got
    got="$(grep -c -- "$pattern" "$file" || true)"
    [[ "$got" == "$want" ]] ||
        fail "$label: '$pattern' в $(basename -- "$file") встречается $got раз(а), ожидалось $want"
}

[[ -f "$SCRIPT" ]] || fail "нет скрипта $SCRIPT"

# --- Sandbox ---------------------------------------------------------------

# --initial-branch=main is mandatory: cloning an empty bare repository would
# otherwise leave a local "master" branch and every "git push origin main"
# below would fail with "src refspec main does not match any".
git init -q --bare --initial-branch=main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work"
WORK="$TMP/work"

(
    cd "$WORK"
    git config user.email test@example.invalid
    git config user.name "CSQTT Test"
    printf 'x\n' >f
    git add f
    git commit -qm one
    git push -q origin main
)
MAIN_SHA="$(git -C "$WORK" rev-parse HEAD)"

(
    cd "$WORK"
    git tag v1.2.3
    git push -q origin v1.2.3
)

# Side branch not merged into main; its commit is only reachable through the
# tag pushed below.
(
    cd "$WORK"
    git checkout -q -b side
    printf 'y\n' >g
    git add g
    git commit -qm two
    git tag v9.9.9
    git push -q origin v9.9.9
    git checkout -q main
)
SIDE_SHA="$(git -C "$WORK" rev-parse side)"
[[ "$SIDE_SHA" != "$MAIN_SHA" ]] || fail "песочница: side совпал с main"

# --- Scenario 1: push of a release tag -------------------------------------

run_resolve "$WORK" \
    GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3
expect_status 0 "push v1.2.3"
expect_line "tag=v1.2.3" "push v1.2.3"
expect_line "version=1.2.3" "push v1.2.3"
expect_line "commit=$MAIN_SHA" "push v1.2.3"
expect_line "dry_run=false" "push v1.2.3"
ok "push v1.2.3 → tag/version/commit/dry_run"

# --- Scenario 2: pre-release tag -------------------------------------------

run_resolve "$WORK" \
    GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3-rc1
expect_status 1 "push v1.2.3-rc1"
expect_err_fixed '^v[0-9]+\.[0-9]+\.[0-9]+$' "push v1.2.3-rc1"
ok "push v1.2.3-rc1 → exit 1, сообщение содержит регулярку"

# --- Scenario 3: truncated tag ---------------------------------------------

run_resolve "$WORK" \
    GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2
expect_status 1 "push v1.2"
expect_err_fixed '^v[0-9]+\.[0-9]+\.[0-9]+$' "push v1.2"
ok "push v1.2 → exit 1"

# --- Scenario 4: tag of a commit not merged into origin/main ---------------

run_resolve "$WORK" \
    GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v9.9.9
expect_status 1 "push v9.9.9 (side branch)"
expect_err_fixed "origin/main" "push v9.9.9 (side branch)"
expect_err_fixed "$SIDE_SHA" "push v9.9.9 (side branch)"
ok "push v9.9.9 на невлитом коммите → exit 1, stderr называет origin/main"

# --- Scenario 5: non-existent tag ------------------------------------------

run_resolve "$WORK" \
    GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v7.7.7
expect_status 1 "push v7.7.7 (не существует)"
grep -qE 'не существует|does not exist' "$ERR" ||
    fail "push v7.7.7: stderr не сообщает, что тег не существует"
ok "push v7.7.7 → exit 1, «тег не существует»"

# --- Scenario 6: workflow_dispatch from main -------------------------------

run_resolve "$WORK" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main \
    INPUT_TAG_NAME=v1.2.3
expect_status 0 "dispatch main v1.2.3"
expect_line "tag=v1.2.3" "dispatch main v1.2.3"
expect_line "version=1.2.3" "dispatch main v1.2.3"
expect_line "commit=$MAIN_SHA" "dispatch main v1.2.3"
expect_line "dry_run=false" "dispatch main v1.2.3"
ok "dispatch main + v1.2.3 → exit 0, commit = коммит тега"

# dispatch honors the optional dry_run input (workflow passes it through).
run_resolve "$WORK" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main \
    INPUT_TAG_NAME=v1.2.3 INPUT_DRY_RUN=true
expect_status 0 "dispatch dry_run=true"
expect_line "dry_run=true" "dispatch dry_run=true"
ok "dispatch INPUT_DRY_RUN=true → dry_run=true"

# --- Scenario 7: workflow_dispatch from a non-main branch ------------------

run_resolve "$WORK" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_TYPE=branch GITHUB_REF_NAME=dev \
    INPUT_TAG_NAME=v1.2.3
expect_status 1 "dispatch dev"
expect_err_fixed "main" "dispatch dev"
ok "dispatch с ветки dev → exit 1"

# --- Scenario 8: workflow_dispatch without tag name ------------------------

run_resolve "$WORK" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main \
    INPUT_TAG_NAME=
expect_status 1 "dispatch без INPUT_TAG_NAME"
ok "dispatch с пустым INPUT_TAG_NAME → exit 1"

# --- Scenario 9: GITHUB_OUTPUT file ----------------------------------------

GITHUB_OUTPUT_FILE="$TMP/github_output.txt"
run_resolve "$WORK" \
    GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3 \
    GITHUB_OUTPUT="$GITHUB_OUTPUT_FILE"
expect_status 0 "GITHUB_OUTPUT file"
[[ -f "$GITHUB_OUTPUT_FILE" ]] || fail "GITHUB_OUTPUT file: файл не создан"
expect_count '^tag=' 1 "$GITHUB_OUTPUT_FILE" "GITHUB_OUTPUT file"
expect_count '^version=' 1 "$GITHUB_OUTPUT_FILE" "GITHUB_OUTPUT file"
expect_count '^commit=' 1 "$GITHUB_OUTPUT_FILE" "GITHUB_OUTPUT file"
expect_count '^dry_run=' 1 "$GITHUB_OUTPUT_FILE" "GITHUB_OUTPUT file"
expect_count '^tag=v1\.2\.3$' 1 "$GITHUB_OUTPUT_FILE" "GITHUB_OUTPUT file"
expect_count "^commit=$MAIN_SHA\$" 1 "$GITHUB_OUTPUT_FILE" "GITHUB_OUTPUT file"
[[ ! -s "$OUT" ]] || fail "GITHUB_OUTPUT file: stdout должен быть пуст при заданном GITHUB_OUTPUT"
ok "GITHUB_OUTPUT: четыре ключа, stdout пуст"

# --- Scenario 10: tag only on origin (fresh runner has no local tag) -------

git -C "$WORK" tag -d v1.2.3 >/dev/null
git -C "$WORK" rev-parse --verify --quiet refs/tags/v1.2.3 >/dev/null &&
    fail "песочница: локальный тег v1.2.3 не удалён"

run_resolve "$WORK" \
    GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3
expect_status 0 "push v1.2.3 (тег только на origin)"
expect_line "commit=$MAIN_SHA" "push v1.2.3 (тег только на origin)"
ok "отсутствующий локально тег подтягивается из origin"

# --- Scenario 11: origin/main not fetched yet ------------------------------

git -C "$WORK" update-ref -d refs/remotes/origin/main
git -C "$WORK" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null &&
    fail "песочница: refs/remotes/origin/main не удалён"

run_resolve "$WORK" \
    GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3
expect_status 0 "push v1.2.3 (нет origin/main локально)"
git -C "$WORK" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null ||
    fail "origin/main не восстановлен из origin"
ok "origin/main подтягивается из origin, если его нет локально"

printf 'resolve-release-target: все сценарии пройдены\n'
