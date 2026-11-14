#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Section test for docker/entrypoint.sh — the self-provisioning container
# entrypoint (empty volume -> csqtt.env + install.json + TLS pair -> netfilter
# -> exec csqtt).
#
# The REAL script from the repository is executed; only the three external
# commands it talks to (csqtt, ip, iptables) are shims in $TMP/bin. hostname,
# date and openssl are the real binaries on purpose: certificate generation and
# JSON timestamps are part of the behaviour under test.
#
# Nothing outside mktemp -d is written: the config dir, the csqtt binary and the
# TUN device all go through the script's own test hooks
# (CSQTT_DOCKER_CONFIG_DIR / CSQTT_DOCKER_CSQTT_BIN / CSQTT_DOCKER_TUN_DEV).
# /dev/null stands in for /dev/net/tun because the check is `[ -c "$TUN_DEV" ]`
# and a character device is all it needs — no root, no modprobe.
#
# The ip shim answers the default route immediately, so the entrypoint's 90x1s
# WAN wait loop exits on the first iteration: the section runs in seconds.

set -euo pipefail
export LC_ALL=C
# The entrypoint must not inherit anything from the caller's shell/CI.
unset CSQTT_HOST CSQTT_PUBLIC_IP CSQTT_WEB_USER CSQTT_WEB_PASS \
    CSQTT_WEB_SECRET_PATH CSQTT_EVENTS CSQTT_DOCKER_CONFIG_DIR \
    CSQTT_DOCKER_CSQTT_BIN CSQTT_DOCKER_TUN_DEV 2>/dev/null || true

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/docker/entrypoint.sh"
[[ -f "$SCRIPT" ]] || {
    printf 'FAIL: нет %s\n' "$SCRIPT" >&2
    exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p -- "$BIN"

# Character device that exists without root; the entrypoint only checks `-c`.
TUN_OK=/dev/null
TUN_MISSING=/nonexistent/tun
# A hang here means the WAN loop never converged (shim broken) — fail instead.
STEP_TIMEOUT=60

PASS=0
CURRENT_OUT=""
CURRENT_ERR=""

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    if [[ -n "$CURRENT_OUT" && -f "$CURRENT_OUT" ]]; then
        printf -- '--- stdout ---\n%s\n' "$(<"$CURRENT_OUT")" >&2
    fi
    if [[ -n "$CURRENT_ERR" && -f "$CURRENT_ERR" ]]; then
        printf -- '--- stderr ---\n%s\n' "$(<"$CURRENT_ERR")" >&2
    fi
    exit 1
}

ok() {
    PASS=$((PASS + 1))
    printf '[OK] %s\n' "$1"
}

assert_exit() {
    local desc="$1" want="$2"
    [[ "$status_of_run" -eq "$want" ]] ||
        fail "$desc: exit $status_of_run, ожидался $want"
    ok "$desc"
}

assert_exists() {
    local desc="$1" path="$2"
    [[ -e "$path" ]] || fail "$desc: нет $path"
    ok "$desc"
}

assert_absent() {
    local desc="$1" path="$2"
    [[ ! -e "$path" ]] || fail "$desc: $path не должен существовать"
    ok "$desc"
}

assert_mode() {
    local desc="$1" path="$2" want="$3" got
    got="$(stat -c '%a' "$path" 2>/dev/null || printf 'missing')"
    [[ "$got" == "$want" ]] || fail "$desc: $path mode $got, ожидался $want"
    ok "$desc"
}

assert_has() {
    local desc="$1" file="$2" needle="$3"
    grep -Fq -- "$needle" "$file" || fail "$desc: нет '$needle' в $file"
    ok "$desc"
}

assert_lacks() {
    local desc="$1" file="$2" needle="$3"
    ! grep -Fq -- "$needle" "$file" || fail "$desc: не ожидалось '$needle' в $file"
    ok "$desc"
}

