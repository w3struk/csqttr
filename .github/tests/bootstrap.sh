#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Тест scripts/bootstrap.sh на фиктивном релизе в file://-репозитории:
# пин версии, проброс аргументов в install.sh, проверка SHA-256 и --help.
# Сеть не используется.

set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="$REPO_ROOT/scripts/bootstrap.sh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    [[ ! -s "$TMP/stdout.txt" ]] || printf -- '--- stdout ---\n%s\n' "$(<"$TMP/stdout.txt")" >&2
    [[ ! -s "$TMP/stderr.txt" ]] || printf -- '--- stderr ---\n%s\n' "$(<"$TMP/stderr.txt")" >&2
    exit 1
}

ok() {
    pass=$((pass + 1))
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$msg (expected '$expected', got '$actual')"
    ok
}

assert_contains() {
    local file="$1" needle="$2" msg="$3"
    grep -qF -- "$needle" "$file" || fail "$msg (no '$needle' in $file)"
    ok
}

# run_sut <base> [arguments...] — запускает bootstrap.sh с подменённой базой
# релизов. Статус остаётся в STATUS, вывод — в $TMP/stdout.txt/stderr.txt.
run_sut() {
    local base="$1"
    shift
    STATUS=0
    CSQTT_RELEASE_BASE="$base" bash "$SUT" "$@" \
        >"$TMP/stdout.txt" 2>"$TMP/stderr.txt" || STATUS=$?
}

# make_release <tag> — релиз с фейковым install.sh (печатает ARGS и выходит 7)
# и корректным SHA256SUMS.
make_release() {
    local tag="$1"
    local dir="$TMP/repo/releases/download/$tag"
    mkdir -p "$dir"
    cat >"$dir/install.sh" <<'FAKE_INSTALLER'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*"
exit 7
FAKE_INSTALLER
    ( cd "$dir" && sha256sum install.sh >SHA256SUMS ) || fail "cannot hash fixture"
}


# make_path_only_dir <dir> — PATH без curl/wget, только утилиты самого bootstrap.
# Нужен, чтобы подменить загрузчик управляемым скриптом.
make_path_only_dir() {
    local dir="$1" tool real
    mkdir -p "$dir"
    for tool in bash mktemp awk sha256sum rm cp cat; do
        real="$(command -v "$tool" 2>/dev/null || true)"
        [[ -n "$real" ]] || fail "cannot locate $tool for a fixture"
        ln -sf "$real" "$dir/$tool"
    done
}

# make_latest — копия релиза v9.9.9 в /releases/latest/download, как отдаёт GitHub
# до редиректа. Нужна для проверки непинованного пути без HEAD-запроса.
make_latest() {
    local src="$TMP/repo/releases/download/v9.9.9"
    local dst="$TMP/repo/releases/latest/download"
    mkdir -p "$dst"
    cp "$src/install.sh" "$src/SHA256SUMS" "$dst/"
}

# run_sut_path <path-prefix> <base> [arguments...] — как run_sut, но PATH
# подменяется целиком: так проверяется выбор загрузчика (curl/wget/ничего).
run_sut_path() {
    local path_prefix="$1" base="$2"
    shift 2
    STATUS=0
    PATH="$path_prefix" CSQTT_RELEASE_BASE="$base" bash "$SUT" "$@" \
        >"$TMP/stdout.txt" 2>"$TMP/stderr.txt" || STATUS=$?
}

BASE="file://$TMP/repo"
make_release v9.9.9

# ---------------------------------------------------------------- pinned run

run_sut "$BASE" --version v9.9.9 --yes --check
# Код установщика возвращается как есть, а не превращается в 0.
assert_eq "$STATUS" "7" "installer exit code is propagated"
assert_contains "$TMP/stdout.txt" "ARGS:--version v9.9.9 --yes --check" \
    "installer receives the pinned version and the forwarded arguments"
assert_contains "$TMP/stdout.txt" "v9.9.9" "bootstrap reports the release it runs"

# --version=... is accepted too, and still pins the installer release.
run_sut "$BASE" --version=v9.9.9 --mode docker
assert_eq "$STATUS" "7" "--version=<tag> run reaches the installer"
assert_contains "$TMP/stdout.txt" "ARGS:--version v9.9.9 --mode docker" \
    "--version=<tag> pins the installer release and forwards the rest"

# ------------------------------------------------------------------- --help

run_sut "$BASE" --help
assert_eq "$STATUS" "0" "--help exits 0"
assert_contains "$TMP/stdout.txt" "Usage: bootstrap.sh" "--help prints the usage"
assert_contains "$TMP/stdout.txt" "--version" "--help documents --version"
assert_contains "$TMP/stdout.txt" "CSQTT_RELEASE_BASE" "--help documents the release base override"

# ---------------------------------------------------------- checksum failures

# Хороший тег, но подменённый SHA256SUMS: установщик не должен запускаться.
BAD_TAG=v9.9.8
make_release "$BAD_TAG"
printf '%064d  install.sh\n' 0 >"$TMP/repo/releases/download/$BAD_TAG/SHA256SUMS"
run_sut "$BASE" --version "$BAD_TAG" --yes
[[ "$STATUS" -ne 0 ]] || fail "checksum mismatch must fail"
assert_eq "$STATUS" "20" "checksum mismatch uses exit 20"
assert_contains "$TMP/stderr.txt" "SHA-256" "checksum failure names SHA-256"
if grep -qF "ARGS:" "$TMP/stdout.txt"; then
    fail "installer ran despite a checksum mismatch"
fi
ok