assert_count() {
    local desc="$1" file="$2" needle="$3" want="$4" got
    got="$(grep -Fc -- "$needle" "$file" || true)"
    [[ "$got" == "$want" ]] ||
        fail "$desc: '$needle' встречается $got раз(а) в $file, ожидалось $want"
    ok "$desc"
}

sha256_of() {
    sha256sum "$1" | awk '{ print $1 }'
}

# --- shims ----------------------------------------------------------------
# csqtt: --version answers for server_version(); every other invocation only
# records its argv so the test can assert the exec line.
cat >"$BIN/csqtt" <<'SHIM'
#!/bin/sh
set -eu
for arg in "$@"; do
    if [ "$arg" = "--version" ]; then
        printf 'csqtt 2.5.4\n'
        exit 0
    fi
done
printf '%s\n' "$*" >>"${CSQTT_ARGV_LOG:?}"
exit 0
SHIM

# ip: a public source address and one default route on eth0, which is enough for
# detect_public_ipv4/detect_wan_interface to succeed on the first pass.
cat >"$BIN/ip" <<'SHIM'
#!/bin/sh
set -eu
case "$*" in
    "-4 route get 8.8.8.8")
        printf '8.8.8.8 via 192.0.2.1 dev eth0 src 203.0.113.9 uid 0\n'
        exit 0
        ;;
    "-o -4 route show default")
        printf 'default via 192.0.2.1 dev eth0 proto static\n'
        exit 0
        ;;
esac
# link show / addr show / anything else: success, empty output.
exit 0
SHIM

# iptables: -S INPUT replays $IPT_LISTING (the "existing" ruleset); every other
# call is appended to $IPT_LOG verbatim, including the leading `-w 2`.
cat >"$BIN/iptables" <<'SHIM'
#!/bin/sh
set -eu
case "$*" in
    *"-S INPUT")
        if [ -n "${IPT_LISTING:-}" ] && [ -f "$IPT_LISTING" ]; then
            cat "$IPT_LISTING"
        fi
        exit 0
        ;;
esac
printf '%s\n' "$*" >>"${IPT_LOG:?}"
exit 0
SHIM
chmod 0755 "$BIN/csqtt" "$BIN/ip" "$BIN/iptables"

# --- runner ---------------------------------------------------------------
# run <dir> [argv...] — executes the real entrypoint against $RUN_CONFIG_DIR and
# captures stdout/stderr under <dir>. All other environment is cleared with
# `env -i` so a developer shell cannot influence the result.
RUN_CONFIG_DIR=""
RUN_HOST=""
RUN_TUN="$TUN_OK"
status_of_run=0

run() {
    local dir="$1"
    shift
    mkdir -p -- "$dir"
    CURRENT_OUT="$dir/stdout.txt"
    CURRENT_ERR="$dir/stderr.txt"
    local env_args=(
        "PATH=$BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "LC_ALL=C"
        "TMPDIR=$TMP"
        "CSQTT_DOCKER_CONFIG_DIR=$RUN_CONFIG_DIR"
        "CSQTT_DOCKER_CSQTT_BIN=$BIN/csqtt"
        "CSQTT_DOCKER_TUN_DEV=$RUN_TUN"
        "CSQTT_ARGV_LOG=$dir/csqtt.argv"
        "IPT_LOG=$dir/iptables.log"
        "IPT_LISTING=$dir/iptables.listing"
    )
    [[ -z "$RUN_HOST" ]] || env_args+=("CSQTT_HOST=$RUN_HOST")
    status_of_run=0
    env -i "${env_args[@]}" timeout "$STEP_TIMEOUT" "$SCRIPT" "$@" \
        >"$CURRENT_OUT" 2>"$CURRENT_ERR" || status_of_run=$?
}

# =========================================================================
# 1. Empty volume, domain host: identity, state, TLS pair, credential banner.
# =========================================================================
printf '=== 1. пустой том, домен ===\n'
C1="$TMP/case1"
C1_ETC="$C1/etc"
RUN_CONFIG_DIR="$C1_ETC"
RUN_HOST=example.org
RUN_TUN="$TUN_OK"
run "$C1"
assert_exit "домен: exit 0" 0

ENV1="$C1_ETC/csqtt.env"
STATE1="$C1_ETC/install.json"
CERT1="$C1_ETC/web_cert.pem"
KEY1="$C1_ETC/web_key.pem"

assert_mode "каталог конфига 0700" "$C1_ETC" 700
assert_mode "csqtt.env 0600" "$ENV1" 600
assert_mode "install.json 0600" "$STATE1" 600
assert_mode "web_cert.pem 0644" "$CERT1" 644
assert_mode "web_key.pem 0600" "$KEY1" 600

assert_has "install.json: panel_mode=domain" "$STATE1" '"panel_mode":"domain"'
assert_has "install.json: panel_host=example.org" "$STATE1" '"panel_host":"example.org"'
assert_has "install.json: web_port=443" "$STATE1" '"web_port":"443"'
assert_has "install.json: peer_port=46000" "$STATE1" '"peer_port":"46000"'
assert_has "install.json: mode=docker" "$STATE1" '"mode":"docker"'

# The banner is the only place the generated password is ever shown, so it must
# appear exactly once and its value must equal what landed in csqtt.env.
assert_count "домен: пароль напечатан один раз" "$CURRENT_OUT" 'Пароль:' 1
LOGIN1="$(sed -n 's/^CSQTT_WEB_USER="\(.*\)"$/\1/p' "$ENV1")"
PASS1="$(sed -n 's/^CSQTT_WEB_PASS="\(.*\)"$/\1/p' "$ENV1")"
[[ -n "$LOGIN1" && -n "$PASS1" ]] || fail "csqtt.env: логин/пароль не записаны"
ok "csqtt.env: логин и пароль непустые"
assert_has "баннер: логин из csqtt.env" "$CURRENT_OUT" "Логин:   $LOGIN1"
assert_has "баннер: пароль из csqtt.env" "$CURRENT_OUT" "Пароль:  $PASS1"

assert_has "argv: --listen 0.0.0.0:46000" "$C1/csqtt.argv" '--listen 0.0.0.0:46000'
assert_has "argv: --web-port 443 --config-dir <том>" "$C1/csqtt.argv" \
    "--web-port 443 --config-dir $C1_ETC"

openssl x509 -in "$CERT1" -noout -text >"$C1/cert.txt" 2>"$C1/cert.err" ||
    fail "openssl не разобрал $CERT1: $(<"$C1/cert.err")"
assert_has "сертификат: SAN DNS:example.org" "$C1/cert.txt" 'DNS:example.org'

# Recorded for the repeat-start case: a reboot must not touch the volume.
SHA_ENV1="$(sha256_of "$ENV1")"
SHA_STATE1="$(sha256_of "$STATE1")"
SHA_CERT1="$(sha256_of "$CERT1")"
SHA_KEY1="$(sha256_of "$KEY1")"

# =========================================================================
# 2. Same volume, hostile CLI: state wins, nothing is regenerated.
# =========================================================================
printf '=== 2. повторный старт + чужой CLI ===\n'
C2="$TMP/case2"
RUN_CONFIG_DIR="$C1_ETC"
RUN_HOST=""
RUN_TUN="$TUN_OK"
run "$C2" --web-port 47001 --listen 0.0.0.0:47000 --config-dir "$C1_ETC"
assert_exit "повторный старт: exit 0" 0

assert_has "warning про игнор --web-port" "$C2/stderr.txt" \
    'warning: --web-port 47001 ignored'
assert_has "warning называет сохранённый порт" "$C2/stderr.txt" 'keeps web/tcp 443'
assert_has "warning про игнор --listen" "$C2/stderr.txt" \
    'warning: --listen port 47000 ignored'
assert_count "повторный старт: пароль не печатается снова" "$C2/stdout.txt" 'Пароль:' 0