# Отсутствующая запись install.sh: тот же отказ, установщик не запускается.
NO_ENTRY_TAG=v9.9.7
make_release "$NO_ENTRY_TAG"
printf '%064d  csqtt-linux-amd64\n' 0 >"$TMP/repo/releases/download/$NO_ENTRY_TAG/SHA256SUMS"
run_sut "$BASE" --version "$NO_ENTRY_TAG"
[[ "$STATUS" -ne 0 ]] || fail "missing SHA256SUMS entry must fail"
assert_contains "$TMP/stderr.txt" "install.sh" "missing entry failure names install.sh"
if grep -qF "ARGS:" "$TMP/stdout.txt"; then
    fail "installer ran without a SHA256SUMS entry"
fi
ok

# Некорректный тег отвергается до любых загрузок.
run_sut "$BASE" --version 9.9.9
assert_eq "$STATUS" "2" "invalid tag exits 2"
assert_contains "$TMP/stderr.txt" "vX.Y.Z" "invalid tag explains the expected form"

# ------------------------------------------------- unpinned (latest) run

# Без --version bootstrap берёт /releases/latest/download: так работает и curl,
# и wget, без разбора редиректа. Установщик обязан получить аргументы как есть,
# без --version.
make_latest
run_sut "$BASE" --yes
assert_eq "$STATUS" "7" "latest run reaches the installer"
assert_contains "$TMP/stdout.txt" "ARGS:--yes" "latest run forwards the arguments unchanged"
if grep -qF "ARGS:--version" "$TMP/stdout.txt"; then
    fail "latest run must not pin a version"
fi
assert_contains "$TMP/stdout.txt" "последний релиз" "latest run reports that the latest release is used"
ok

# ---------------------------------------------------------- wget fallback

# Минимальная система может не иметь curl. PATH собирается только из нужных
# утилит: curl отсутствует, wget подменён копированием file://-фикстур.
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$MOCK_BIN"
for tool in bash mktemp awk sha256sum rm cp cat; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$real" ]] || fail "cannot locate $tool for the wget fixture"
    ln -sf "$real" "$MOCK_BIN/$tool"
done
cat >"$MOCK_BIN/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
set -euo pipefail
dest=""
url=""
while (($#)); do
    case "$1" in
        -O) dest="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
[[ -n "$dest" && -n "$url" ]] || exit 2
printf '%s\n' "$url" >>"${WGET_CALLS:?}"
cp "${url#file://}" "$dest"
FAKE_WGET
chmod +x "$MOCK_BIN/wget"

WGET_CALLS="$TMP/wget-calls.txt"
: >"$WGET_CALLS"
export WGET_CALLS
run_sut_path "$MOCK_BIN" "$BASE" --version v9.9.9 --yes
assert_eq "$STATUS" "7" "wget-only run reaches the installer"
assert_contains "$TMP/stdout.txt" "ARGS:--version v9.9.9 --yes" \
    "wget-only run forwards the pinned version and arguments"
assert_contains "$WGET_CALLS" "install.sh" "wget is used for install.sh"
assert_contains "$WGET_CALLS" "SHA256SUMS" "wget is used for SHA256SUMS"
ok

# ------------------------------------------------------- no downloader

mkdir -p "$TMP/no-dl"
for tool in bash mktemp awk sha256sum rm cp cat; do
    ln -sf "$(command -v "$tool")" "$TMP/no-dl/$tool"
done
run_sut_path "$TMP/no-dl" "$BASE" --version v9.9.9
assert_eq "$STATUS" "20" "missing curl and wget exits 20"
assert_contains "$TMP/stderr.txt" "нужен curl или wget" "missing downloader names both tools"
assert_contains "$TMP/stderr.txt" "apt-get install" "missing downloader suggests the package command"
if grep -qF "ARGS:" "$TMP/stdout.txt"; then
    fail "installer ran without a downloader"
fi
ok

# ------------------------------------------------ download failure classes

# TLS: curl 60 / wget 5 — подсказка про ca-certificates, а не общее «не скачалось».
TLS_BIN="$TMP/tls-bin"
make_path_only_dir "$TLS_BIN"
printf '#!/usr/bin/env bash\nexit 60\n' >"$TLS_BIN/curl"
chmod +x "$TLS_BIN/curl"
run_sut_path "$TLS_BIN" "$BASE" --version v9.9.9
assert_eq "$STATUS" "20" "TLS failure exits 20"
assert_contains "$TMP/stderr.txt" "ca-certificates" "TLS failure names the package to install"
assert_contains "$TMP/stderr.txt" "TLS" "TLS failure is labelled as TLS"
ok

TLS_WGET_BIN="$TMP/tls-wget-bin"
make_path_only_dir "$TLS_WGET_BIN"
printf '#!/usr/bin/env bash\nexit 5\n' >"$TLS_WGET_BIN/wget"
chmod +x "$TLS_WGET_BIN/wget"
run_sut_path "$TLS_WGET_BIN" "$BASE" --version v9.9.9
assert_eq "$STATUS" "20" "wget TLS failure exits 20"
assert_contains "$TMP/stderr.txt" "ca-certificates" "wget TLS failure names the package"
ok

# HTTP-ошибка: curl 22 / wget 8 — ассет не найден, сеть при этом жива.
HTTP_BIN="$TMP/http-bin"
make_path_only_dir "$HTTP_BIN"
printf '#!/usr/bin/env bash\nexit 22\n' >"$HTTP_BIN/curl"
chmod +x "$HTTP_BIN/curl"
run_sut_path "$HTTP_BIN" "$BASE" --version v9.9.9
assert_eq "$STATUS" "20" "HTTP failure exits 20"
assert_contains "$TMP/stderr.txt" "HTTP" "HTTP failure is labelled as HTTP"
assert_contains "$TMP/stderr.txt" "не найден" "HTTP failure explains the asset is missing"
ok

printf 'bootstrap: %d assertions OK\n' "$pass"