[[ "$(sha256_of "$ENV1")" == "$SHA_ENV1" ]] || fail "csqtt.env изменился на повторном старте"
ok "csqtt.env не изменился"
[[ "$(sha256_of "$STATE1")" == "$SHA_STATE1" ]] || fail "install.json изменился на повторном старте"
ok "install.json не изменился"
[[ "$(sha256_of "$CERT1")" == "$SHA_CERT1" ]] || fail "web_cert.pem перевыпущен на повторном старте"
ok "web_cert.pem не изменился"
[[ "$(sha256_of "$KEY1")" == "$SHA_KEY1" ]] || fail "web_key.pem перевыпущен на повторном старте"
ok "web_key.pem не изменился"

assert_has "argv: state wins, остаётся --web-port 443" "$C2/csqtt.argv" \
    "--web-port 443 --config-dir $C1_ETC"
assert_has "argv: state wins, остаётся peer 46000" "$C2/csqtt.argv" \
    '--listen 0.0.0.0:46000'
assert_lacks "argv: чужой --web-port 47001 не дошёл до сервера" "$C2/csqtt.argv" '47001'
assert_lacks "argv: чужой --listen 47000 не дошёл до сервера" "$C2/csqtt.argv" '47000'

# =========================================================================
# 3. Empty volume, public IPv4: ip mode, 46002, IP SAN.
# =========================================================================
printf '=== 3. IP-режим ===\n'
C3="$TMP/case3"
RUN_CONFIG_DIR="$C3/etc"
RUN_HOST=203.0.113.7
RUN_TUN="$TUN_OK"
run "$C3"
assert_exit "IP-режим: exit 0" 0

STATE3="$C3/etc/install.json"
CERT3="$C3/etc/web_cert.pem"
assert_has "IP-режим: panel_mode=ip" "$STATE3" '"panel_mode":"ip"'
assert_has "IP-режим: panel_host=203.0.113.7" "$STATE3" '"panel_host":"203.0.113.7"'
assert_has "IP-режим: web_port=46002" "$STATE3" '"web_port":"46002"'
assert_has "IP-режим: argv --web-port 46002" "$C3/csqtt.argv" \
    "--web-port 46002 --config-dir $C3/etc"
assert_count "IP-режим: пароль напечатан один раз" "$C3/stdout.txt" 'Пароль:' 1

openssl x509 -in "$CERT3" -noout -text >"$C3/cert.txt" 2>"$C3/cert.err" ||
    fail "openssl не разобрал $CERT3: $(<"$C3/cert.err")"
assert_has "IP-режим: SAN IP Address:203.0.113.7" "$C3/cert.txt" 'IP Address:203.0.113.7'
assert_lacks "IP-режим: в SAN нет DNS:" "$C3/cert.txt" 'DNS:'

# =========================================================================
# 4. Half a TLS pair must fail closed and stay untouched.
# =========================================================================
printf '=== 4. частичная TLS-пара ===\n'
C4="$TMP/case4"
mkdir -p "$C4/etc"
printf 'not a certificate, but the user owns it\n' >"$C4/etc/web_cert.pem"
CERT4="$C4/etc/web_cert.pem"
SHA_CERT4="$(sha256_of "$CERT4")"

RUN_CONFIG_DIR="$C4/etc"
RUN_HOST=example.org
RUN_TUN="$TUN_OK"
run "$C4"
assert_exit "неполная пара: exit 1" 1
assert_has "неполная пара: внятное сообщение" "$C4/stderr.txt" 'incomplete TLS pair'
assert_has "неполная пара: сообщение называет оба файла" "$C4/stderr.txt" \
    'web_cert.pem and web_key.pem'
[[ "$(sha256_of "$CERT4")" == "$SHA_CERT4" ]] ||
    fail "неполная пара: пользовательский web_cert.pem изменён"
ok "неполная пара: web_cert.pem не изменён"
assert_exists "неполная пара: web_cert.pem не удалён" "$CERT4"
assert_absent "неполная пара: web_key.pem не создан" "$C4/etc/web_key.pem"

# =========================================================================
# 5. No TUN device: refuse to start with a message that names the device.
# =========================================================================
printf '=== 5. нет TUN ===\n'
C5="$TMP/case5"
RUN_CONFIG_DIR="$C5/etc"
RUN_HOST=example.org
RUN_TUN="$TUN_MISSING"
run "$C5"
assert_exit "нет TUN: exit 1" 1
assert_has "нет TUN: сообщение называет устройство" "$C5/stderr.txt" "$TUN_MISSING is missing"
assert_has "нет TUN: подсказка про modprobe" "$C5/stderr.txt" 'modprobe tun'
[[ "$status_of_run" -ne 124 ]] || fail "нет TUN: entrypoint повис и был убит timeout"
ok "нет TUN: не дошло до exec csqtt"
assert_absent "нет TUN: csqtt не запускался" "$C5/csqtt.argv"

# =========================================================================
# 6. Stale managed INPUT rules: only foreign TCP ports are deleted.
# =========================================================================
printf '=== 6. stale netfilter ===\n'
C6="$TMP/case6"
mkdir -p "$C6"
cat >"$C6/iptables.listing" <<'LISTING'
-P INPUT ACCEPT
-A INPUT -p udp -m udp --dport 46000 -m comment --comment CSQTT_MANAGED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 46002 -m comment --comment CSQTT_MANAGED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 47001 -m comment --comment CSQTT_MANAGED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 80 -m comment --comment CSQTT_MANAGED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 443 -m comment --comment CSQTT_MANAGED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
LISTING

# Same volume as case 1 => effective web port is 443, peer port 46000.
RUN_CONFIG_DIR="$C1_ETC"
RUN_HOST=""
RUN_TUN="$TUN_OK"
run "$C6"
assert_exit "stale: exit 0" 0

IPT_LOG6="$C6/iptables.log"
assert_exists "stale: iptables вызывался" "$IPT_LOG6"
# 47001 is not one of the two "known" ports of the image (443/46002): the
# cleanup must be generic, "every managed INPUT tcp ACCEPT whose dport is not
# the effective one", not a 443<->46002 migration.
assert_count "stale: ровно два -D INPUT (46002 и 47001)" "$IPT_LOG6" '-D INPUT' 2
grep -q -- '-D INPUT -p tcp --dport 46002 ' "$IPT_LOG6" ||
    fail "stale: нет удаления tcp/46002: $(grep -F -- '-D' "$IPT_LOG6" || true)"
ok "stale: удалён tcp/46002"
grep -q -- '-D INPUT -p tcp --dport 47001 ' "$IPT_LOG6" ||
    fail "stale: нет удаления произвольного tcp/47001: $(grep -F -- '-D' "$IPT_LOG6" || true)"
ok "stale: удалён произвольный tcp/47001 (не только пара 443/46002)"
for kept in 80 443 46000; do
    ! grep -Eq -- "-D INPUT .*--dport ${kept}( |\$)" "$IPT_LOG6" ||
        fail "stale: удалено правило для порта $kept, который должен остаться"
    ok "stale: порт $kept не удалён"
done
assert_count "stale: существующий ACCEPT не добавлялся повторно" "$IPT_LOG6" '-I INPUT' 0

# =========================================================================
# 7. Typos and a foreign volume path die before any side effect.
# =========================================================================
printf '=== 7. опечатка / запрещённый config-dir ===\n'
C7="$TMP/case7"
RUN_CONFIG_DIR="$C7/etc"
RUN_HOST=example.org
RUN_TUN="$TUN_OK"
run "$C7/a" --webb-port 443
assert_exit "опечатка --webb-port: exit 1" 1
assert_has "опечатка: сообщение про неизвестный аргумент" "$C7/a/stderr.txt" \
    "unknown argument '--webb-port'"
assert_has "опечатка: показана подсказка" "$C7/a/stderr.txt" 'Использование:'
assert_absent "опечатка: каталог конфига не создан" "$C7/etc"
assert_absent "опечатка: csqtt.env не создан" "$C7/etc/csqtt.env"
assert_absent "опечатка: csqtt не запускался" "$C7/a/csqtt.argv"

# The message is rendered with the effective mount point, so it is asserted
# against CSQTT_DOCKER_CONFIG_DIR rather than the /etc/csqtt literal: pointing
# the hook at the real /etc/csqtt would let a regression write outside the
# sandbox on a root runner.
RUN_CONFIG_DIR="$C7/etc"
RUN_HOST=example.org
RUN_TUN="$TUN_OK"
run "$C7/b" --config-dir /tmp/other
assert_exit "чужой --config-dir: exit 1" 1
assert_has "чужой --config-dir: отказ называет флаг и путь" "$C7/b/stderr.txt" \
    "--config-dir '/tmp/other' is not supported"
assert_has "чужой --config-dir: сказано, где смонтирован том" "$C7/b/stderr.txt" \
    "data volume is mounted at $C7/etc"
assert_absent "чужой --config-dir: каталог конфига не создан" "$C7/etc"
assert_absent "чужой --config-dir: csqtt не запускался" "$C7/b/csqtt.argv"

# =========================================================================
# 8. Partial install.json (crashed first start) + CLI: the holes are filled
#    from the flags, everything already in the state is kept.
# =========================================================================
printf '=== 8. неполный install.json + CLI ===\n'
C8="$TMP/case8"

# 8a. Both ports are missing: the flags close both holes.
mkdir -p "$C8/a/etc"
cat >"$C8/a/etc/install.json" <<'STATE'
{"version":"2.5.4","mode":"docker","panel_mode":"domain","panel_host":"example.org","ssh_port":"22","tls":"selfsigned","installed_at":"1","updated_at":"1"}
STATE
STATE8="$C8/a/etc/install.json"

RUN_CONFIG_DIR="$C8/a/etc"
RUN_HOST=""
RUN_TUN="$TUN_OK"
run "$C8/a" --web-port 47002 --listen 0.0.0.0:47000
assert_exit "неполный state: exit 0" 0

assert_has "неполный state: web_port закрыт из CLI" "$STATE8" '"web_port":"47002"'
assert_has "неполный state: peer_port закрыт из CLI" "$STATE8" '"peer_port":"47000"'
assert_has "неполный state: installed_at сохранён" "$STATE8" '"installed_at":"1"'
assert_has "неполный state: panel_host сохранён" "$STATE8" '"panel_host":"example.org"'
assert_has "неполный state: panel_mode сохранён" "$STATE8" '"panel_mode":"domain"'
assert_has "неполный state: state перезаписан" "$C8/a/stderr.txt" \
    "wrote $STATE8"
assert_has "неполный state: argv --web-port 47002" "$C8/a/csqtt.argv" \
    "--web-port 47002 --config-dir $C8/a/etc"
assert_has "неполный state: argv --listen 0.0.0.0:47000" "$C8/a/csqtt.argv" \
    '--listen 0.0.0.0:47000'
assert_mode "неполный state: install.json 0600" "$STATE8" 600
assert_mode "неполный state: csqtt.env 0600" "$C8/a/etc/csqtt.env" 600
assert_exists "неполный state: TLS-пара создана" "$C8/a/etc/web_cert.pem"
assert_exists "неполный state: TLS-ключ создан" "$C8/a/etc/web_key.pem"
assert_count "неполный state: пароль напечатан один раз" "$C8/a/stdout.txt" 'Пароль:' 1

# 8b. Only web_port is missing: the valid peer_port in state must survive, the
# flag only closes the hole it is allowed to close.
mkdir -p "$C8/b/etc"
cat >"$C8/b/etc/install.json" <<'STATE'
{"version":"2.5.4","mode":"docker","panel_mode":"domain","panel_host":"example.org","peer_port":"46000","ssh_port":"22","tls":"selfsigned","installed_at":"1","updated_at":"1"}
STATE
STATE8B="$C8/b/etc/install.json"

RUN_CONFIG_DIR="$C8/b/etc"
RUN_HOST=""
RUN_TUN="$TUN_OK"
run "$C8/b" --web-port 47002 --listen 0.0.0.0:47000
assert_exit "неполный state (только web_port): exit 0" 0
assert_has "неполный state (только web_port): дырка закрыта" "$STATE8B" '"web_port":"47002"'
assert_has "неполный state (только web_port): валидный peer_port сохранён" "$STATE8B" \
    '"peer_port":"46000"'
assert_lacks "неполный state (только web_port): --listen не переписал state" "$STATE8B" \
    '"peer_port":"47000"'
assert_has "неполный state (только web_port): argv peer 46000" "$C8/b/csqtt.argv" \
    '--listen 0.0.0.0:46000'
assert_has "неполный state (только web_port): argv web 47002" "$C8/b/csqtt.argv" \
    '--web-port 47002'

# =========================================================================
# 9. Out-of-range CLI port dies before the volume is touched.
# =========================================================================
printf '=== 9. порт вне диапазона на CLI ===\n'
C9="$TMP/case9"
RUN_CONFIG_DIR="$C9/a/etc"
RUN_HOST=example.org
RUN_TUN="$TUN_OK"
run "$C9/a" --web-port 70000
assert_exit "--web-port 70000: exit 1" 1
assert_has "--web-port 70000: сообщение про диапазон" "$C9/a/stderr.txt" \
    "--web-port expects a port 1..65535, got '70000'"
assert_absent "--web-port 70000: каталог конфига не создан" "$C9/a/etc"
assert_absent "--web-port 70000: csqtt не запускался" "$C9/a/csqtt.argv"

# A 20-digit number must not reach test(1): `[ N -ge 1 ]` would fail on it and
# the value would slip through, so the length check has to catch it first.
HUGE_PORT=99999999999999999999
RUN_CONFIG_DIR="$C9/b/etc"
RUN_HOST=example.org
RUN_TUN="$TUN_OK"
run "$C9/b" --web-port "$HUGE_PORT"
assert_exit "--web-port $HUGE_PORT: exit 1" 1
assert_has "длинный порт: сообщение про диапазон" "$C9/b/stderr.txt" \
    "--web-port expects a port 1..65535, got '$HUGE_PORT'"
assert_absent "длинный порт: каталог конфига не создан" "$C9/b/etc"
assert_absent "длинный порт: csqtt не запускался" "$C9/b/csqtt.argv"

# =========================================================================
# 10. Complete install.json with an out-of-range web_port: the value is
#     reported and replaced by the default instead of being exec'd.
# =========================================================================
printf '=== 10. install.json с web_port вне диапазона ===\n'
C10="$TMP/case10"
mkdir -p "$C10/etc"
cat >"$C10/etc/install.json" <<'STATE'
{"version":"2.5.4","mode":"docker","panel_mode":"domain","panel_host":"example.org","peer_port":"46000","web_port":"99999","ssh_port":"22","tls":"selfsigned","installed_at":"1","updated_at":"1"}
STATE
STATE10="$C10/etc/install.json"

RUN_CONFIG_DIR="$C10/etc"
RUN_HOST=""
RUN_TUN="$TUN_OK"
run "$C10"
assert_exit "state web_port 99999: exit 0" 0
assert_has "state web_port 99999: предупреждение" "$C10/stderr.txt" \
    "ignoring out-of-range web_port '99999'"
assert_has "state web_port 99999: в state записан дефолт домена" "$STATE10" '"web_port":"443"'
assert_has "state web_port 99999: валидный peer_port сохранён" "$STATE10" '"peer_port":"46000"'
assert_has "state web_port 99999: installed_at сохранён" "$STATE10" '"installed_at":"1"'
assert_has "state web_port 99999: argv --web-port 443" "$C10/csqtt.argv" \
    "--web-port 443 --config-dir $C10/etc"
assert_lacks "state web_port 99999: мусор не дошёл до сервера" "$C10/csqtt.argv" '99999'
assert_count "state web_port 99999: пароль напечатан один раз" "$C10/stdout.txt" 'Пароль:' 1

printf 'docker-entrypoint: %d cases OK\n' "$PASS"
