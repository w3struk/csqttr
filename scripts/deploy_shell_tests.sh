#!/usr/bin/env bash
#
# Поведенческие тесты scripts/install.sh.
#
#   НИКОГДА НЕ ЗАПУСКАТЬ НА БОЕВОЙ МАШИНЕ.
#
# Раннер исполняет отдельные функции установщика. Некоторые из них на живой
# системе разрушительны: `all_csqtt_process_pids` обходит /proc и убивает любой
# процесс csqtt (на рабочей машине может жить настоящий rust-клиент),
# `remove_csqtt_tun_interface` делает настоящий `ip link del csqtt1` (это
# TUN-интерфейс самого проекта), `remove_all_csqtt_docker_containers` — настоящий
# `docker rm -f`.
#
# Поэтому:
#   1. раннер отказывается работать под root (обойти можно только явным
#      CSQTT_ALLOW_ROOT_TESTS=1, и это осознанное решение того, кто это делает);
#   2. t_begin подменяет все CSQTT_* runtime-пути корнями внутри SANDBOX, а
#      разрушительные кейсы дополнительно требуют t_require_sandbox_runtime_paths;
#      поэтому csqtt_cleanup вызывается только на путях песочницы;
#   3. certbot, iptables, iptables-save, nft, systemctl, ss, install, docker,
#      ip, openssl, curl, sysctl и uname -m
#      подменяются заглушками в $MOCK_BIN, которые первыми стоят в PATH.
#
# Запуск: ./scripts/deploy_shell_tests.sh
# Один кейс: ./scripts/deploy_shell_tests.sh test_domain_selects_domain_mode

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
DEPLOY_SCRIPT="${REPO_ROOT}/scripts/install.sh"

ORIGINAL_PATH="$PATH"
PASSED=0
FAILED=0
FAILED_NAMES=()

if [ ! -f "$DEPLOY_SCRIPT" ]; then
    printf 'Не найден scripts/install.sh: %s\n' "$DEPLOY_SCRIPT" >&2
    exit 1
fi

# Предохранитель: под root заглушки обходятся не везде, а rm -f /usr/local/bin/csqtt
# и ip link del сработают по-настоящему. CSQTT_EUID_OVERRIDE существует только
# для того, чтобы сам предохранитель был проверяемым тестом.
require_non_root() {
    local euid="${CSQTT_EUID_OVERRIDE:-${EUID}}"
    [ "$euid" -eq 0 ] || return 0
    [ "${CSQTT_ALLOW_ROOT_TESTS:-}" = "1" ] && return 0
    printf 'deploy_shell_tests.sh: запуск под root запрещён: тесты вызывают разрушительные\n' >&2
    printf 'функции установщика. Если это осознанное решение, задайте CSQTT_ALLOW_ROOT_TESTS=1.\n' >&2
    return 1
}

require_non_root || exit 1

# ---------------------------------------------------------------------------
# Песочница и заглушки
# ---------------------------------------------------------------------------

SANDBOX=""
MOCK_BIN=""
CALL_LOG=""
FAKE_LE=""
FAKE_CFG=""
STUB_STATE_DIR=""
T_OWNER_PID=""
T_TEST_NAME=""

STUB_NAMES=(certbot iptables iptables-save nft systemctl ss install docker ip openssl curl sysctl uname \
    modprobe update-grub grub2-mkconfig netplan apt-get dnf yum apk iptables-restore)

write_stub() {
    local name="$1"
    local file="$MOCK_BIN/$name"
    local real_openssl real_install real_uname
    real_openssl="$(PATH="$ORIGINAL_PATH" command -v openssl || true)"
    real_install="$(PATH="$ORIGINAL_PATH" command -v install || true)"
    real_uname="$(PATH="$ORIGINAL_PATH" command -v uname)"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -u'
        printf 'stub_name=%q\n' "$name"
        printf 'real_openssl=%q\n' "$real_openssl"
        printf 'real_install=%q\n' "$real_install"
        printf 'real_uname=%q\n' "$real_uname"
        cat <<'STUB_COMMON'
state_dir="${STUB_STATE_DIR:?}"
stdout_file="$state_dir/$stub_name.stdout"
exit_file="$state_dir/$stub_name.exit"
fail_file="$state_dir/$stub_name.fail_times"

log_call() {
    printf '%s %s\n' "$stub_name" "$*" >> "${CALL_LOG:?}"
}

# Бюджет неуспехов: t_stub_fail_times <команда> <n>.
consume_fail() {
    local remaining
    [ -f "$fail_file" ] || return 1
    remaining="$(cat "$fail_file" 2>/dev/null || true)"
    case "$remaining" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$remaining" -gt 0 ] || return 1
    printf '%s\n' "$((remaining - 1))" > "$fail_file"
    return 0
}

print_stdout() {
    [ -f "$stdout_file" ] && cat "$stdout_file"
    return 0
}

forced_exit_code() {
    local code=""
    [ -f "$exit_file" ] && code="$(cat "$exit_file" 2>/dev/null || true)"
    case "$code" in
        ''|*[!0-9]*) printf '%s' 0 ;;
        *) printf '%s' "$code" ;;
    esac
}

finish() {
    exit "$(forced_exit_code)"
}
STUB_COMMON

        case "$name" in
            certbot)
                cat <<'STUB_CERTBOT'
# `certbot certonly --help all` используется как проба поддержки нужного режиму
# флага. Такой вызов НЕ пишется в CALL_LOG: иначе ensure_letsencrypt_client решит,
# что клиент не поддерживает флаг, уйдёт в python3 -m venv /opt/csqtt-certbot
# и упадёт с отказом записи.
if printf '%s' " $* " | grep -q -- ' --help '; then
    if [ "$(cat "$state_dir/certbot.ip_support" 2>/dev/null || printf '%s' 1)" = "1" ]; then
        printf '%s\n' '--ip-address' '--domains'
    fi
    exit 0
fi
log_call "$@"
if printf '%s' " $* " | grep -q -- ' certonly '; then
    if consume_fail; then
        exit 1
    fi
    [ "$(forced_exit_code)" -eq 0 ] || finish
    cert_name=""
    domain=""
    ip_address=""
    previous=""
    for argument in "$@"; do
        case "$previous" in
            --cert-name) cert_name="$argument" ;;
            --domains|-d) domain="$argument" ;;
            --ip-address) ip_address="$argument" ;;
        esac
        case "$argument" in
            --cert-name=*) cert_name="${argument#--cert-name=}" ;;
            --domains=*) domain="${argument#--domains=}" ;;
            --ip-address=*) ip_address="${argument#--ip-address=}" ;;
        esac
        previous="$argument"
    done
    if [ -z "$cert_name" ]; then
        exit 0
    fi
    # «Выпуск» обязан быть настоящим сертификатом: установщик затем читает
    # файлы, разбирает issuer и SAN. Поэтому сертификат генерируется реальным
    # openssl, но вызов пишется в CALL_LOG под именем certbot-fixture, чтобы
    # проверки «в доменном режиме нет openssl req -x509» не ловили фикстуру.
    common_name="${domain:-$ip_address}"
    if [ -n "$domain" ]; then
        san="DNS:${domain}"
    else
        san="IP:${ip_address}"
    fi
    printf 'certbot-fixture %s\n' "req -x509 -newkey rsa:2048 -nodes -days 90 -subj /O=Let's Encrypt/CN=${common_name} -addext subjectAltName=${san}" >> "$CALL_LOG"
    mkdir -p "$FAKE_LE/live/$cert_name"
    "$real_openssl" req -x509 -newkey rsa:2048 -nodes -days 90 \
        -subj "/O=Let's Encrypt/CN=${common_name}" \
        -addext "subjectAltName = ${san}" \
        -keyout "$FAKE_LE/live/$cert_name/privkey.pem" \
        -out "$FAKE_LE/live/$cert_name/fullchain.pem" >/dev/null 2>&1 || exit 1
    exit 0
fi
print_stdout
finish
STUB_CERTBOT
                ;;
            uname)
                cat <<'STUB_UNAME'
# Подменяется только архитектура VPS; прочие запросы сохраняют настоящий uname.
if [ "$#" -eq 1 ] && [ "$1" = "-m" ]; then
    log_call "$@"
    if consume_fail; then
        exit 1
    fi
    if [ -f "$stdout_file" ]; then
        print_stdout
    else
        printf '%s\n' amd64
    fi
    finish
fi
exec "$real_uname" "$@"
STUB_UNAME
                ;;
            openssl)
                cat <<'STUB_OPENSSL'
# Наблюдение и настоящее поведение одновременно: SAN, issuer и checkend
# разбирают реальный сертификат.
log_call "$@"
exec "$real_openssl" "$@"
STUB_OPENSSL
                ;;
            install)
                cat <<'STUB_INSTALL'
# Бюджет неуспехов t_stub_fail_times относится только к установке файлов:
# install -d в write_letsencrypt_renewal_helper идёт первым и не должен
# съедать отказ активации сертификата (Review Focus #4).
case " $* " in
    *" -d "*)
        log_call "$@"
        exec "$real_install" "$@"
        ;;
esac
log_call "$@"
if consume_fail; then
    exit 1
fi
[ "$(forced_exit_code)" -eq 0 ] || finish
exec "$real_install" "$@"
STUB_INSTALL
                ;;
            systemctl)
                cat <<'STUB_SYSTEMCTL'
log_call "$@"
# По умолчанию службы не активны: иначе stop_csqtt_docker_prereq решит, что
# остановка не удалась, и завершит установку. Явный переключатель — файл
# systemctl.active=1.
case " $* " in
    *" is-active "*)
        if [ "$(cat "$state_dir/systemctl.active" 2>/dev/null || printf '%s' 0)" = "1" ]; then
            exit 0
        fi
        exit 1
        ;;
esac
# Момент включения таймера фиксируется вместе с фактом существования нового
# хелпера: так проверяется, что легаси-файл удаляется не раньше, чем появится
# letsencrypt.env и хелпер.
case " $* " in
    *" enable --now "*)
        if [ -f "${CSQTT_LE_RENEW_HELPER:-}" ]; then
            printf '%s\n' 'systemctl-marker renew-helper=present' >> "${CALL_LOG:?}"
        else
            printf '%s\n' 'systemctl-marker renew-helper=missing' >> "${CALL_LOG:?}"
        fi
        ;;
esac
if consume_fail; then
    exit 1
fi
print_stdout
finish
STUB_SYSTEMCTL
                ;;
            iptables)
                cat <<'STUB_IPTABLES'
# Для iptables бюджет неуспехов из t_stub_fail_times относится ТОЛЬКО к -D:
# ограниченный цикл удаления проверяется и на успехе, и на постоянном неуспехе,
# а -S/-C/-I при этом должны работать штатно.
verb="$1"
if [ "$verb" = "-w" ]; then
    verb="$3"
fi
case "$verb" in
    -S)
        log_call "$@"
        print_stdout
        exit 0
        ;;
    -D)
        log_call "$@"
        if consume_fail; then
            exit 1
        fi
        finish
        ;;
esac
log_call "$@"
if consume_fail; then
    exit 1
fi
print_stdout
finish
STUB_IPTABLES
                ;;
            curl)
                cat <<'STUB_CURL'
# Обслуживает фикстуры релиза: URL -> $STUB_STATE_DIR/http/<host>/<path>.
# -o/--output копирует фикстуру, иначе содержимое идёт в stdout. Для
# `-sIL -o /dev/null -w '%{url_effective}'` отдаёт $STUB_STATE_DIR/latest-url.
log_call "$@"
if consume_fail; then
    exit 1
fi
[ "$(forced_exit_code)" -eq 0 ] || finish

output=""
write_out=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output) output="${2:-}"; shift 2 ;;
        -w|--write-out) write_out="${2:-}"; shift 2 ;;
        --proto|--retry|--connect-timeout|--max-time) shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done

if printf '%s' "$write_out" | grep -q 'url_effective'; then
    [ -f "$state_dir/latest-url" ] || exit 22
    cat "$state_dir/latest-url"
    exit 0
fi
if printf '%s' "$write_out" | grep -q 'http_code'; then
    printf '%s' 200
    exit 0
fi
[ -n "$url" ] || exit 2
path="${url#*://}"
path="${path%%\?*}"
path="${path%%#*}"
path="${path%/}"
fixture="$state_dir/http/$path"
[ -f "$fixture" ] || exit 22
if [ -n "$output" ]; then
    [ "$output" = "/dev/null" ] && exit 0
    mkdir -p -- "$(dirname -- "$output")" 2>/dev/null || true
    cp -- "$fixture" "$output" || exit 23
else
    cat -- "$fixture"
fi
exit 0
STUB_CURL
                ;;
            docker)
                cat <<'STUB_DOCKER'
# Эмуляция docker для rollback-кейсов. Состояние — каталоги в $state_dir/docker:
# containers/<name>/{name,id,image_tag,image_id,running}, images/<id>, tags/<tag>.
# Неизвестная команда — успешный no-op.
docker_state="$state_dir/docker"
containers_dir="$docker_state/containers"
images_dir="$docker_state/images"
tags_dir="$docker_state/tags"
mkdir -p "$containers_dir" "$images_dir" "$tags_dir"

sanitize_ref() {
    printf '%s' "$1" | tr '/:' '__'
}

image_id_for() {
    local ref="$1" f
    f="$tags_dir/$(sanitize_ref "$ref")"
    if [ -f "$f" ]; then
        cat "$f"
        return 0
    fi
    f="$images_dir/$(sanitize_ref "$ref")"
    if [ -f "$f" ]; then
        printf '%s\n' "$ref"
        return 0
    fi
    return 1
}

log_call "$@"
if consume_fail; then
    exit 1
fi
if [ -f "$exit_file" ]; then
    finish
fi

cmd="${1:-}"
[ "$#" -eq 0 ] || shift
case "$cmd" in
    inspect)
        format=""
        target=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --format) format="${2:-}"; shift 2 ;;
                --format=*) format="${1#--format=}"; shift ;;
                -*) shift ;;
                *) target="$1"; shift ;;
            esac
        done
        [ -n "$target" ] || exit 1
        cdir="$containers_dir/$target"
        [ -d "$cdir" ] || exit 1
        case "$format" in
            ''|'{{.Id}}')
                cat "$cdir/id"
                ;;
            '{{.Image}}')
                cat "$cdir/image_id"
                ;;
            '{{.Config.Image}}')
                cat "$cdir/image_tag"
                ;;
            '{{.State.Running}}')
                cat "$cdir/running"
                ;;
            '{{.Name}}')
                printf '/%s\n' "$(cat "$cdir/name")"
                ;;
            '{{.State.Running}}|{{.State.Pid}}|{{.RestartCount}}')
                printf '%s|4242|0\n' "$(cat "$cdir/running")"
                ;;
            *)
                # docker_container_runs_csqtt: имя|образ|... — достаточно, чтобы
                # контейнер распознавался как наш runtime (имя/образ `csqtt`).
                printf '/%s|%s|null|null|\n' "$(cat "$cdir/name")" "$(cat "$cdir/image_tag")"
                ;;
        esac
        exit 0
        ;;
    image)
        sub="${1:-}"
        [ "$#" -eq 0 ] || shift
        case "$sub" in
            inspect)
                format=""
                ref=""
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --format) format="${2:-}"; shift 2 ;;
                        --format=*) format="${1#--format=}"; shift ;;
                        -*) shift ;;
                        *) ref="$1"; shift ;;
                    esac
                done
                resolved="$(image_id_for "$ref")" || exit 1
                if [ -n "$format" ]; then
                    printf '%s\n' "$resolved"
                fi
                exit 0
                ;;
            rm)
                ref=""
                for arg in "$@"; do
                    case "$arg" in -*) ;; *) ref="$arg" ;; esac
                done
                if [ -n "$ref" ]; then
                    f="$tags_dir/$(sanitize_ref "$ref")"
                    if [ -f "$f" ]; then
                        id="$(cat "$f")"
                        rm -f "$f" "$images_dir/$(sanitize_ref "$id")"
                    else
                        rm -f "$images_dir/$(sanitize_ref "$ref")"
                    fi
                fi
                exit 0
                ;;
        esac
        exit 0
        ;;
    tag)
        src="${1:-}"
        dst="${2:-}"
        resolved="$(image_id_for "$src")" || exit 0
        printf '%s\n' "$resolved" > "$tags_dir/$(sanitize_ref "$dst")"
        exit 0
        ;;
    run)
        name=""
        image=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --name) name="${2:-}"; shift 2 ;;
                --label|--restart|--network|--cap-drop|--cap-add|--device|--security-opt|--stop-timeout|--ulimit|--env-file|--env|--volume|--mount|--entrypoint)
                    shift 2
                    ;;
                -*) shift ;;
                *)
                    if [ -z "$image" ]; then
                        image="$1"
                    fi
                    shift
                    ;;
            esac
        done
        # `docker run --rm` без --name — это проба: контейнер не создаётся.
        [ -n "$name" ] || exit 0
        cdir="$containers_dir/$name"
        mkdir -p "$cdir"
        printf '%s\n' "$name" > "$cdir/name"
        printf '%s\n' "cid-$name" > "$cdir/id"
        printf '%s\n' "$image" > "$cdir/image_tag"
        if resolved="$(image_id_for "$image")"; then
            printf '%s\n' "$resolved" > "$cdir/image_id"
        else
            printf '%s\n' "$image" > "$cdir/image_id"
        fi
        printf 'true\n' > "$cdir/running"
        printf 'cid-%s\n' "$name"
        exit 0
        ;;
    ps)
        for cdir in "$containers_dir"/*/; do
            [ -d "$cdir" ] || continue
            cat "$cdir/id"
        done
        exit 0
        ;;
    stop|kill)
        container=""
        for arg in "$@"; do
            case "$arg" in -*) ;; *) container="$arg" ;; esac
        done
        [ -n "$container" ] || exit 0
        printf 'false\n' > "$containers_dir/$container/running" 2>/dev/null || true
        exit 0
        ;;
    start)
        container=""
        for arg in "$@"; do
            case "$arg" in -*) ;; *) container="$arg" ;; esac
        done
        printf 'true\n' > "$containers_dir/$container/running" 2>/dev/null || true
        exit 0
        ;;
    rm)
        for arg in "$@"; do
            case "$arg" in -*) ;; *) rm -rf "$containers_dir/$arg" ;; esac
        done
        exit 0
        ;;
esac
print_stdout
finish
STUB_DOCKER
                ;;
            *)
                cat <<'STUB_PLAIN'
log_call "$@"
if consume_fail; then
    exit 1
fi
print_stdout
finish
STUB_PLAIN
                ;;
        esac
    } > "$file"
    chmod 0755 "$file"
}

write_stubs() {
    local name
    for name in "${STUB_NAMES[@]}"; do
        write_stub "$name"
    done
}

t_begin() {
    T_TEST_NAME="$1"
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/csqtt-deploy-tests.XXXXXX")"
    MOCK_BIN="$SANDBOX/bin"
    STUB_STATE_DIR="$SANDBOX/state"
    CALL_LOG="$SANDBOX/calls.log"
    FAKE_LE="$SANDBOX/le"
    FAKE_CFG="$SANDBOX/cfg"
    mkdir -p "$MOCK_BIN" "$STUB_STATE_DIR" "$FAKE_LE" "$FAKE_CFG"
    : > "$CALL_LOG"
    write_stubs
    T_OWNER_PID="${BASHPID:-$$}"
    # shellcheck disable=SC2064
    trap 't_end' EXIT

    export MOCK_BIN STUB_STATE_DIR CALL_LOG FAKE_LE FAKE_CFG
    export PATH="$MOCK_BIN:$ORIGINAL_PATH"
    export CSQTT_XT_WAIT=1
    export CSQTT_CONFIG_DIR="$FAKE_CFG"
    export CSQTT_INSTALL_LOG_FILE="$SANDBOX/install.log"
    export CSQTT_LE_ROOT="$FAKE_LE"
    export CSQTT_LE_STATE_FILE="$FAKE_CFG/letsencrypt.env"
    export CSQTT_LE_RENEW_HELPER="$FAKE_CFG/csqtt-letsencrypt-renew.sh"
    export CSQTT_LE_CERTBOT="$MOCK_BIN/certbot"
    export CSQTT_LE_VENV="$SANDBOX/certbot-venv"
    # Work-dir всегда внутри песочницы: кандидат, SHA256SUMS и csqtt.env.candidate
    # не должны переживать тест в общем /tmp.
    export CSQTT_WORK_DIR="$SANDBOX/work"
    export CSQTT_WORK_DIR_OWNED=0
    export CSQTT_PUBLIC_IP=""
    # Все runtime-корни — внутри песочницы. Без этого установщик снова начнёт
    # писать в /usr/local, /etc/systemd, /run и /proc/sys хоста.
    export CSQTT_BIN_DIR="$SANDBOX/usr/local/bin"
    export CSQTT_LIB_DIR="$SANDBOX/usr/local/lib/csqtt"
    export CSQTT_CLI_DIR="$SANDBOX/usr/local/lib/csqtt-installer"
    export CSQTT_SYSTEMD_DIR="$SANDBOX/etc/systemd/system"
    export CSQTT_RUN_DIR="$SANDBOX/run/csqtt"
    export CSQTT_INSTALL_LOCK="$SANDBOX/run/csqtt-install.lock"
    export CSQTT_SYSCTL_DIR="$SANDBOX/etc/sysctl.d"
    export CSQTT_MODULES_LOAD_DIR="$SANDBOX/etc/modules-load.d"
    export CSQTT_PROC_SYS_DIR="$SANDBOX/proc/sys"
    export CSQTT_GRUB_FILE="$SANDBOX/etc/default/grub"
    export CSQTT_CRON_DIR="$SANDBOX/etc/cron.d"
    export CSQTT_OPT_DIR="$SANDBOX/opt/csqtt-certbot"
    export CSQTT_VAR_DIR="$SANDBOX/var/lib/csqtt"
    mkdir -p "$CSQTT_BIN_DIR" "$CSQTT_SYSTEMD_DIR" "$CSQTT_RUN_DIR" \
        "$CSQTT_SYSCTL_DIR" "$CSQTT_MODULES_LOAD_DIR" "$CSQTT_PROC_SYS_DIR" \
        "$CSQTT_CRON_DIR" "$(dirname "$CSQTT_GRUB_FILE")"
    unset PANEL_MODE PANEL_HOST CSQTT_LE_IDENTIFIER T_RENEW_BEFORE T_RENEW_HTTP_PORT
    # Явные web-доступы не должны протекать из окружения тестового раннера в
    # fresh-кейсы: иначе сгенерированные значения не проверить.
    unset CSQTT_WEB_USER CSQTT_WEB_PASS CSQTT_WEB_SECRET_PATH CSQTT_ASSUME_TTY
}

# Страховка для разрушительных кейсов: каждый runtime-корень обязан лежать в
# песочнице. Если кто-то добавит тест без t_begin или переопределит корень на
# host-путь, проверка упадёт до запуска установщика.
t_require_sandbox_runtime_paths() {
    local value
    for value in "$CSQTT_BIN_DIR" "$CSQTT_LIB_DIR" "$CSQTT_CLI_DIR" \
                 "$CSQTT_SYSTEMD_DIR" "$CSQTT_RUN_DIR" "$CSQTT_INSTALL_LOCK" \
                 "$CSQTT_SYSCTL_DIR" "$CSQTT_MODULES_LOAD_DIR" "$CSQTT_PROC_SYS_DIR" \
                 "$CSQTT_GRUB_FILE" "$CSQTT_CRON_DIR" \
                 "$CSQTT_OPT_DIR" "$CSQTT_VAR_DIR" \
                 "$CSQTT_LE_RENEW_HELPER"; do
        [[ "$value" == "$SANDBOX"/* ]] || t_fail "runtime path outside sandbox: $value"
    done
}

# t_seed_previous_runtime — старый runtime в песочнице: бинарник, unit, helper'ы,
# LE-таймер, env и БД. Нужен кейсам snapshot/rollback: без предыдущего runtime
# откатывать нечего.
t_seed_previous_runtime() {
    mkdir -p "$CSQTT_LIB_DIR" "$CSQTT_SYSTEMD_DIR"
    printf 'old-binary\n' > "$CSQTT_BIN_DIR/csqtt"
    chmod 0755 "$CSQTT_BIN_DIR/csqtt"
    printf 'old-env\n' > "$FAKE_CFG/csqtt.env"
    printf 'old-db\n' > "$FAKE_CFG/csqtt.db"
    printf 'old-wal\n' > "$FAKE_CFG/csqtt.db-wal"
    printf 'old-shm\n' > "$FAKE_CFG/csqtt.db-shm"
    printf 'old-helper\n' > "$CSQTT_LIB_DIR/network-up.sh"
    printf 'old-recover\n' > "$CSQTT_LIB_DIR/tun-recover.sh"
    mkdir -p "$(dirname "$CSQTT_LE_RENEW_HELPER")"
    printf 'old-le-helper\n' > "$CSQTT_LE_RENEW_HELPER"
    cat > "$CSQTT_SYSTEMD_DIR/csqtt.service" <<EOF
[Service]
ExecStart=${CSQTT_BIN_DIR}/csqtt --listen 0.0.0.0:46000 --web-port 46002 --config-dir ${CSQTT_CONFIG_DIR}
EOF
    printf '[Timer]\n' > "$CSQTT_SYSTEMD_DIR/csqtt-letsencrypt.timer"
}

t_end() {
    # Вложенные подshell (t_run) наследуют EXIT-trap, поэтому песочницу убирает
    # только тот процесс, который её создал.
    [ "${BASHPID:-$$}" = "$T_OWNER_PID" ] || return 0
    [ -n "$SANDBOX" ] && rm -rf -- "$SANDBOX"
    SANDBOX=""
    export PATH="$ORIGINAL_PATH"
    return 0
}

# t_run '<код>' — подshell, в котором уже выполнен `source deploy.sh`.
# Все проверки состояния обязаны идти через него: константы скрипта readonly,
# повторный source в том же процессе падает на «readonly variable».
# deploy.sh в начале выполняет PANEL_MODE="" / PANEL_HOST="", поэтому режим,
# заданный кейсом через окружение, восстанавливается сразу после source.
t_run() {
    local code="$1" inherited_mode="${PANEL_MODE:-}" inherited_host="${PANEL_HOST:-}"
    (
        # shellcheck disable=SC1090
        . "$DEPLOY_SCRIPT"
        trap - ERR EXIT
        set +e
        PANEL_MODE="$inherited_mode"
        PANEL_HOST="$inherited_host"
        eval "$code"
    )
}

# t_run_fails <код> [pattern] [сообщение] [ожидаемый status]
# Историческая форма — <код> <сообщение>: проверяется только ненулевой статус.
# Расширенная форма — <код> <pattern> <сообщение>: дополнительно проверяется,
# что в объединённом stdout/stderr есть подстрока pattern, и (опционально)
# точный код возврата.
t_run_fails() {
    local code="$1" second="${2:-}" third="${3:-}" expected_status="${4:-}"
    local output="" status=0 message="$second" pattern=""
    if [ "$#" -ge 3 ]; then
        pattern="$second"
        message="$third"
    fi
    [ -n "$message" ] || message="отказ"
    output="$(t_run "$code" 2>&1)" || status=$?
    if [ "$status" -eq 0 ]; then
        t_fail "$message: ожидался ненулевой код возврата"
    fi
    if [ -n "$expected_status" ]; then
        t_assert_eq "$status" "$expected_status" "$message: код возврата"
    fi
    if [ -n "$pattern" ]; then
        printf '%s\n' "$output" | grep -Fq -- "$pattern" || \
            t_fail "$message: в выводе нет «$pattern» (вывод: $output)"
    fi
    return 0
}

t_log_calls() {
    printf '  --- журнал заглушек (%s) ---\n' "$CALL_LOG"
    if [ -s "$CALL_LOG" ]; then
        sed 's/^/  | /' "$CALL_LOG"
    else
        printf '  | (пусто)\n'
    fi
}

t_fail() {
    printf '  ✗ %s\n' "$*" >&2
    t_log_calls >&2
    exit 1
}

t_assert_contains() {
    local file="$1" needle="$2" message="$3"
    grep -Fq -- "$needle" "$file" || t_fail "$message (нет «$needle» в $file)"
}

t_assert_not_contains() {
    local file="$1" needle="$2" message="$3"
    if grep -Fq -- "$needle" "$file"; then
        t_fail "$message (найдено «$needle» в $file)"
    fi
}

t_assert_eq() {
    local actual="$1" expected="$2" message="$3"
    [ "$actual" = "$expected" ] || t_fail "$message (ожидалось «$expected», получено «$actual»)"
}

# t_assert_before <файл> <строка1> <строка2> <сообщение> — проверяет порядок
# маркеров: первая строка обязана встретиться раньше второй.
t_assert_before() {
    local file="$1" first="$2" second="$3" message="$4"
    local first_line second_line
    first_line="$(grep -n -x -- "$first" "$file" 2>/dev/null | head -n 1 | cut -d: -f1)"
    second_line="$(grep -n -x -- "$second" "$file" 2>/dev/null | head -n 1 | cut -d: -f1)"
    [ -n "$first_line" ] || t_fail "$message: нет маркера «$first» в $file"
    [ -n "$second_line" ] || t_fail "$message: нет маркера «$second» в $file"
    [ "$first_line" -lt "$second_line" ] || \
        t_fail "$message: «$first» (строка $first_line) обязана идти до «$second» (строка $second_line)"
}

t_assert_failed() {
    local command="$1" message="$2"
    if eval "$command" >/dev/null 2>&1; then
        t_fail "$message: ожидался ненулевой код возврата"
    fi
}

t_count_calls() {
    local name="$1" pattern="${2:-}"
    awk -v name="$name" -v pattern="$pattern" '
        index($0, name " ") == 1 {
            if (pattern == "" || index($0, pattern) > 0) total++
        }
        END { print total + 0 }
    ' "$CALL_LOG"
}

t_stub_exit() {
    printf '%s\n' "$2" > "$STUB_STATE_DIR/$1.exit"
}

t_stub_fail_times() {
    printf '%s\n' "$2" > "$STUB_STATE_DIR/$1.fail_times"
}

t_stub_stdout() {
    printf '%s\n' "$2" > "$STUB_STATE_DIR/$1.stdout"
}

# t_http_fixture <url> <content> — кладёт ответ для заглушки curl.
# Путь фикстуры повторяет URL без схемы: https://github.com/w3struk/recsqtt/releases/download/v2.5.2/install.sh
# -> $STUB_STATE_DIR/http/github.com/w3struk/recsqtt/releases/download/v2.5.2/install.sh.
t_http_fixture() {
    local url="$1" content="$2" path
    path="${url#*://}"
    path="${path%%\?*}"
    path="${path%%#*}"
    path="${path%/}"
    mkdir -p -- "$STUB_STATE_DIR/http/$(dirname -- "$path")"
    printf '%s\n' "$content" > "$STUB_STATE_DIR/http/$path"
}

# t_http_redirect <url> — эффективный URL для `curl -sIL ... -w url_effective`.
t_http_redirect() {
    printf '%s\n' "$1" > "$STUB_STATE_DIR/latest-url"
}

# Заглушка certbot печатает --ip-address на --help. Этот переключатель нужен,
# чтобы проверить обратный случай: клиент без поддержки IP-сертификатов.
t_stub_certbot_ip_support() {
    printf '%s\n' "$1" > "$STUB_STATE_DIR/certbot.ip_support"
}

# t_seed_docker_image <tag> <id> — образ в состоянии docker-заглушки. Тег
# указывает на ID; `docker image inspect` без этого файла честно падает, как на
# сервере, где новая версия ещё не скачана.
t_seed_docker_image() {
    local tag="$1" id="$2" root="$STUB_STATE_DIR/docker" key
    mkdir -p "$root/images" "$root/tags"
    key="$(printf '%s' "$tag" | tr '/:' '__')"
    printf '%s\n' "$id" > "$root/tags/$key"
    key="$(printf '%s' "$id" | tr '/:' '__')"
    : > "$root/images/$key"
}

# t_seed_docker_runtime <container> <tag> <id> — запущенный контейнер, который
# помнит, из какого образа он создан (Config.Image=<tag>, Image=<id>).
t_seed_docker_runtime() {
    local container="$1" tag="$2" id="$3"
    local cdir="$STUB_STATE_DIR/docker/containers/$container"
    t_seed_docker_image "$tag" "$id"
    mkdir -p "$cdir"
    printf '%s\n' "$container" > "$cdir/name"
    printf '%s\n' "cid-$container" > "$cdir/id"
    printf '%s\n' "$tag" > "$cdir/image_tag"
    printf '%s\n' "$id" > "$cdir/image_id"
    printf 'true\n' > "$cdir/running"
}

# t_upload_env больше не существует: upload-путь старого app-деплоя удалён,
# host панели приходит из флага/state/env, а нормализация кавычек проверяется
# прямо на CSQTT_PUBLIC_IP.

# Просроченный сертификат для 203.0.113.7 (issuer O=Let's Encrypt, SAN IP)
# вшит статическим PEM: `openssl req -not_before/-not_after` появился только
# в OpenSSL 3.5, а на Ubuntu 24.04 стоит 3.0.x. Сгенерирован один раз
# (notBefore 2020-01-01, notAfter 2020-02-01) — фикстура не зависит от версии
# openssl на хосте. Ключ одноразовый и существует только для этого теста.
T_EXPIRED_IP_CERT_PEM='-----BEGIN CERTIFICATE-----
MIIDTjCCAjagAwIBAgIUP9C+/5sKIW6KGuNyabRzIms2pIEwDQYJKoZIhvcNAQEL
BQAwLjEWMBQGA1UECgwNTGV0J3MgRW5jcnlwdDEUMBIGA1UEAwwLMjAzLjAuMTEz
LjcwHhcNMjAwMTAxMDAwMDAwWhcNMjAwMjAxMDAwMDAwWjAuMRYwFAYDVQQKDA1M
ZXQncyBFbmNyeXB0MRQwEgYDVQQDDAsyMDMuMC4xMTMuNzCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBAJYIlDou4DYq6YXlUyXa5vOotRfJsE8GVB19GK/s
BaodB1JJRNr2Y2x2bGg1RFr5uQVXT+dYo1sEkEqy7Jc8cASNi7jhDlAvrNiLYh5r
tnGLo1VjXOhb+Vy7PIqYU/Egz9meRi+DP8PILzkNET8W9It8oIkDb7QzSgwlFkkw
gqatr51j37lupPLuML5pGki81N4dRUwjgmAHYhJh7ZcSduCTlYke0uYm0FwAZ49C
SYyM4M11hnDxzl7Q+0e1aboOoygE9XyC1iQAQnodMI1rtQnxygO//f2nqfVcsFRq
+sQe0/MOZbsrK62VT8k/qSBAAiCSpPpuOFGiogKp/ToPH+UCAwEAAaNkMGIwHQYD
VR0OBBYEFNRWGFJcMyU5yrnl5kyywsH7nC/wMB8GA1UdIwQYMBaAFNRWGFJcMyU5
yrnl5kyywsH7nC/wMA8GA1UdEwEB/wQFMAMBAf8wDwYDVR0RBAgwBocEywBxBzAN
BgkqhkiG9w0BAQsFAAOCAQEAHZhTqjsGI/Q1SM8K+wxbxWO74tGlaL5NrWCBmUDE
q14QBX5brfevEyBpJZf+Q1/jflVygsZMgyHAPC9D6EH1naIojRZHLssX0YCj1Dev
yIlHHFO9dG0Ckc1wo9vhi5g/+0C840ysv0flqStXQmsBw9cOQhv9vgaT1IEUytdz
I+N3oK79EwVN7PFHr8N6GgCZEUsK4hWlg9gPf5MPASyyhZnRqsF0sz8/CrWgf6hC
Vy95j/3UPITqecMT+uAZJ/EaoUxEYVVyE3a7eOqs7BJt3IL4sklr48WPEkoeI/TT
O9wTqttwsKIG4x0fIZZrmBLaU9I2I0XhqHOABZydAw5E3Q==
-----END CERTIFICATE-----'
T_EXPIRED_IP_KEY_PEM='-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCWCJQ6LuA2KumF
5VMl2ubzqLUXybBPBlQdfRiv7AWqHQdSSUTa9mNsdmxoNURa+bkFV0/nWKNbBJBK
suyXPHAEjYu44Q5QL6zYi2Iea7Zxi6NVY1zoW/lcuzyKmFPxIM/ZnkYvgz/DyC85
DRE/FvSLfKCJA2+0M0oMJRZJMIKmra+dY9+5bqTy7jC+aRpIvNTeHUVMI4JgB2IS
Ye2XEnbgk5WJHtLmJtBcAGePQkmMjODNdYZw8c5e0PtHtWm6DqMoBPV8gtYkAEJ6
HTCNa7UJ8coDv/39p6n1XLBUavrEHtPzDmW7KyutlU/JP6kgQAIgkqT6bjhRoqIC
qf06Dx/lAgMBAAECggEAFpJy2TASkRkH/29+1hv8EXNzz1Y2MtAabpdSqVZNNzMy
gJ7qVOEAbfcrxx/LHr7MUcaO4cOUTA4V4U8lniPnHHWT1vxGXtUACvzUBbdMgFey
+paTie0bHpLtgFJ7lTRLtmCuttjnCn7/GnUMql0Qlz29me93lPj/GRr+ooNBshlb
cSXwvyX1D1OSCyWJ0AWDaRKhmMkQH1Ft+JcA6xnyQLHx6NeDEsJX9786P0BOeEIV
UMWdZ+XN9Icc7/CnLhglqJlOVYjV8TGURSRg739KgS7TJ2FmXe0IWC0nkmLFkTKN
CsZWEBHsuouzN640r2VaY9j6IUk8JKyigGj8u/RQPwKBgQDEe71mXtnQW2MnmweQ
K3pxOie6V23Imx0Nropf3C7H2sjDazc0VCHgdq4BT3p56SqWPIHC1Pw3s49H58Ag
Az+ntDhvRyKER3iJ9M4vZCmP/vvBWoNUuMqIjLXn8BzPgvZhurrlPDmLCvqmubyL
+cP9tCNLapCGgvGMaZ9pxzMLkwKBgQDDeuVL5tQxv1wXiuSKpAMmyZWJacgJdbys
WL0fRKLIL8imapmUELVGHGmJqhws1YTX0FGodHeRWuRmdJAA/cosHqJC091DXB3I
2cLWFOJAT1iIQEsvmRAmuL3YZKjwqLiANMSYq7S7/A905L0T1vFlqFiJa23bVbAz
i8l58M0BpwKBgQC542POHUCvGjbV+psOL8Q4qU96wUpxNycmkZICnTp5BClakO36
iPo/9agsPzhdbFZJKteNL5mrTSrqWXxwDQLFNAEMbl1ejoug4UXMmlOkExW12V9U
4TtkMtPKqmVngbx9u38kb3T1ch6vbBvQxi1BspKNwDUZvXqvYCJcngRSFwKBgEFT
N39G81Bwn4jqjHdcWgVDRmq2Y/ftVZDO0ty5JiD5/vbGFu6pKrr0UbyEkYfWDt/E
KRW/XhnAIyWt/FWoekCGODlW7dFN3lI5m2fJcNaG7ZIS0k1kvEYEZMUE1oQeDhIi
EDTo5KwRjuTEb/9KTD9po7TApuSuXQTMyRasBwZvAoGAdHwsmvXn0fh/9dNWODWb
etHrG/RKs9+gqdCOHUeJFrLLCX3oV0xNiMXpPZV4eR3vClKkVGkaZM7xGeeKHgb/
o4GUU0KtLXsdZo/1Pp4vPyu9TWRvOAScN+39oiuJ3DO9k9lr0VLJNXtnl9aSvAJq
qJFZP7Ohs4fSTH1OFQLB1O4=
-----END PRIVATE KEY-----'

# t_seed_le_certificate <mode> <identifier> [days|expired] — кладёт в песочницу
# настоящий сертификат с issuer «O=Let's Encrypt» и state-файл, не вызывая
# certbot. Нужен там, где сертификат уже должен лежать на диске.
t_seed_le_certificate() {
    local mode="$1" identifier="$2" validity="${3:-90}" cert_name san source_dir
    case "$mode" in
        domain) cert_name="csqtt-${identifier}"; san="DNS:${identifier}" ;;
        *) cert_name="csqtt-ip-${identifier//./-}"; san="IP:${identifier}" ;;
    esac
    source_dir="$FAKE_LE/live/$cert_name"
    mkdir -p "$source_dir"
    if [ "$validity" = "expired" ]; then
        [ "$mode" = "ip" ] || t_fail "просроченный PEM есть только для IP-режима"
        [ "$identifier" = "203.0.113.7" ] \
            || t_fail "просроченный PEM выпущен для 203.0.113.7, а не для $identifier"
        printf '%s\n' "$T_EXPIRED_IP_CERT_PEM" > "$source_dir/fullchain.pem" \
            || t_fail "не удалось записать просроченный сертификат"
        printf '%s\n' "$T_EXPIRED_IP_KEY_PEM" > "$source_dir/privkey.pem" \
            || t_fail "не удалось записать ключ просроченного сертификата"
        # Проверка самой фикстуры: кейс ниже обязан видеть именно истёкший
        # сертификат, иначе он молча проверял бы отсутствие файла.
        if PATH="$ORIGINAL_PATH" openssl x509 -noout -checkend 0 \
            -in "$source_dir/fullchain.pem" >/dev/null 2>&1; then
            t_fail "фикстура обязана быть просроченной"
        fi
    else
        PATH="$ORIGINAL_PATH" openssl req -x509 -newkey rsa:2048 -nodes -days "$validity" \
            -subj "/O=Let's Encrypt/CN=${identifier}" \
            -addext "subjectAltName = ${san}" \
            -keyout "$source_dir/privkey.pem" -out "$source_dir/fullchain.pem" >/dev/null 2>&1 \
            || t_fail "openssl не создал сертификат для ${identifier}: кейс проверял бы пустую фикстуру"
    fi
    [ -s "$source_dir/fullchain.pem" ] && [ -s "$source_dir/privkey.pem" ] \
        || t_fail "фикстура сертификата для ${identifier} не создана"
    cp "$source_dir/fullchain.pem" "$FAKE_CFG/web_cert.pem" || t_fail "не удалось скопировать web_cert.pem"
    cp "$source_dir/privkey.pem" "$FAKE_CFG/web_key.pem" || t_fail "не удалось скопировать web_key.pem"
    printf 'MODE=%s\nIDENTIFIER=%s\nCERT_NAME=%s\n' "$mode" "$identifier" "$cert_name" \
        > "$FAKE_CFG/letsencrypt.env"
}

# t_write_renewal_helper — генерирует хелпер продления в песочнице. install -d
# /usr/local/lib под непривилегированным пользователем ругается в stderr; это
# ожидаемо и к содержимому хелпера отношения не имеет.
t_write_renewal_helper() {
    t_run 'write_letsencrypt_renewal_helper' 2>/dev/null
}

# t_run_renewal_helper — запускает сгенерированный хелпер. Подменяются только
# переменные окружения: CSQTT_CONFIG_DIR/CSQTT_LE_ROOT/CSQTT_LE_CERTBOT уже
# экспортированы t_begin, идентификатор и окно продления задаёт сам кейс.
t_run_renewal_helper() {
    CSQTT_LE_RENEW_BEFORE_SECONDS="${T_RENEW_BEFORE:-259200}" \
    CSQTT_LE_HTTP_PORT="${T_RENEW_HTTP_PORT:-80}" \
    CSQTT_DEPLOY_MODE=systemd \
        bash "$FAKE_CFG/csqtt-letsencrypt-renew.sh"
}

# ---------------------------------------------------------------------------
# Кейсы: Task 1 — тестируемость и раннер
# ---------------------------------------------------------------------------

test_smoke_source_does_not_run_main() {
    t_begin "smoke: source does not run main"
    t_run 'true'
    t_assert_eq "$?" "0" "source deploy.sh не должен запускать установку"
    # Проверка внутри t_run: install.sh объявляет константы readonly, поэтому
    # повторный source в этом процессе невозможен — значения читаем в подshell.
    t_run 't_assert_eq "$CSQTT_CONFIG_DIR" "$FAKE_CFG" "CSQTT_CONFIG_DIR доступна и переопределена"'
}

test_smoke_stub_captures_argv() {
    t_begin "smoke: stub captures argv"
    PATH="$MOCK_BIN:$PATH" systemctl daemon-reload >/dev/null 2>&1
    t_assert_contains "$CALL_LOG" "systemctl daemon-reload" "заглушка обязана записать свои аргументы"
}

test_runner_refuses_root() {
    t_begin "runner refuses to run as root"
    t_assert_eq "$(sed -n 's/.*CSQTT_ALLOW_ROOT_TESTS.*/found/p' "$0" | head -n 1)" "found" \
        "раннер обязан знать про CSQTT_ALLOW_ROOT_TESTS"
    t_assert_failed 'CSQTT_EUID_OVERRIDE=0 require_non_root' \
        "предохранитель обязан отказать при EUID 0"
    CSQTT_EUID_OVERRIDE=0 CSQTT_ALLOW_ROOT_TESTS=1 require_non_root || \
        t_fail "CSQTT_ALLOW_ROOT_TESTS=1 обязан снимать предохранитель"
    require_non_root || t_fail "без override предохранитель не должен мешать обычному пользователю"
}

# ---------------------------------------------------------------------------
# Кейсы: install — архитектура VPS до переключения runtime
# ---------------------------------------------------------------------------

test_install_architecture_aliases() {
    t_begin "install accepts exact amd64 architecture aliases in both runtime modes"
    local mode machine output="$SANDBOX/architecture.out"
    for mode in systemd docker; do
        export CSQTT_DEPLOY_MODE="$mode"
        for machine in x86_64 amd64; do
            : > "$CALL_LOG"
            t_stub_stdout uname "$machine"
            if ! t_run 'cleanup_deploy_artifacts() { :; }; require_runtime_tools; printf "CUTOVER_REACHED\n"' > "$output" 2>&1; then
                t_fail "$mode: архитектура «$machine» обязана пройти require_runtime_tools"
            fi
            t_assert_contains "$output" "Архитектура VPS: amd64" "$mode/$machine: определяется amd64"
            t_assert_contains "$output" "CUTOVER_REACHED" "$mode/$machine: следующий шаг разрешён"
            t_assert_not_contains "$output" "CSQTT_DEPLOY_ERROR" "$mode/$machine: ошибка не ожидается"
            t_assert_not_contains "$CALL_LOG" "docker " "$mode/$machine: preflight не активирует Docker"
            t_assert_not_contains "$CALL_LOG" "systemctl stop" "$mode/$machine: preflight не останавливает runtime"
        done
    done
}

test_install_rejects_unsupported_architectures() {
    t_begin "install rejects ARM, unknown and blank architectures before the next step"
    local mode machine output="$SANDBOX/architecture.out" status=0
    for mode in systemd docker; do
        export CSQTT_DEPLOY_MODE="$mode"
        for machine in aarch64 arm64 armv7l armv7 armhf riscv64 "" $' \n\t'; do
            : > "$CALL_LOG"
            t_stub_stdout uname "$machine"
            status=0
            if t_run 'cleanup_deploy_artifacts() { :; }; require_runtime_tools; printf "CUTOVER_REACHED\n"' > "$output" 2>&1; then
                t_fail "$mode: неподдерживаемая архитектура «$machine» прошла require_runtime_tools"
            else
                status=$?
            fi
            t_assert_eq "$status" "20" "$mode/$machine: preflight-отказ обязан дать exit 20"
            t_assert_contains "$output" "CSQTT_DEPLOY_ERROR|preflight|" "$mode/$machine: фаза отказа обязана быть preflight"
            t_assert_contains "$output" "Поддерживается только x86_64/amd64" "$mode/$machine: отказ объясняет поддерживаемую архитектуру"
            t_assert_contains "$output" "CSQTT_DEPLOY_ERROR|" "$mode/$machine: отказ использует die"
            t_assert_not_contains "$output" "CUTOVER_REACHED" "$mode/$machine: отказ останавливает выполнение до следующего шага"
            t_assert_not_contains "$CALL_LOG" "docker " "$mode/$machine: отказ не активирует Docker"
            t_assert_not_contains "$CALL_LOG" "systemctl stop" "$mode/$machine: отказ не останавливает runtime"
        done
    done
}

# ---------------------------------------------------------------------------
# Кейсы: Task 2 — каталог данных нельзя сносить
# ---------------------------------------------------------------------------

test_symlinked_config_dir_keeps_link_and_data() {
    t_begin "symlinked config dir keeps both link and data"
    mkdir -p "$FAKE_CFG/target"
    printf 'данные' > "$FAKE_CFG/target/csqtt.db"
    ln -s "$FAKE_CFG/target" "$FAKE_CFG/cfg"
    t_run 'ensure_persistent_directory "$CSQTT_CONFIG_DIR/cfg" 700'
    t_assert_eq "$(readlink "$FAKE_CFG/cfg")" "$FAKE_CFG/target" \
        "симлинк каталога данных обязан пережить установку"
    t_assert_eq "$(cat "$FAKE_CFG/target/csqtt.db")" "данные" \
        "данные в цели симлинка обязаны остаться"
    t_assert_eq "$(stat -c %a "$FAKE_CFG/target")" "700" \
        "права выставляются на цель симлинка"
}

test_dangling_config_symlink_fails_without_deleting() {
    t_begin "dangling symlink fails without deleting"
    ln -s "$FAKE_CFG/missing-target" "$FAKE_CFG/cfg"
    t_run_fails 'ensure_persistent_directory "$CSQTT_CONFIG_DIR/cfg" 700' \
        'несуществующий путь' "висячая ссылка обязана дать отказ"
    t_assert_eq "$(readlink "$FAKE_CFG/cfg")" "$FAKE_CFG/missing-target" \
        "висячая ссылка не должна удаляться"
    [ -e "$FAKE_CFG/missing-target" ] && t_fail "цель висячей ссылки не должна создаваться"
    return 0
}

test_non_directory_config_path_fails_without_deleting() {
    t_begin "non-directory config path fails without deleting"
    printf 'важное' > "$FAKE_CFG/cfg"
    t_run_fails 'ensure_persistent_directory "$CSQTT_CONFIG_DIR/cfg" 700' \
        'не каталог' "обычный файл на месте каталога данных обязан дать отказ"
    t_assert_eq "$(cat "$FAKE_CFG/cfg")" "важное" "файл обязан остаться нетронутым"
}

test_missing_config_dir_is_created() {
    t_begin "missing config dir is created"
    t_run 'ensure_persistent_directory "$CSQTT_CONFIG_DIR/cfg" 700'
    t_assert_eq "$(stat -c %a "$FAKE_CFG/cfg")" "700" "каталог данных создаётся с режимом 700"
}

test_helper_dir_still_gets_recreated() {
    t_begin "helper dir still gets recreated"
    ln -s /usr/local/lib/csqtt "$FAKE_CFG/helper"
    t_run 'ensure_csqtt_directory "$CSQTT_CONFIG_DIR/helper" 755'
    [ -L "$FAKE_CFG/helper" ] && t_fail "вспомогательный каталог должен пересоздаваться, а не оставаться симлинком"
    t_assert_eq "$(stat -c %a "$FAKE_CFG/helper")" "755" "вспомогательный каталог создаётся с режимом 755"
}

# ---------------------------------------------------------------------------
# Кейсы: Task 3 — определение режима панели
# ---------------------------------------------------------------------------

test_public_ip_selects_ip_mode() {
    t_begin "public ip selects ip mode"
    export CSQTT_PUBLIC_IP=203.0.113.7
    t_run 'resolve_panel_mode
        t_assert_eq "$PANEL_MODE" "ip" "режим панели"
        t_assert_eq "$PANEL_HOST" "203.0.113.7" "хост панели"
        t_assert_eq "$WEB_PORT" "46002" "порт панели в IP-режиме"
        t_assert_eq "$LE_RENEW_BEFORE_SECONDS" "259200" "окно продления в IP-режиме"'
}

test_domain_selects_domain_mode_on_443() {
    t_begin "domain selects domain mode on 443"
    export CSQTT_PUBLIC_IP=panel.example.com
    t_run 'resolve_panel_mode
        t_assert_eq "$PANEL_MODE" "domain" "режим панели"
        t_assert_eq "$PANEL_HOST" "panel.example.com" "хост панели"
        t_assert_eq "$WEB_PORT" "443" "порт панели в доменном режиме"
        t_assert_eq "$LE_RENEW_BEFORE_SECONDS" "2592000" "окно продления в доменном режиме"'
}

test_domain_overrides_client_web_port() {
    t_begin "domain overrides a web port supplied by the client"
    export CSQTT_PUBLIC_IP=panel.example.com
    export CSQTT_WEB_PORT=46002
    t_run 'resolve_panel_mode
        t_assert_eq "$WEB_PORT" "443" "доменный режим обязан переопределить порт клиента"'
}

test_garbage_web_port_with_domain_still_resolves_to_443() {
    t_begin "garbage web port with a domain still resolves to 443"
    export CSQTT_PUBLIC_IP=panel.example.com
    export CSQTT_WEB_PORT=abc
    t_run 'resolve_panel_mode
        t_assert_eq "$WEB_PORT" "443" "мусорный порт клиента не должен мешать доменному режиму"'
}

test_host_is_lowercased() {
    t_begin "host is lowercased"
    export CSQTT_PUBLIC_IP=Panel.Example.COM
    t_run 'resolve_panel_mode
        t_assert_eq "$PANEL_HOST" "panel.example.com" "хост обязан нормализоваться в нижний регистр"'
}

test_blank_host_fails_before_parsing() {
    t_begin "blank host fails before any parsing"
    export CSQTT_PUBLIC_IP="   "
    t_run_fails 'resolve_panel_mode' "пустое поле обязано привести к отказу"
    t_assert_eq "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0" "до разбора не должно быть внешних вызовов"
}

test_private_ipv4_is_rejected() {
    t_begin "private ipv4 is rejected"
    local ip
    for ip in 192.168.1.5 10.0.0.1 172.16.0.1 127.0.0.1 100.64.0.1; do
        export CSQTT_PUBLIC_IP="$ip"
        t_run_fails 'resolve_panel_mode' "частный адрес $ip обязан быть отклонён"
    done
}

test_non_address_and_non_domain_is_rejected() {
    t_begin "non address and non domain is rejected"
    export CSQTT_PUBLIC_IP="не домен"
    t_run_fails 'resolve_panel_mode' "произвольная строка обязана быть отклонена"
}

test_quoted_host_value_is_accepted() {
    t_begin "quoted host value is accepted"
    export CSQTT_PUBLIC_IP='"panel.example.com"'
    t_run 'resolve_panel_mode
        t_assert_eq "$PANEL_HOST" "panel.example.com" "кавычки из systemd-формы обязаны сниматься"
        t_assert_eq "$PANEL_MODE" "domain" "домен в кавычках обязан остаться доменом"'
}

test_escaped_host_value_is_accepted() {
    t_begin "escaped host value is accepted"
    export CSQTT_PUBLIC_IP='"panel\.example.com"'
    t_run 'resolve_panel_mode
        t_assert_eq "$PANEL_HOST" "panel.example.com" "обратные слэши обязаны сниматься"'
}

test_hostname_validator_vectors() {
    t_begin "hostname validator vectors"
    local name
    for name in panel.example.com localhost a.b.c.d.e; do
        t_run "is_dns_hostname '$name'" || t_fail "«$name» обязан считаться доменным именем"
    done
    for name in 203.0.113.7 1.2.3.4.5 -bad.example.com bad-.example.com bad..example.com .example.com example.com. ""; do
        t_run_fails "is_dns_hostname '$name'" "«$name» не должен считаться доменным именем"
    done
}

# ---------------------------------------------------------------------------
# Кейсы: Task 4 — firewall: закрытие старого порта
# ---------------------------------------------------------------------------

test_domain_mode_removes_46002_rule() {
    t_begin "domain mode removes the 46002 rule"
    t_stub_stdout iptables '-A INPUT -p tcp -m tcp --dport 46002 -m comment --comment CSQTT_MANAGED -j ACCEPT'
    t_run 'PANEL_MODE=domain; fw_close_unused_panel_port'
    t_assert_contains "$CALL_LOG" "-D INPUT" "старое правило закрывается через iptables -D"
    t_assert_contains "$CALL_LOG" "--dport 46002" "закрывается именно порт 46002"
}

test_ip_mode_removes_443_rule() {
    t_begin "ip mode removes the 443 rule"
    t_stub_stdout iptables '-A INPUT -p tcp -m tcp --dport 443 -m comment --comment CSQTT_MANAGED -j ACCEPT'
    t_run 'PANEL_MODE=ip; fw_close_unused_panel_port'
    t_assert_contains "$CALL_LOG" "--dport 443" "обратный переход обязан закрыть 443"
    t_assert_not_contains "$CALL_LOG" "--dport 46002" "в IP-режиме правило 46002 не трогается"
}

test_current_port_rule_is_still_added() {
    t_begin "current port rule is still added"
    t_run 'fw_add_input_tcp 46002'
    t_assert_contains "$CALL_LOG" "-p tcp --dport 46002" "правило текущего порта открывается штатно"
}

test_removal_stops_on_success() {
    t_begin "removal stops on success"
    t_stub_stdout iptables '-A INPUT -p tcp -m tcp --dport 46002 -m comment --comment CSQTT_MANAGED -j ACCEPT'
    t_stub_fail_times iptables 2
    t_run 'PANEL_MODE=domain; fw_close_unused_panel_port'
    t_assert_eq "$(t_count_calls iptables "-D INPUT")" "3" "два неуспеха и успех — ровно три попытки удаления"
}

test_removal_terminates_without_the_rule() {
    t_begin "removal on a host that never had the rule terminates"
    t_stub_stdout iptables '-A INPUT -p tcp -m tcp --dport 46002 -m comment --comment CSQTT_MANAGED -j ACCEPT'
    t_stub_fail_times iptables 100
    t_run 'PANEL_MODE=domain; fw_close_unused_panel_port'
    local attempts
    attempts="$(t_count_calls iptables "-D INPUT")"
    [ "$attempts" -ge 1 ] || t_fail "удаление обязано хотя бы раз попробовать снять правило"
    [ "$attempts" -le 8 ] || t_fail "цикл удаления обязан быть ограничен 8 попытками, было $attempts"
    return 0
}

test_cleanup_removes_unmarked_legacy_mss_rules() {
    t_begin "cleanup removes unmarked legacy MSS clamping rules"
    t_stub_stdout iptables '-A FORWARD -s 10.66.67.0/24 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
    t_run 'cleanup_csqtt_netfilter_rules'
    t_assert_eq "$?" "0" "cleanup обязан пройти при legacy-правиле"
    local deletions
    deletions="$(t_count_calls iptables "-D FORWARD")"
    [ "$deletions" -ge 2 ] || t_fail "обязаны быть удаления -s и -d (было $deletions)"
    t_assert_contains "$CALL_LOG" "-D FORWARD -s 10.66.67.0/24" \
        "исходящее legacy-правило обязано удаляться"
    t_assert_contains "$CALL_LOG" "-D FORWARD -d 10.66.67.0/24" \
        "входящее legacy-правило обязано удаляться"
    t_assert_contains "$CALL_LOG" "TCPMSS --clamp-mss-to-pmtu" \
        "удаляется именно legacy TCPMSS-правило"
    return 0
}

test_cleanup_tolerates_missing_legacy_mss_rules() {
    t_begin "cleanup tolerates a host without legacy MSS rules"
    t_run 'cleanup_csqtt_netfilter_rules'
    t_assert_eq "$?" "0" "отсутствие legacy-правил — не ошибка"
    t_assert_not_contains "$CALL_LOG" "TCPMSS" "без правил iptables -D TCPMSS не вызывается"
    return 0
}

test_network_helper_closes_the_unused_port() {
    t_begin "network helper closes the port the panel no longer uses"
    t_run 'PANEL_MODE=domain; write_network_helper "$FAKE_CFG/network-up.sh"'
    t_assert_contains "$FAKE_CFG/network-up.sh" 'STALE_WEB_PORT="46002"' \
        "хелпер обязан знать, какой порт закрывается"
    t_assert_contains "$FAKE_CFG/network-up.sh" 'ipt -D INPUT -p tcp --dport "$STALE_WEB_PORT"' \
        "вторая копия правил обязана снимать старое правило"
    sh -n "$FAKE_CFG/network-up.sh" || t_fail "сгенерированный хелпер обязан остаться валидным POSIX sh"
}

test_network_helper_keeps_the_reverse_switch() {
    t_begin "network helper keeps the reverse switch"
    t_run 'PANEL_MODE=ip; write_network_helper "$FAKE_CFG/network-up.sh"'
    t_assert_contains "$FAKE_CFG/network-up.sh" 'STALE_WEB_PORT="443"' \
        "в IP-режиме хелпер закрывает 443"
}

# ---------------------------------------------------------------------------
# Кейсы: Task 5 — выпуск сертификата для домена
# ---------------------------------------------------------------------------

test_domain_issuance_asks_certbot_for_a_dns_name_only() {
    t_begin "domain issuance asks certbot for a dns name only"
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run 'setup_web_panel_tls'
    t_assert_contains "$CALL_LOG" "certbot certonly --standalone --http-01-port 80" \
        "доменный выпуск идёт через HTTP-01"
    t_assert_contains "$CALL_LOG" "--domains panel.example.com" "certbot получает домен"
    t_assert_not_contains "$CALL_LOG" "--ip-address" "в доменном режиме IP-флаг не передаётся"
    t_assert_not_contains "$CALL_LOG" "shortlived" "в доменном режиме профиль не переопределяется"
}

test_ip_issuance_is_unchanged() {
    t_begin "ip issuance is unchanged"
    export PANEL_MODE=ip PANEL_HOST=203.0.113.7
    t_run 'setup_web_panel_tls'
    t_assert_contains "$CALL_LOG" "--ip-address 203.0.113.7" "IP-режим передаёт адрес"
    t_assert_contains "$CALL_LOG" "--preferred-profile shortlived" "IP-режим сохраняет профиль"
    t_assert_not_contains "$CALL_LOG" "--domains" "IP-режим не передаёт домен"
}

test_domain_mode_never_falls_back_to_self_signed() {
    t_begin "domain mode never falls back to a self signed certificate"
    t_stub_fail_times certbot 2
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run_fails 'setup_web_panel_tls' "неудача выпуска в доменном режиме обязана быть фатальной"
    t_assert_not_contains "$CALL_LOG" "openssl req -x509" "самоподпись в доменном режиме запрещена"
}

test_ip_mode_still_falls_back_to_self_signed() {
    t_begin "ip mode still falls back to a self signed certificate"
    t_stub_fail_times certbot 2
    export PANEL_MODE=ip PANEL_HOST=203.0.113.7
    t_run 'setup_web_panel_tls'
    t_assert_contains "$CALL_LOG" "openssl req -x509" "в IP-режиме откат на самоподпись сохранён"
}

test_activation_failure_is_fatal_in_domain_mode() {
    t_begin "activation failure is fatal in domain mode"
    t_stub_fail_times install 1
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run_fails 'setup_web_panel_tls' "неудача активации сертификата обязана быть фатальной"
    t_assert_not_contains "$CALL_LOG" "openssl req -x509" "откат на самоподпись запрещён"
    [ -e "$FAKE_CFG/letsencrypt.env" ] && t_fail "при неудачной активации state не должен записываться"
    return 0
}

test_missing_certbot_client_is_fatal_in_domain_mode() {
    t_begin "missing certbot client is fatal in domain mode"
    t_stub_certbot_ip_support 0
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run_fails 'setup_web_panel_tls' "без certbot с --domains доменная установка обязана падать"
    t_assert_not_contains "$CALL_LOG" "openssl req -x509" "откат на самоподпись запрещён"
}

test_occupied_port_80_fails_in_domain_mode() {
    t_begin "occupied port 80 fails in domain mode"
    t_stub_stdout ss 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*'
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    local output
    if output="$(t_run 'setup_web_panel_tls' 2>&1)"; then
        t_fail "занятый TCP/80 в доменном режиме обязан остановить установку"
    fi
    printf '%s' "$output" | grep -Fq "80" || t_fail "в отказе обязан упоминаться порт 80"
    return 0
}

test_identifier_comes_from_panel_host() {
    t_begin "identifier comes from PANEL_HOST"
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run 'setup_web_panel_tls'
    t_assert_contains "$CALL_LOG" "--domains panel.example.com" "идентификатор берётся из PANEL_HOST"
    t_assert_not_contains "$CALL_LOG" "ip -4 route get" "detect_public_ipv4 в доменном режиме не вызывается"
}

test_certificate_name_and_state_follow_the_mode() {
    t_begin "certificate name and state file follow the mode"
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run 'setup_web_panel_tls'
    t_assert_contains "$FAKE_CFG/letsencrypt.env" "MODE=domain" "state фиксирует режим"
    t_assert_contains "$FAKE_CFG/letsencrypt.env" "IDENTIFIER=panel.example.com" "state фиксирует идентификатор"
    t_assert_contains "$FAKE_CFG/letsencrypt.env" "CERT_NAME=csqtt-panel.example.com" "имя сертификата следует режиму"
    t_assert_contains "$CALL_LOG" "--cert-name csqtt-panel.example.com" "certbot получает то же имя"
}

test_ip_certificate_name_keeps_the_dash_form() {
    t_begin "ip certificate name keeps the dash form"
    export PANEL_MODE=ip PANEL_HOST=203.0.113.7
    t_run 'setup_web_panel_tls'
    t_assert_contains "$FAKE_CFG/letsencrypt.env" "CERT_NAME=csqtt-ip-203-0-113-7" "IP-имя сохраняет дефисы"
}

test_domain_certificate_is_recognised_as_current() {
    t_begin "domain certificate is recognised as current"
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run 'setup_web_panel_tls'
    t_run 'setup_web_panel_tls'
    t_assert_eq "$(t_count_calls certbot "certonly")" "1" \
        "повторная установка не выпускает второй сертификат"
}

test_user_supplied_certificate_is_left_alone_in_both_modes() {
    t_begin "user supplied certificate is left alone in both modes"
    PATH="$ORIGINAL_PATH" openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
        -subj "/CN=user.example.org" -addext "subjectAltName = DNS:user.example.org" \
        -keyout "$FAKE_CFG/web_key.pem" -out "$FAKE_CFG/web_cert.pem" >/dev/null 2>&1
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run 'setup_web_panel_tls'
    export PANEL_MODE=ip PANEL_HOST=203.0.113.7
    t_run 'setup_web_panel_tls'
    t_assert_not_contains "$CALL_LOG" "certbot certonly" "пользовательский сертификат не перевыпускается"
    t_assert_contains "$CALL_LOG" "systemctl disable --now csqtt-letsencrypt.timer" \
        "продление выключается для пользовательского сертификата"
}

test_adopt_recovers_a_domain_certificate_after_state_loss() {
    t_begin "adopt recovers a domain certificate after the state file is lost"
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run 'setup_web_panel_tls'
    rm -f "$FAKE_CFG/letsencrypt.env"
    t_run 'setup_web_panel_tls'
    t_assert_eq "$(t_count_calls certbot "certonly")" "1" "adopt не выпускает второй сертификат"
    t_assert_contains "$FAKE_CFG/letsencrypt.env" "MODE=domain" "adopt восстановил состояние"
}

test_supported_install_does_not_create_legacy_files() {
    t_begin "2.5.2 install does not recreate legacy migration files"
    t_require_sandbox_runtime_paths
    t_seed_le_certificate ip 203.0.113.7
    t_seed_install_state systemd ip 203.0.113.7 46000 46002 22
    printf 'mig\n' > "$FAKE_CFG/csqtt.db.pre-owner-migration"
    # Двойной проход по путям install на 2.5.2-состоянии: resolve -> cleanup ->
    # TLS. Файлы, которых не было, не должны появиться: импорт legacy JSON и
    # перенос letsencrypt-ip.env удалены, данные остаются как есть.
    local round
    for round in 1 2; do
        t_run '
            parse_cli --yes
            resolve_install_configuration
            clear_runtime_config_preserving_database
            setup_web_panel_tls
        ' || t_fail "проход $round по install-путям обязан пройти"
    done
    local file
    for file in passwords.json passwords.json.imported letsencrypt-ip.env; do
        [ -e "$FAKE_CFG/$file" ] && t_fail "установка 2.5.2 не должна создавать $file"
    done
    [ -f "$FAKE_CFG/csqtt.db.pre-owner-migration" ] || \
        t_fail "данные pre-owner-migration обязаны пережить установку"
    [ -f "$FAKE_CFG/letsencrypt.env" ] || t_fail "состояние Let’s Encrypt обязано остаться"
    return 0
}

test_cutover_stops_the_renewal_timer() {
    t_begin "cutover stops the renewal timer before the helper is overwritten"
    t_run 'stop_letsencrypt_renewal_timer'
    t_assert_contains "$CALL_LOG" "systemctl stop csqtt-letsencrypt.timer csqtt-letsencrypt.service" \
        "таймер обязан быть остановлен"
    t_assert_not_contains "$CALL_LOG" "enable --now" "остановка не включает таймер обратно"
}

test_domain_install_does_not_adopt_an_ip_certificate() {    t_begin "domain install with an old IP certificate does not write MODE=ip state"
    t_seed_le_certificate ip 203.0.113.7
    rm -f "$FAKE_CFG/letsencrypt.env"
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run_fails 'adopt_letsencrypt_certificate' "adopt обязан отказаться от сертификата чужого режима"
    [ -e "$FAKE_CFG/letsencrypt.env" ] && t_fail "state не должен записываться при несоответствии режиму"
    return 0
}

test_domain_preflight_dies_before_the_runtime_is_stopped() {
    t_begin "domain preflight dies before the runtime is stopped"
    t_stub_stdout ss 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*'
    export PANEL_MODE=domain PANEL_HOST=panel.example.com
    t_run_fails 'run_domain_mode_preflight' "занятый TCP/80 обязан остановить установку"
    t_assert_not_contains "$CALL_LOG" "systemctl stop csqtt.service" \
        "проверка обязана идти до cutover"
}

# ---------------------------------------------------------------------------
# Кейсы: Task 5 — хелпер продления
# ---------------------------------------------------------------------------

test_renewal_helper_renews_the_domain_without_the_short_lived_profile() {
    t_begin "renewal helper renews the domain without the short lived profile"
    t_write_renewal_helper
    t_seed_le_certificate domain panel.example.com
    export CSQTT_LE_IDENTIFIER=panel.example.com
    T_RENEW_BEFORE=100000000 t_run_renewal_helper
    t_assert_contains "$CALL_LOG" "certbot certonly" "хелпер обязан продлевать сертификат"
    t_assert_contains "$CALL_LOG" "--domains panel.example.com" "домен передаётся certbot-у"
    t_assert_not_contains "$CALL_LOG" "shortlived" "доменное продление без профиля shortlived"
    t_assert_not_contains "$CALL_LOG" "--ip-address" "доменное продление без IP-флага"
}

test_renewal_helper_never_self_signs_in_domain_mode() {
    t_begin "renewal helper never self signs in domain mode"
    t_write_renewal_helper
    t_seed_le_certificate domain panel.example.com
    export CSQTT_LE_IDENTIFIER=panel.example.com
    t_stub_fail_times certbot 2
    local output
    if ! output="$(T_RENEW_BEFORE=100000000 t_run_renewal_helper 2>&1)"; then
        t_fail "хелпер обязан завершиться успешно, сохранив текущий сертификат"
    fi
    printf '%s' "$output" | grep -Fq "не удался" || t_fail "в журнал обязано попасть предупреждение"
    t_assert_not_contains "$CALL_LOG" "openssl req -x509" "самоподпись в доменном режиме запрещена"
    return 0
}

test_renewal_helper_self_signs_in_ip_mode() {
    t_begin "renewal helper self signs in ip mode"
    t_write_renewal_helper
    t_seed_le_certificate ip 203.0.113.7 expired
    t_stub_fail_times certbot 2
    local output
    output="$(T_RENEW_BEFORE=100000000 t_run_renewal_helper 2>&1)" || t_fail "хелпер обязан завершиться успешно"
    # Хелпер обязан дойти до этой ветки, а не выйти раньше по пустому
    # идентификатору: иначе самоподпись получалась бы и без фикстуры.
    printf '%s\n' "$output" | grep -Fq "текущий сертификат истёк" || \
        t_fail "хелпер обязан увидеть истёкший сертификат (вывод: $output)"
    t_assert_eq "$(t_count_calls certbot "certonly")" "2" \
        "просроченный сертификат обязан уйти в обе попытки перевыпуска"
    t_assert_contains "$CALL_LOG" "--ip-address 203.0.113.7" "перевыпуск идёт для IP из фикстуры"
    t_assert_contains "$CALL_LOG" "openssl req -x509" "в IP-режиме откат на самоподпись сохранён"
}

test_renewal_helper_exits_when_state_is_missing_in_domain_mode() {
    t_begin "renewal helper exits when the state file is missing in domain mode"
    t_write_renewal_helper
    t_seed_le_certificate domain panel.example.com
    rm -f "$FAKE_CFG/letsencrypt.env"
    export CSQTT_LE_IDENTIFIER=panel.example.com
    local output
    if ! output="$(t_run_renewal_helper 2>&1)"; then
        t_fail "хелпер обязан выйти успешно"
    fi
    printf '%s' "$output" | grep -Fq "отсутствует" || t_fail "ранний выход обязан быть записан в журнал"
    t_assert_not_contains "$CALL_LOG" "certbot certonly" "certbot не должен вызываться"
    t_assert_not_contains "$CALL_LOG" "openssl req -x509" "самоподпись запрещена"
    return 0
}

test_renewal_helper_renews_on_identifier_mismatch() {
    t_begin "renewal helper renews on identifier mismatch"
    t_write_renewal_helper
    t_seed_le_certificate domain panel.example.com
    export CSQTT_LE_IDENTIFIER=old.example.com
    t_run_renewal_helper || t_fail "хелпер обязан завершиться успешно"
    t_assert_contains "$CALL_LOG" "--force-renewal" "расхождение идентификатора требует перевыпуска"
    t_assert_contains "$CALL_LOG" "--domains panel.example.com" "перевыпуск идёт для домена"
}

test_renewal_helper_exits_quietly_without_identifier() {
    t_begin "renewal helper exits quietly when the unit passes no identifier"
    t_write_renewal_helper
    t_seed_le_certificate domain panel.example.com
    unset CSQTT_LE_IDENTIFIER
    local output
    if ! output="$(t_run_renewal_helper 2>&1)"; then
        t_fail "хелпер обязан выйти успешно"
    fi
    printf '%s' "$output" | grep -Fq "CSQTT_LE_IDENTIFIER" || t_fail "пропуск сверки обязан быть записан в журнал"
    t_assert_not_contains "$CALL_LOG" "certbot certonly" "пустой идентификатор не должен вызывать перевыпуск"
    t_assert_not_contains "$CALL_LOG" "openssl req -x509" "самоподпись запрещена"
    return 0
}

# ---------------------------------------------------------------------------
# Кейсы: Task 6 — порты запуска, docker-capability и проверка занятости
# ---------------------------------------------------------------------------

test_docker_run_passes_unquoted_env() {
    t_begin "docker run receives env values without quotes"
    printf 'CSQTT_WEB_USER="admin"\nCSQTT_WEB_PASS="SecretPass123"\nCSQTT_PUBLIC_IP="panel.example.com"\nCSQTT_WEB_SECRET_PATH="secret-path"\n' \
        > "$FAKE_CFG/csqtt.env"
    t_run 'run_csqtt_docker_container'
    t_assert_contains "$CALL_LOG" "--env CSQTT_WEB_SECRET_PATH=secret-path" \
        "secret path обязан уйти без кавычек"
    t_assert_contains "$CALL_LOG" "--env CSQTT_WEB_USER=admin" \
        "логин обязан уйти без кавычек"
    if grep -qF -- '--env-file' "$CALL_LOG"; then
        t_fail "--env-file оставляет кавычки в значениях и ломает panel secret path"
    fi
    return 0
}

test_docker_run_grants_net_bind_service() {
    t_begin "docker run grants net bind service"
    t_run 'run_csqtt_docker_container'
    t_assert_contains "$CALL_LOG" "--cap-add NET_BIND_SERVICE" \
        "контейнер под --cap-drop ALL не забиндит 443 без этой capability"
}

# Кандидат занимает основной тег только после health-check, поэтому к моменту
# снимка `csqtt:2.5.2` может уже существовать локально. Откат обязан вернуть
# образ из снимка контейнера (ID), а не текущий тег.
test_docker_rollback_uses_previous_image() {
    t_begin "docker rollback runs the previous image, not the candidate"
    t_require_sandbox_runtime_paths
    local old_id="sha256:1111111111111111111111111111111111111111111111111111111111111111"
    local new_id="sha256:2222222222222222222222222222222222222222222222222222222222222222"
    # Только docker: если рядом окажется управляемый csqtt.service, установщик
    # определит systemd и кейс перестанет проверять docker-откат.
    printf 'old-binary\n' > "$CSQTT_BIN_DIR/csqtt"
    printf 'CSQTT_WEB_USER="admin"\nCSQTT_WEB_PASS="kept"\n' > "$FAKE_CFG/csqtt.env"
    printf 'old-db\n' > "$FAKE_CFG/csqtt.db"
    t_seed_docker_runtime csqtt csqtt:2.5.1 "$old_id"
    t_seed_docker_image csqtt:2.5.2 "$new_id"
    local out status=0
    out="$(t_run '
        DEPLOY_PHASE=cutover
        RUNTIME_SNAPSHOT_MODE=docker
        snapshot_runtime >/dev/null
        : > "$CALL_LOG"
        ROLLBACK_ARMED=1
        die "simulated docker cutover failure"
    ' 2>&1)" || status=$?
    t_assert_eq "$status" "30" "откат docker обязан завершиться успешно"
    printf '%s' "$out" | grep -Fq 'CSQTT_DEPLOY_ROLLED_BACK' || \
        t_fail "успешный откат обязан напечатать ROLLED_BACK (вывод: $out)"
    local run_line
    run_line="$(grep -E '^docker run ' "$CALL_LOG" | tail -n 1)"
    [ -n "$run_line" ] || t_fail "после отката контейнер обязан запускаться через docker run"
    printf '%s' "$run_line" | grep -Fq -- "$old_id" || \
        t_fail "rollback обязан запускать прежний ID образа ($run_line)"
    printf '%s' "$run_line" | grep -Fq 'csqtt:2.5.2' && \
        t_fail "rollback не должен запускать новый образ ($run_line)"
    local conf
    conf="$(find "$FAKE_CFG/runtime-archive" -name docker-image.conf -print -quit)"
    [ -n "$conf" ] || t_fail "снимок обязан сохранить docker-image.conf"
    t_assert_contains "$conf" "tag=csqtt:2.5.1" "снимок обязан помнить прежний тег"
    t_assert_contains "$conf" "id=$old_id" "снимок обязан помнить ID прежнего образа"
    return 0
}

test_occupied_web_port_fails_before_panel_starts() {
    t_begin "occupied web port fails before the panel starts"
    t_stub_stdout ss 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*'
    local output
    if output="$(t_run 'PANEL_MODE=domain; PANEL_HOST=panel.example.com; WEB_PORT=443; assert_web_port_is_available' 2>&1)"; then
        t_fail "занятый порт панели обязан остановить установку"
    fi
    printf '%s' "$output" | grep -Fq "443" || t_fail "в отказе обязан упоминаться порт"
    return 0
}

test_free_web_port_passes() {
    t_begin "free web port passes"
    t_run 'PANEL_MODE=domain; PANEL_HOST=panel.example.com; WEB_PORT=443; assert_web_port_is_available'
    t_assert_eq "$?" "0" "свободный порт не должен мешать запуску"
}

test_banners_report_the_effective_port() {
    t_begin "banners report the effective port"
    local output
    output="$(t_run 'PANEL_MODE=domain; PANEL_HOST=panel.example.com; WEB_PORT=443; panel_web_port_label; print_installer_header; print_systemd_deploy_summary 4321; print_docker_deploy_summary 4321')"
    [ "$(printf '%s\n' "$output" | grep -Fc '443 (домен panel.example.com)')" -ge 3 ] || \
        t_fail "доменный режим обязан печатать 443 и домен во всех баннерах"
    output="$(t_run 'PANEL_MODE=ip; PANEL_HOST=203.0.113.7; WEB_PORT=46002; panel_web_port_label; print_installer_header; print_systemd_deploy_summary 4321; print_docker_deploy_summary 4321')"
    [ "$(printf '%s\n' "$output" | grep -Fc '46002 (IP 203.0.113.7)')" -ge 3 ] || \
        t_fail "IP-режим обязан печатать 46002 и адрес во всех баннерах"
    t_assert_contains "$DEPLOY_SCRIPT" '${WEB_PORT}/tcp(WEB: $(panel_web_mode_label))' \
        "сводка портов NAT/firewall печатает режим"
}

# ---------------------------------------------------------------------------
# Кейсы: Task 3 — изоляция runtime-путей (безопасные shell-тесты)
# ---------------------------------------------------------------------------

test_cli_dir_is_outside_runtime_lib() {
    t_begin "cli dir is outside the runtime lib dir"
    t_require_sandbox_runtime_paths
    case "$CSQTT_CLI_DIR/" in
        "$CSQTT_LIB_DIR/"*) t_fail "CSQTT_CLI_DIR не должен лежать внутри CSQTT_LIB_DIR: cleanup снесёт CLI" ;;
    esac
    t_run 'case "$CSQTT_CLI_DIR/" in "$CSQTT_LIB_DIR/"*) exit 1 ;; esac'
    t_assert_eq "$?" "0" "installer: CLI вне пересоздаваемого lib-каталога"
    t_assert_contains "$DEPLOY_SCRIPT" \
        'CSQTT_CLI_DIR="${CSQTT_CLI_DIR-/usr/local/lib/csqtt-installer}"' \
        "production-дефолт CLI-каталога зафиксирован"
    # Значение берётся из sourced install.sh и сверяется с песочницей: так
    # проверяется, что установщик не подменяет переопределённый CSQTT_LIB_DIR
    # своим дефолтом /usr/local/lib/csqtt.
    t_assert_eq "$(t_run 'printf %s "$CSQTT_LIB_DIR"')" "$CSQTT_LIB_DIR" \
        "installer обязан брать CSQTT_LIB_DIR из окружения"
}

test_relative_runtime_path_is_rejected() {
    t_begin "relative runtime path is rejected"
    t_run_fails 'validate_runtime_path CSQTT_BIN_DIR relative/bin' 'абсолютным' \
        "относительный runtime-путь обязан быть отклонён" 2
    t_run_fails 'validate_runtime_path CSQTT_LIB_DIR ""' 'пустым' \
        "пустой runtime-путь обязан быть отклонён" 2
    t_run_fails 'validate_runtime_path CSQTT_RUN_DIR /' 'корнем' \
        "корень / не может быть runtime-путём" 2
    t_run 'validate_runtime_paths' || t_fail "sandbox-пути обязаны пройти валидацию"
}

test_empty_runtime_override_is_rejected() {
    t_begin "explicitly empty runtime override is rejected"
    local name saved
    for name in CSQTT_BIN_DIR CSQTT_CONFIG_DIR CSQTT_SYSTEMD_DIR; do
        saved="${!name}"
        export "$name="
        t_run_fails 'validate_runtime_paths' "$name не может быть пустым" \
            "пустой $name обязан дать exit 2, а не подмениться дефолтом" 2
        export "$name=$saved"
    done
    return 0
}

test_cleanup_uses_overridden_runtime_paths() {
    t_begin "cleanup uses overridden runtime paths"
    t_require_sandbox_runtime_paths
    mkdir -p "$CSQTT_VAR_DIR" "$CSQTT_OPT_DIR/bin" "$CSQTT_SYSTEMD_DIR" "$CSQTT_CRON_DIR" "$CSQTT_LIB_DIR"
    : > "$CSQTT_BIN_DIR/csqtt"
    : > "$CSQTT_LIB_DIR/network-up.sh"
    : > "$CSQTT_VAR_DIR/state.db"
    : > "$CSQTT_OPT_DIR/bin/certbot"
    : > "$CSQTT_CRON_DIR/csqtt-letsencrypt"
    : > "$CSQTT_SYSTEMD_DIR/csqtt.service"
    # Никакого TUN-интерфейса нет: ip link show завершается отказом, и cleanup
    # не уходит в ветку восстановления.
    t_stub_exit ip 1
    local output
    if ! output="$(t_run 'csqtt_cleanup' 2>&1)"; then
        printf '%s\n' "$output" >&2
        t_fail "cleanup обязан пройти целиком на переопределённых путях"
    fi
    printf '%s' "$output" | grep -Fq 'CSQTT_DEPLOY_ERROR' && t_fail "cleanup не должен упираться в host-runtime"
    [ -e "$CSQTT_BIN_DIR/csqtt" ] && t_fail "cleanup обязан снять бинарник из переопределённого BIN_DIR"
    [ -e "$CSQTT_LIB_DIR" ] && t_fail "cleanup обязан снести переопределённый LIB_DIR"
    [ -f "$CSQTT_VAR_DIR/state.db" ] || t_fail "cleanup не должен трогать VAR_DIR (состояние сохраняется)"
    [ -f "$CSQTT_OPT_DIR/bin/certbot" ] || t_fail "cleanup не должен трогать OPT_DIR"
    [ -f "$CSQTT_CRON_DIR/csqtt-letsencrypt" ] || t_fail "cleanup не должен удалять cron вне очистки runtime"
    return 0
}

test_sysctl_and_grub_stay_in_sandbox() {
    t_begin "sysctl and grub stay in sandbox"
    t_require_sandbox_runtime_paths
    mkdir -p "$CSQTT_PROC_SYS_DIR/net/ipv4/conf/all" "$CSQTT_PROC_SYS_DIR/net/ipv4/conf/default" \
        "$CSQTT_PROC_SYS_DIR/net/ipv6/conf/all" "$CSQTT_PROC_SYS_DIR/net/ipv6/conf/default"
    printf '0\n' > "$CSQTT_PROC_SYS_DIR/net/ipv4/ip_forward"
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$CSQTT_GRUB_FILE"
    local host_forward host_grub="" host_grub_existed=0
    host_forward="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo missing)"
    if [ -e /etc/default/grub ]; then
        host_grub_existed=1
        host_grub="$(sha256sum /etc/default/grub)"
    fi
    t_run 'setup_sysctl; tune_cpu_mitigations'
    t_assert_eq "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo missing)" "$host_forward" \
        "host /proc/sys/net/ipv4/ip_forward обязан остаться нетронутым"
    if [ "$host_grub_existed" -eq 1 ]; then
        t_assert_eq "$(sha256sum /etc/default/grub)" "$host_grub" \
            "host /etc/default/grub обязан остаться нетронутым"
    else
        [ -e /etc/default/grub ] && \
            t_fail "host /etc/default/grub не должен создаваться тестом"
    fi
    t_assert_eq "$(cat "$CSQTT_PROC_SYS_DIR/net/ipv4/ip_forward" 2>/dev/null || echo 0)" "1" \
        "sysctl обязан включить forwarding в песочнице"
    t_assert_contains "$CSQTT_SYSCTL_DIR/99-csqtt.conf" "net.ipv4.ip_forward = 1" \
        "sysctl-файл создаётся в переопределённом SYSCTL_DIR"
    t_assert_contains "$CSQTT_MODULES_LOAD_DIR/bbr.conf" "tcp_bbr" \
        "modules-load пишется в переопределённый каталог"
    t_assert_contains "$CSQTT_GRUB_FILE" "mitigations=off" \
        "GRUB правится в песочнице"
}

test_uninstall_preserves_state_unless_purge() {
    t_begin "uninstall preserves state unless purge"
    t_require_sandbox_runtime_paths
    printf 'важная-база\n' > "$FAKE_CFG/csqtt.db"
    printf '{"version":"2.5.2","mode":"systemd"}\n' > "$FAKE_CFG/install.json"
    printf 'CSQTT_WEB_PASS="kept"\n' > "$FAKE_CFG/csqtt.env"
    printf 'le-account\n' > "$FAKE_LE/account.txt"
    mkdir -p "$CSQTT_VAR_DIR" "$CSQTT_OPT_DIR/bin" "$CSQTT_CRON_DIR" "$CSQTT_LIB_DIR" "$CSQTT_CLI_DIR"
    : > "$CSQTT_BIN_DIR/csqtt"
    : > "$CSQTT_LIB_DIR/network-up.sh"
    : > "$CSQTT_VAR_DIR/state.db"
    : > "$CSQTT_OPT_DIR/bin/certbot"
    : > "$CSQTT_CRON_DIR/csqtt-letsencrypt"
    printf '#!/usr/bin/env bash\n' > "$CSQTT_CLI_DIR/install.sh"
    chmod 0755 "$CSQTT_CLI_DIR/install.sh"
    ln -s "$CSQTT_CLI_DIR/install.sh" "$CSQTT_BIN_DIR/csqttctl"
    t_stub_exit ip 1
    local output
    if ! output="$(t_run 'do_uninstall' 2>&1)"; then
        printf '%s\n' "$output" >&2
        t_fail "uninstall обязан пройти целиком на переопределённых путях"
    fi
    t_assert_eq "$(cat "$FAKE_CFG/csqtt.db")" "важная-база" \
        "uninstall обязан сохранить SQLite state по умолчанию"
    [ -f "$FAKE_CFG/install.json" ] || t_fail "uninstall без --purge обязан сохранить install.json"
    [ -f "$FAKE_CFG/csqtt.env" ] || t_fail "uninstall без --purge обязан сохранить csqtt.env"
    [ -e "$CSQTT_BIN_DIR/csqtt" ] && t_fail "uninstall обязан снять бинарник из переопределённого BIN_DIR"
    [ -e "$CSQTT_CLI_DIR/install.sh" ] && t_fail "uninstall обязан снять CLI install.sh"
    [ -e "$CSQTT_BIN_DIR/csqttctl" ] && t_fail "uninstall обязан снять симлинк csqttctl"
    [ -e "$CSQTT_LIB_DIR" ] && t_fail "uninstall обязан снести переопределённый LIB_DIR"
    [ -e "$CSQTT_VAR_DIR" ] && t_fail "uninstall обязан снести переопределённый VAR_DIR"
    [ -e "$CSQTT_OPT_DIR" ] && t_fail "uninstall обязан снести переопределённый OPT_DIR"
    [ -e "$CSQTT_CRON_DIR/csqtt-letsencrypt" ] && t_fail "uninstall обязан снять cron-задание"
    [ -f "$FAKE_LE/account.txt" ] || t_fail "uninstall не должен трогать /etc/letsencrypt"

    # --purge снимает конфигурацию и БД, но не /etc/letsencrypt.
    if ! output="$(t_run 'PURGE=1; do_uninstall' 2>&1)"; then
        printf '%s\n' "$output" >&2
        t_fail "uninstall --purge обязан пройти на переопределённых путях"
    fi
    [ -e "$FAKE_CFG" ] && t_fail "uninstall --purge обязан удалить CSQTT_CONFIG_DIR"
    [ -f "$FAKE_LE/account.txt" ] || t_fail "uninstall --purge не должен трогать /etc/letsencrypt"
    return 0
}

# ---------------------------------------------------------------------------
# Кейсы: Task 4 — install.json, whitelist и snapshot
# ---------------------------------------------------------------------------

test_install_state_survives_runtime_cleanup() {
    t_begin "state survives cleanup"
    t_require_sandbox_runtime_paths
    t_run 'printf "{\"version\":\"2.5.2\",\"mode\":\"systemd\"}\n" > "$CSQTT_CONFIG_DIR/install.json"; clear_runtime_config_preserving_database; test -f "$CSQTT_CONFIG_DIR/install.json"'
    t_assert_eq "$?" "0" "install.json must be whitelisted"
}

test_pre_owner_migration_backup_survives_cleanup() {
    t_begin "pre-owner-migration backup survives cleanup"
    t_require_sandbox_runtime_paths
    t_run 'touch "$CSQTT_CONFIG_DIR/csqtt.db.pre-owner-migration" "$CSQTT_CONFIG_DIR/csqtt.db.pre-owner-migration-wal" "$CSQTT_CONFIG_DIR/csqtt.db.pre-owner-migration-shm"; clear_runtime_config_preserving_database; test -f "$CSQTT_CONFIG_DIR/csqtt.db.pre-owner-migration"; test -f "$CSQTT_CONFIG_DIR/csqtt.db.pre-owner-migration-wal"; test -f "$CSQTT_CONFIG_DIR/csqtt.db.pre-owner-migration-shm"'
    t_assert_eq "$?" "0" "migration backup must be whitelisted"
}

test_install_state_roundtrip() {
    t_begin "install state roundtrip"
    t_require_sandbox_runtime_paths
    t_run 'DEPLOY_MODE=docker PANEL_MODE=domain PANEL_HOST=panel.example.com PEER_PORT=46000 WEB_PORT=443 SSH_PORT=2222 write_install_state'
    t_assert_eq "$?" "0" "write_install_state обязан записать state"
    t_assert_eq "$(t_run 'load_install_state mode')" "docker" "mode читается из install.json"
    t_assert_eq "$(t_run 'load_install_state peer_port')" "46000" "peer_port читается из install.json"
    t_assert_eq "$(t_run 'load_install_state panel_host')" "panel.example.com" "panel_host читается из install.json"
    t_assert_eq "$(stat -c '%a' "$FAKE_CFG/install.json")" "600" "install.json обязан быть 0600"
    t_assert_eq "$(t_run 'json_get absent_key "$CSQTT_INSTALL_STATE_FILE" >/dev/null; printf "%s" "$?"')" "1" \
        "json_get отсутствующего ключа обязан вернуть exit 1"
}

test_snapshot_keeps_helpers_and_db() {
    t_begin "snapshot keeps helpers and database"
    t_require_sandbox_runtime_paths
    mkdir -p "$CSQTT_LIB_DIR" "$CSQTT_SYSTEMD_DIR"
    printf 'db\n' > "$FAKE_CFG/csqtt.db"
    printf 'wal\n' > "$FAKE_CFG/csqtt.db-wal"
    printf 'shm\n' > "$FAKE_CFG/csqtt.db-shm"
    printf 'env\n' > "$FAKE_CFG/csqtt.env"
    printf '{"version":"2.5.2","mode":"systemd"}\n' > "$FAKE_CFG/install.json"
    printf 'cert\n' > "$FAKE_CFG/web_cert.pem"
    printf 'key\n' > "$FAKE_CFG/web_key.pem"
    printf 'MODE=ip\n' > "$FAKE_CFG/letsencrypt.env"
    printf 'IP=203.0.113.7\n' > "$FAKE_CFG/letsencrypt-ip.env"
    printf 'json\n' > "$FAKE_CFG/passwords.json"
    printf 'json-imported\n' > "$FAKE_CFG/passwords.json.imported"
    printf 'old-db\n' > "$FAKE_CFG/csqtt.db.pre-owner-migration"
    printf 'helper\n' > "$FAKE_CFG/csqtt-letsencrypt-renew.sh"
    : > "$CSQTT_LIB_DIR/network-up.sh"
    : > "$CSQTT_LIB_DIR/tun-recover.sh"
    : > "$CSQTT_LIB_DIR/docker-prereq.sh"
    : > "$CSQTT_SYSTEMD_DIR/csqtt.service"
    : > "$CSQTT_SYSTEMD_DIR/csqtt-letsencrypt.timer"
    : > "$CSQTT_SYSTEMD_DIR/unrelated.service"
    local archive
    archive="$(t_run 'snapshot_runtime')"
    t_assert_eq "$?" "0" "snapshot_runtime обязан завершиться успешно"
    [ -n "$archive" ] || t_fail "snapshot_runtime обязан напечатать путь каталога"
    [ -d "$archive" ] || t_fail "каталог снимка обязан существовать: $archive"
    case "$archive" in
        "$CSQTT_CONFIG_DIR"/runtime-archive/*) ;;
        *) t_fail "снимок обязан лежать в runtime-archive: $archive" ;;
    esac
    t_assert_eq "$(stat -c '%a' "$archive")" "700" "каталог снимка обязан быть 0700"
    local name
    for name in csqtt.db csqtt.db-wal csqtt.db-shm csqtt.env install.json \
                web_cert.pem web_key.pem letsencrypt.env letsencrypt-ip.env \
                passwords.json passwords.json.imported \
                csqtt.db.pre-owner-migration csqtt-letsencrypt-renew.sh \
                network-up.sh tun-recover.sh docker-prereq.sh csqtt.service csqtt-letsencrypt.timer; do
        [ -e "$archive/$name" ] || t_fail "в снимке нет $name"
    done
    [ -e "$archive/unrelated.service" ] && t_fail "снимок не должен копировать чужие units"
    return 0
}

test_snapshot_keeps_pre_owner_migration_backup() {
    t_begin "snapshot keeps pre-owner-migration backup"
    t_require_sandbox_runtime_paths
    printf 'old-db\n' > "$FAKE_CFG/csqtt.db.pre-owner-migration"
    printf 'old-wal\n' > "$FAKE_CFG/csqtt.db.pre-owner-migration-wal"
    printf 'old-shm\n' > "$FAKE_CFG/csqtt.db.pre-owner-migration-shm"
    local archive
    archive="$(t_run 'snapshot_runtime')"
    t_assert_eq "$?" "0" "snapshot_runtime обязан завершиться успешно"
    [ -e "$archive/csqtt.db.pre-owner-migration" ] || t_fail "снимок обязан сохранить БД до миграции"
    [ -e "$archive/csqtt.db.pre-owner-migration-wal" ] || t_fail "снимок обязан сохранить WAL до миграции"
    [ -e "$archive/csqtt.db.pre-owner-migration-shm" ] || t_fail "снимок обязан сохранить SHM до миграции"
    return 0
}

test_archive_keeps_last_three() {
    t_begin "archive keeps last three snapshots"
    t_require_sandbox_runtime_paths
    local root="$CSQTT_CONFIG_DIR/runtime-archive" day
    mkdir -p "$root"
    for day in 1 2 3 4 5; do
        mkdir -p "$root/2026010${day}-000000"
        touch -d "2026-01-0${day} 00:00:00" "$root/2026010${day}-000000"
    done
    t_run 'prune_runtime_archive'
    t_assert_eq "$?" "0" "prune_runtime_archive обязан завершиться успешно"
    [ -e "$root/20260101-000000" ] && t_fail "старый снимок 1 обязан быть удалён"
    [ -e "$root/20260102-000000" ] && t_fail "старый снимок 2 обязан быть удалён"
    [ -d "$root/20260103-000000" ] || t_fail "снимок 3 обязан остаться"
    [ -d "$root/20260104-000000" ] || t_fail "снимок 4 обязан остаться"
    [ -d "$root/20260105-000000" ] || t_fail "снимок 5 обязан остаться"
    return 0
}

# ---------------------------------------------------------------------------
# Кейсы: Task 8 — откат, сигналы и восстановление сети
# ---------------------------------------------------------------------------

test_failure_after_cutover_rolls_back() {
    t_begin "failure after cutover rolls back"
    t_require_sandbox_runtime_paths
    t_seed_previous_runtime
    local out status=0
    out="$(t_run '
        DEPLOY_PHASE=cutover
        snapshot_runtime >/dev/null
        printf "1\n" > "$STUB_STATE_DIR/systemctl.active"
        printf "candidate-binary\n" > "$CSQTT_BIN_DIR/csqtt"
        printf "candidate-helper\n" > "$CSQTT_LIB_DIR/network-up.sh"
        printf "candidate-db\n" > "$CSQTT_CONFIG_DIR/csqtt.db"
        ROLLBACK_ARMED=1
        die "simulated cutover failure"
    ' 2>&1)" || status=$?
    t_assert_eq "$status" "30" "успешный откат обязан выйти 30"
    printf '%s' "$out" | grep -Fq 'CSQTT_DEPLOY_ROLLED_BACK' || \
        t_fail "успешный откат обязан напечатать маркер ROLLED_BACK (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'CSQTT_DEPLOY_ROLLBACK_FAILED' && \
        t_fail "успешный откат не должен печатать ROLLBACK_FAILED"
    t_assert_eq "$(cat "$CSQTT_BIN_DIR/csqtt")" "old-binary" "предыдущий бинарник обязан вернуться"
    t_assert_eq "$(cat "$CSQTT_LIB_DIR/network-up.sh")" "old-helper" "прежний helper обязан вернуться"
    t_assert_eq "$(cat "$FAKE_CFG/csqtt.db")" "old-db" "БД обязана вернуться из снимка"
    t_assert_contains "$CALL_LOG" "systemctl start csqtt" "служба обязана быть запущена заново"
    return 0
}

test_rollback_restores_previous_helper() {
    t_begin "rollback restores the previous helper, not a regenerated one"
    t_require_sandbox_runtime_paths
    t_seed_previous_runtime
    local status=0
    t_run '
        DEPLOY_PHASE=cutover
        snapshot_runtime >/dev/null
        printf "1\n" > "$STUB_STATE_DIR/systemctl.active"
        rm -rf "$CSQTT_LIB_DIR"
        mkdir -p "$CSQTT_LIB_DIR"
        printf "broken-new-helper\n" > "$CSQTT_LIB_DIR/network-up.sh"
        printf "broken-new-recover\n" > "$CSQTT_LIB_DIR/tun-recover.sh"
        ROLLBACK_ARMED=1
        die "simulated helper failure"
    ' >/dev/null 2>&1 || status=$?
    t_assert_eq "$status" "30" "откат обязан завершиться успешно"
    t_assert_eq "$(cat "$CSQTT_LIB_DIR/network-up.sh")" "old-helper" \
        "network-up.sh обязан быть восстановлен из снимка"
    t_assert_eq "$(cat "$CSQTT_LIB_DIR/tun-recover.sh")" "old-recover" \
        "tun-recover.sh обязан быть восстановлен из снимка"
    return 0
}

test_rollback_restores_nat_rules() {
    t_begin "rollback restores NAT and firewall rules"
    t_require_sandbox_runtime_paths
    t_seed_previous_runtime
    local status=0 archive
    t_run '
        DEPLOY_PHASE=cutover
        snapshot_runtime >/dev/null
        printf "1\n" > "$STUB_STATE_DIR/systemctl.active"
        : > "$CALL_LOG"
        ROLLBACK_ARMED=1
        die "simulated network failure"
    ' >/dev/null 2>&1 || status=$?
    t_assert_eq "$status" "30" "откат обязан завершиться успешно"
    t_assert_contains "$CALL_LOG" "--dport 46000" "правило PEER-порта обязано вернуться"
    t_assert_contains "$CALL_LOG" "--dport 46002" "правило панели обязано вернуться"
    [ "$(t_count_calls iptables MASQUERADE)" -ge 1 ] || \
        t_fail "MASQUERADE обязан восстанавливаться после отката"
    archive="$(find "$FAKE_CFG/runtime-archive" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [ -n "$archive" ] || t_fail "снимок обязан существовать"
    t_assert_contains "$archive/network.conf" "peer_port=46000" \
        "параметры сети обязаны сохраняться в снимке"
    return 0
}

test_rollback_skips_nft_when_iptables_restore_succeeds() {
    t_begin "rollback skips nft after a successful iptables-restore"
    local archive="$SANDBOX/network-archive"
    mkdir -p "$archive"
    printf '*filter\n-A INPUT -m comment --comment CSQTT_MANAGED -j ACCEPT\nCOMMIT\n' \
        >"$archive/iptables.rules"
    printf 'table ip filter {\n}\n' >"$archive/nft.rules"
    : >"$CALL_LOG"
    t_run "restore_network_rules_from_snapshot '$archive'" 2>/dev/null
    t_assert_contains "$CALL_LOG" "iptables-restore" "iptables-restore обязан применяться"
    if grep -q '^nft ' "$CALL_LOG"; then
        t_fail "nft не должен применяться поверх успешного iptables-restore"
    fi
    return 0
}

test_rollback_uses_nft_only_as_fallback() {
    t_begin "rollback uses nft only when iptables-restore fails"
    t_stub_exit iptables-restore 1
    local archive="$SANDBOX/network-archive-fallback"
    mkdir -p "$archive"
    printf '*filter\nCOMMIT\n' >"$archive/iptables.rules"
    printf 'table ip filter {\n}\n' >"$archive/nft.rules"
    : >"$CALL_LOG"
    t_run "restore_network_rules_from_snapshot '$archive'" 2>/dev/null
    t_assert_contains "$CALL_LOG" "iptables-restore" "iptables-restore обязан быть попробован"
    t_assert_contains "$CALL_LOG" "nft -f" "nft обязан подхватить восстановление после отказа"
    return 0
}

test_rollback_starts_letsencrypt_timer() {
    t_begin "rollback restarts the Let's Encrypt timer"
    t_require_sandbox_runtime_paths
    t_seed_previous_runtime
    local status=0
    t_run '
        DEPLOY_PHASE=cutover
        snapshot_runtime >/dev/null
        printf "1\n" > "$STUB_STATE_DIR/systemctl.active"
        : > "$CALL_LOG"
        ROLLBACK_ARMED=1
        die "simulated tls failure"
    ' >/dev/null 2>&1 || status=$?
    t_assert_eq "$status" "30" "откат обязан завершиться успешно"
    [ "$(t_count_calls systemctl "csqtt-letsencrypt.timer")" -ge 1 ] || \
        t_fail "откат обязан перезапустить csqtt-letsencrypt.timer"
    t_assert_contains "$CALL_LOG" "systemctl enable --now csqtt-letsencrypt.timer" \
        "таймер обязан включаться штатной командой"
    return 0
}

test_sigterm_after_arming_rolls_back() {
    t_begin "SIGTERM after arming rolls back"
    t_require_sandbox_runtime_paths
    t_seed_previous_runtime
    local out status=0
    out="$(t_run '
        DEPLOY_PHASE=cutover
        snapshot_runtime >/dev/null
        printf "1\n" > "$STUB_STATE_DIR/systemctl.active"
        ROLLBACK_ARMED=1
        kill -TERM "$BASHPID"
        sleep 0.5
        exit 99
    ' 2>&1)" || status=$?
    t_assert_eq "$status" "30" "SIGTERM после arming обязан откатить и выйти 30"
    printf '%s' "$out" | grep -Fq 'CSQTT_DEPLOY_ROLLED_BACK' || \
        t_fail "после arming SIGTERM обязан дать ROLLED_BACK (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'interrupted' || \
        t_fail "причина отката обязана быть interrupted (вывод: $out)"
    t_assert_eq "$(cat "$CSQTT_BIN_DIR/csqtt")" "old-binary" "бинарник обязан вернуться"
    t_assert_contains "$CALL_LOG" "systemctl start csqtt" "служба обязана быть запущена"
    return 0
}

test_sigterm_during_snapshot_restarts_runtime() {
    t_begin "SIGTERM during snapshot restarts the stopped runtime"
    t_require_sandbox_runtime_paths
    t_seed_previous_runtime
    local pid status=0 out="$SANDBOX/sigterm.out" waited=0
    : > "$out"
    t_run '
        # t_run исполняет код в подshell: сигнал обязан уйти именно ему, иначе
        # TERM получит родительская обёртка и установщик не увидит trap.
        printf "%s\n" "$BASHPID" > "$FAKE_CFG/installer.pid"
        stop_runtime_for_snapshot() {
            RUNTIME_STOPPED=1
            RUNTIME_STOPPED_UNITS=csqtt
            RUNTIME_SNAPSHOT_MODE=systemd
            # Метка «окно открыто»: без неё сигнал мог прийти до остановки и
            # проверить не тот сценарий.
            : > "$FAKE_CFG/stopped-in-snapshot"
            local i
            for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
                sleep 0.1
            done
        }
        snapshot_runtime
    ' >"$out" 2>&1 &
    pid=$!
    while [ "$waited" -lt 200 ]; do
        [ -s "$FAKE_CFG/installer.pid" ] && [ -e "$FAKE_CFG/stopped-in-snapshot" ] && break
        sleep 0.01
        waited=$((waited + 1))
    done
    kill -TERM "$(cat "$FAKE_CFG/installer.pid" 2>/dev/null || printf '%s' "$pid")" 2>/dev/null || true
    wait "$pid" || status=$?
    t_assert_eq "$status" "130" "сигнал в окне stop→arm обязан выйти 130"
    grep -Fq 'CSQTT_DEPLOY_ROLLED_BACK' "$out" && \
        t_fail "до arming откатывать нечего: ROLLED_BACK печататься не должен"
    t_assert_contains "$CALL_LOG" "systemctl start csqtt" \
        "остановленный прежний runtime обязан быть запущен заново"
    return 0
}

test_rollback_failure_emits_marker() {
    t_begin "rollback failure emits the failure marker"
    t_require_sandbox_runtime_paths
    t_seed_previous_runtime
    t_stub_exit systemctl 1
    local out status=0
    out="$(t_run '
        DEPLOY_PHASE=cutover
        snapshot_runtime >/dev/null
        ROLLBACK_ARMED=1
        die "simulated failure"
    ' 2>&1)" || status=$?
    t_assert_eq "$status" "31" "провал отката обязан выйти 31"
    printf '%s' "$out" | grep -Fq 'CSQTT_DEPLOY_ROLLBACK_FAILED' || \
        t_fail "провал отката обязан напечатать ROLLBACK_FAILED (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'CSQTT_DEPLOY_ROLLED_BACK' && \
        t_fail "провал отката не должен притворяться успешным"
    return 0
}

test_snapshot_stops_runtime_before_copy() {
    t_begin "snapshot stops the runtime before copying"
    t_require_sandbox_runtime_paths
    t_seed_previous_runtime
    local archive stop_line cp_line
    archive="$(t_run '
        stop_runtime_for_snapshot() {
            RUNTIME_STOPPED=1
            printf "after-stop\n" >> "$CSQTT_CONFIG_DIR/csqtt.db"
        }
        snapshot_runtime
    ' 2>/dev/null)"
    [ -n "$archive" ] || t_fail "snapshot обязан напечатать каталог снимка"
    grep -Fq 'after-stop' "$archive/csqtt.db" || \
        t_fail "SQLite обязана копироваться после остановки runtime"
    stop_line="$(grep -n '^    stop_runtime_for_snapshot >&2$' "$DEPLOY_SCRIPT" | cut -d: -f1 | head -n 1)"
    cp_line="$(grep -n '^        cp -a -- "$src" "$archive/"' "$DEPLOY_SCRIPT" | cut -d: -f1 | head -n 1)"
    [ -n "$stop_line" ] || t_fail "snapshot_runtime обязан вызывать stop_runtime_for_snapshot"
    [ -n "$cp_line" ] || t_fail "snapshot_runtime обязан копировать файлы в архив"
    [ "$stop_line" -lt "$cp_line" ] || \
        t_fail "остановка runtime обязана идти до копирования (строки $stop_line/$cp_line)"
    return 0
}

test_snapshot_failure_restarts_stopped_runtime() {
    t_begin "snapshot failure restarts the stopped runtime"
    t_require_sandbox_runtime_paths
    t_seed_previous_runtime
    chmod 000 "$FAKE_CFG/csqtt.env"
    local out status=0
    out="$(t_run '
        DEPLOY_PHASE=cutover
        snapshot_runtime
    ' 2>&1)" || status=$?
    t_assert_eq "$status" "30" "ошибка снимка в фазе cutover сохраняет код фазы (30)"
    printf '%s' "$out" | grep -Fq 'CSQTT_DEPLOY_ERROR' || \
        t_fail "ошибка снимка обязана напечатать CSQTT_DEPLOY_ERROR (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'CSQTT_DEPLOY_ROLLED_BACK' && \
        t_fail "до arming откат не печатается"
    t_assert_contains "$CALL_LOG" "systemctl stop csqtt" "снимок обязан остановить runtime"
    t_assert_contains "$CALL_LOG" "systemctl start csqtt" \
        "ошибка снимка обязана вернуть остановленный runtime"
    return 0
}


# ---------------------------------------------------------------------------
# Кейсы: Task 2 — CLI и подкоманды
# ---------------------------------------------------------------------------

test_cli_parses_host_and_mode() {
    t_begin "cli parses host and mode"
    local out
    out="$(t_run 'parse_cli --host panel.example.com --mode docker --yes || exit $?; printf "%s|%s|%s|%s" "$HOST_OVERRIDE" "$DEPLOY_MODE" "$YES" "$ACTION"')"
    t_assert_eq "$out" "panel.example.com|docker|1|install" "parse_cli result"
}

test_cli_rejects_unknown_flag() {
    t_begin "cli rejects unknown flag"
    t_run_fails 'parse_cli --bogus' 'unknown flag' "неизвестный флаг обязан дать отказ" 2
    t_run_fails 'parse_cli bogus' 'unknown command' "неизвестная команда обязана дать отказ" 2
    t_run_fails 'parse_cli --host ""' 'непустое' "пустой --host обязан дать отказ" 2
}

test_check_uninstall_is_rejected() {
    t_begin "--check uninstall is rejected"
    t_run_fails 'parse_cli --check uninstall' '--check допустим только с install/update' \
        "--check не имеет права запускать uninstall" 2
    t_run_fails 'parse_cli uninstall --check' '--check допустим только с install/update' \
        "--check после команды тоже обязан быть отклонён" 2
}

test_check_status_is_rejected() {
    t_begin "--check status is rejected"
    t_run_fails 'parse_cli status --check' '--check допустим только с install/update' \
        "--check не имеет права запускать status" 2
    t_run_fails 'parse_cli --check --purge' '--purge допустим только с uninstall' \
        "--check с --purge не должен доходить до установки" 2
}

test_cli_docker_alias() {
    t_begin "cli docker alias"
    local out
    out="$(t_run 'parse_cli --docker || exit $?; printf "%s|%s" "$DEPLOY_MODE" "$DEPLOY_MODE_EXPLICIT"')"
    t_assert_eq "$out" "docker|1" "--docker включает docker и считается явным режимом"
}

test_cli_mode_is_tristate() {
    t_begin "cli mode is tri-state"
    local out
    out="$(t_run 'unset CSQTT_DEPLOY_MODE; parse_cli || exit $?; printf "%s|%s" "$DEPLOY_MODE" "$DEPLOY_MODE_EXPLICIT"')"
    t_assert_eq "$out" "systemd|0" "без --mode режим берётся из окружения/дефолта и не считается явным"
    out="$(t_run 'unset CSQTT_DEPLOY_MODE; parse_cli --mode systemd || exit $?; printf "%s|%s" "$DEPLOY_MODE" "$DEPLOY_MODE_EXPLICIT"')"
    t_assert_eq "$out" "systemd|1" "--mode systemd задаёт режим явно"
    out="$(t_run 'unset CSQTT_DEPLOY_MODE; parse_cli --mode docker || exit $?; printf "%s|%s" "$DEPLOY_MODE" "$DEPLOY_MODE_EXPLICIT"')"
    t_assert_eq "$out" "docker|1" "--mode docker задаёт режим явно"
}

test_cli_check_does_not_require_yes() {
    t_begin "cli check does not require yes"
    local out
    out="$(t_run 'parse_cli --check || exit $?; printf "%s|%s" "$CHECK_ONLY" "$YES"')"
    t_assert_eq "$out" "1|0" "--check не требует --yes"
    # Свежий хост без state: адрес панели иначе определяется через публичный IP.
    out="$(t_run 'CSQTT_PUBLIC_IP=203.0.113.7; main --check 2>&1 || exit $?')"
    printf '%s' "$out" | grep -Fq 'CSQTT_INSTALL_CHECK_OK' || \
        t_fail "--check обязан дойти до preflight-заглушки без --yes"
    if [ -e "$CSQTT_INSTALL_LOG_FILE" ]; then
        t_fail "--check не должен создавать журнал установки"
    fi
    return 0
}

test_cli_subcommands_dispatch() {
    t_begin "cli subcommands dispatch"
    local expected out
    t_run 'main status'
    t_assert_eq "$?" "0" "status завершается успешно"
    expected="$(t_run 'printf "%s" "$SCRIPT_VERSION"')"
    out="$(t_run 'main version')"
    t_assert_eq "$out" "$expected" "version печатает SCRIPT_VERSION"
    out="$(t_run 'main --version')"
    t_assert_eq "$out" "$expected" "--version без команды печатает SCRIPT_VERSION"
    t_run 'main help' > "$SANDBOX/help.txt"
    t_assert_eq "$?" "0" "help завершается успешно"
    t_assert_contains "$SANDBOX/help.txt" 'Команды:' "help перечисляет команды"
    t_assert_contains "$SANDBOX/help.txt" '--host' "help перечисляет флаги"
}

test_cli_rejects_removed_password_flags() {
    t_begin "cli rejects removed password flags"
    t_run_fails 'parse_cli --client-password-stdin' 'unknown flag' \
        "--client-password-stdin удалён" 2
    t_run_fails 'parse_cli --main-password-stdin' 'unknown flag' \
        "--main-password-stdin удалён" 2
}

# ---------------------------------------------------------------------------
# Кейсы: Task 5 — загрузка, checksum, версия и источник CLI
# ---------------------------------------------------------------------------

test_checksum_mismatch_is_fatal() {
    t_begin "checksum mismatch is fatal"
    local zeros
    zeros="$(printf '0%.0s' {1..64})"
    printf 'payload\n' > "$SANDBOX/payload"
    printf '%s  payload\n' "$zeros" > "$SANDBOX/SHA256SUMS"
    t_run_fails 'DEPLOY_PHASE=preflight; verify_sha256 "$SANDBOX/payload" "$SANDBOX/SHA256SUMS"' \
        'CSQTT_DEPLOY_ERROR|preflight' "несовпадение checksum обязано быть фатальным" 20
}

test_binary_without_checksum_is_rejected() {
    t_begin "binary without checksum is rejected"
    printf 'binary\n' > "$SANDBOX/local-binary"
    t_run_fails 'BINARY_PATH="$SANDBOX/local-binary"; BINARY_SHA256=""; ALLOW_UNVERIFIED_BINARY=0; DEPLOY_PHASE=validation; validate_binary_options' \
        'checksum' "--binary без checksum обязан быть отклонён" 2
    [ -e "$SANDBOX/local-binary.sha256" ] && \
        t_fail "sidecar не должен появляться сам"
    return 0
}

test_binary_with_explicit_checksum_is_accepted() {
    t_begin "binary with explicit checksum is accepted"
    printf 'binary\n' > "$SANDBOX/local-binary"
    local digest
    digest="$(sha256sum -- "$SANDBOX/local-binary" | awk '{print $1}')"
    TEST_BINARY_DIGEST="$digest"
    t_run 'BINARY_PATH="$SANDBOX/local-binary"; BINARY_SHA256="$TEST_BINARY_DIGEST"; ALLOW_UNVERIFIED_BINARY=0; DEPLOY_PHASE=validation; validate_binary_options'
    t_assert_eq "$?" "0" "верный --binary-sha256 обязан пройти"
    t_run 'BINARY_PATH="$SANDBOX/local-binary"; BINARY_SHA256=""; ALLOW_UNVERIFIED_BINARY=0; printf "%s  local-binary\n" "$TEST_BINARY_DIGEST" > "$SANDBOX/local-binary.sha256"; validate_binary_options'
    t_assert_eq "$?" "0" "sidecar checksum обязан пройти"
}

test_release_redirect_resolves_tag() {
    t_begin "release redirect resolves the tag"
    t_http_redirect "https://github.com/w3struk/recsqtt/releases/tag/v2.5.2"
    local out
    out="$(t_run 'resolve_release_tag')"
    t_assert_eq "$out" "v2.5.2" "тег обязан извлекаться из /tag/ redirect"
    t_assert_contains "$CALL_LOG" "url_effective" "redirect обязан читаться через url_effective"
}

test_prepare_installer_source_downloads_and_verifies() {    t_begin "prepare installer source downloads and verifies"
    local base="https://github.com/w3struk/recsqtt" tag="v2.5.2" content digest out
    content="$(
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'echo downloaded'
    )"
    digest="$(printf '%s\n' "$content" | sha256sum | awk '{print $1}')"
    t_http_fixture "$base/releases/download/$tag/install.sh" "$content"
    t_http_fixture "$base/releases/download/$tag/SHA256SUMS" "$digest  install.sh"
    export CSQTT_WORK_DIR="$SANDBOX/work"
    out="$(t_run 'prepare_installer_source v2.5.2 >/dev/null || exit $?; printf "%s|%s" "$CSQTT_INSTALLER_SOURCE" "$(stat -c "%a" "$CSQTT_INSTALLER_SOURCE")"')"
    t_assert_eq "$out" "$SANDBOX/work/install.sh|755" \
        "источник обязан лежать в work-dir и быть исполняемым"
    t_assert_contains "$CSQTT_WORK_DIR/install.sh" "downloaded" \
        "скачанный install.sh обязан сохраниться"
    t_assert_contains "$CALL_LOG" "-o $SANDBOX/work/install.sh" \
        "ассет обязан скачиваться через curl -o"
}

test_prepare_installer_source_rejects_bad_checksum() {
    t_begin "prepare installer source rejects bad checksum"
    local base="https://github.com/w3struk/recsqtt" tag="v2.5.2"
    t_http_fixture "$base/releases/download/$tag/install.sh" '#!/usr/bin/env bash
echo downloaded'
    t_http_fixture "$base/releases/download/$tag/SHA256SUMS" "0000000000000000000000000000000000000000000000000000000000000000  install.sh"
    export CSQTT_WORK_DIR="$SANDBOX/work"
    t_run_fails 'prepare_installer_source v2.5.2' \
        'SHA-256' "подменённый install.sh обязан валить проверку" 20
}

test_reexec_guard_prevents_loop() {
    t_begin "reexec guard prevents loop"
    local marker="$SANDBOX/reexec-child-ran"
    cat > "$SANDBOX/child-installer.sh" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
    chmod 0755 "$SANDBOX/child-installer.sh"
    t_run 'VERSION_OVERRIDE=v9.9.9; BINARY_PATH=""; CSQTT_UPDATE_REEXEC=1; CSQTT_INSTALLER_SOURCE="$SANDBOX/child-installer.sh"; maybe_reexec_version v9.9.9'
    t_assert_eq "$?" "0" "guard обязан завершиться успешно"
    [ -e "$marker" ] && t_fail "при CSQTT_UPDATE_REEXEC=1 дочерний скрипт не должен запускаться"
    return 0
}

test_reexec_releases_install_lock() {
    t_begin "reexec releases the install lock"
    cat > "$SANDBOX/child-installer.sh" <<'EOF'
#!/usr/bin/env bash
if flock -n "$CSQTT_INSTALL_LOCK" true; then
    printf 'LOCK_OK\n'
else
    printf 'LOCK_BUSY\n'
fi
EOF
    chmod 0755 "$SANDBOX/child-installer.sh"
    local out status=0
    out="$(t_run '
        mkdir -p "$(dirname "$CSQTT_INSTALL_LOCK")"
        : > "$CSQTT_INSTALL_LOCK"
        exec 9>"$CSQTT_INSTALL_LOCK"
        flock -n 9 || exit 98
        VERSION_OVERRIDE=v9.9.9
        BINARY_PATH=""
        CSQTT_UPDATE_REEXEC=""
        CSQTT_INSTALLER_SOURCE="$SANDBOX/child-installer.sh"
        maybe_reexec_version v9.9.9
        printf "FALLTHROUGH\n"
    ')" || status=$?
    t_assert_eq "$status" "0" "re-exec обязан заменить процесс без ошибки"
    printf '%s' "$out" | grep -Fq 'LOCK_OK' || \
        t_fail "после exec дочерний процесс обязан взять lock (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'LOCK_BUSY' && \
        t_fail "lock остался занят: fd ${CSQTT_INSTALL_LOCK_FD} не закрыт перед exec"
    return 0
}

# Дочерний установщик получает исходный argv плюс уже разрешённые значения:
# интерактивные ответы (host/порты) иначе были бы потеряны.
t_reexec_child_writes_argv() {
    local file="$1"
    cat > "$SANDBOX/argv-installer.sh" <<EOF
#!/usr/bin/env bash
{
    printf 'argv=%s\n' "\$*"
    printf 'web_pass=%s\n' "\${CSQTT_WEB_PASS:-}"
    printf 'reexec=%s\n' "\${CSQTT_UPDATE_REEXEC:-}"
} > "$file"
EOF
    chmod 0755 "$SANDBOX/argv-installer.sh"
}

test_reexec_forwards_install_flags() {
    t_begin "reexec forwards installer flags"
    local record="$SANDBOX/reexec-record.txt"
    t_reexec_child_writes_argv "$record"
    t_run '
        INSTALLER_ARGV=(install --host old.example.com --mode docker --peer-port 46000 \
            --web-port 46002 --ssh-port 2222 --web-pass-stdin --yes)
        PANEL_HOST=panel.example.com
        PEER_PORT=46000
        WEB_PORT=443
        SSH_PORT=22
        WEB_USER=admin
        SECRET_PATH=secret-path
        DEPLOY_MODE=docker
        DEPLOY_MODE_EXPLICIT=1
        RECONFIGURE=0
        FORCE=0
        WEB_PASS=PanelPass123
        WEB_PASS_EXPLICIT=1
        VERSION_OVERRIDE=v9.9.9
        BINARY_PATH=""
        CSQTT_UPDATE_REEXEC=""
        CSQTT_INSTALLER_SOURCE="$SANDBOX/argv-installer.sh"
        maybe_reexec_version v9.9.9
    ' || t_fail "re-exec обязан заменить процесс без ошибки"
    [ -f "$record" ] || t_fail "дочерний установщик обязан быть запущен"
    local argv_line
    argv_line="$(grep -F 'argv=' "$record")"
    printf '%s' "$argv_line" | grep -Fq -- '--host panel.example.com' || \
        t_fail "re-exec обязан передать разрешённый host (argv: $argv_line)"
    printf '%s' "$argv_line" | grep -Fq -- '--mode docker' || \
        t_fail "re-exec обязан передать явный режим (argv: $argv_line)"
    printf '%s' "$argv_line" | grep -Fq -- '--peer-port 46000' || \
        t_fail "re-exec обязан передать порт туннеля (argv: $argv_line)"
    printf '%s' "$argv_line" | grep -Fq -- '--web-port 443' || \
        t_fail "re-exec обязан передать разрешённый порт панели (argv: $argv_line)"
    printf '%s' "$argv_line" | grep -Fq -- '--ssh-port 22' || \
        t_fail "re-exec обязан передать SSH-порт (argv: $argv_line)"
    printf '%s' "$argv_line" | grep -Fq -- '--version v9.9.9' || \
        t_fail "re-exec обязан передать целевую версию (argv: $argv_line)"
    printf '%s' "$argv_line" | grep -Fq -- '--yes' || \
        t_fail "re-exec обязан остаться неинтерактивным (argv: $argv_line)"
    printf '%s' "$argv_line" | grep -Fq -- '--web-pass-stdin' && \
        t_fail "re-exec не должен требовать stdin, которого уже нет (argv: $argv_line)"
    printf '%s' "$argv_line" | grep -Fq 'PanelPass123' && \
        t_fail "пароль панели не должен попадать в argv (argv: $argv_line)"
    t_assert_contains "$record" "web_pass=PanelPass123" \
        "пароль панели обязан передаваться окружением, а не argv"
    return 0
}

test_reexec_forwards_reconfigure_and_force() {
    t_begin "reexec forwards --reconfigure and --force"
    local record="$SANDBOX/reexec-record.txt"
    t_reexec_child_writes_argv "$record"
    t_run '
        INSTALLER_ARGV=(update --host panel.example.com)
        PANEL_HOST=panel.example.com
        PEER_PORT=46000
        WEB_PORT=46002
        SSH_PORT=22
        WEB_USER=admin
        SECRET_PATH=secret-path
        DEPLOY_MODE=systemd
        DEPLOY_MODE_EXPLICIT=0
        RECONFIGURE=1
        FORCE=1
        WEB_PASS=""
        VERSION_OVERRIDE=v9.9.9
        BINARY_PATH=""
        CSQTT_UPDATE_REEXEC=""
        CSQTT_INSTALLER_SOURCE="$SANDBOX/argv-installer.sh"
        maybe_reexec_version v9.9.9
    ' || t_fail "re-exec обязан заменить процесс без ошибки"
    [ -f "$record" ] || t_fail "дочерний установщик обязан быть запущен"
    t_assert_contains "$record" '--reconfigure' "reconfigure обязан пережить re-exec"
    t_assert_contains "$record" '--force' "--force обязан пережить re-exec"
    t_assert_not_contains "$record" "--mode" \
        "неявный режим не должен становиться явным флагом"
    return 0
}

test_install_cli_uses_downloaded_script_not_stdin() {
    t_begin "install cli uses downloaded script not stdin"
    t_require_sandbox_runtime_paths
    printf '#!/usr/bin/env bash\nprintf "downloaded\\n"\n' > "$SANDBOX/downloaded-install.sh"
    local status=0
    printf 'stdin\n' | t_run 'CSQTT_INSTALLER_SOURCE="$SANDBOX/downloaded-install.sh"; install_cli' || status=$?
    t_assert_eq "$status" "0" "install_cli обязан завершиться успешно"
    local installed="$CSQTT_CLI_DIR/install.sh"
    [ -f "$installed" ] || t_fail "CLI обязан быть установлен: $installed"
    t_assert_contains "$installed" "downloaded" "CLI обязан быть скопирован из скачанного источника"
    t_assert_not_contains "$installed" "stdin" "stdin не должен быть источником CLI"
    t_assert_eq "$(stat -c '%a' "$installed")" "755" "CLI обязан быть 0755"
    [ -L "$CSQTT_BIN_DIR/csqttctl" ] || t_fail "симлинк csqttctl обязан быть создан"
    t_assert_eq "$(readlink "$CSQTT_BIN_DIR/csqttctl")" "$installed" \
        "csqttctl обязан указывать на установленный install.sh"
}

test_install_cli_refuses_without_downloaded_source() {
    t_begin "install cli refuses without downloaded source"
    local out status=0
    out="$(t_run 'CSQTT_INSTALLER_SOURCE=""; install_cli')" || status=$?
    t_assert_eq "$status" "0" "без источника install_cli обязан вернуть 0"
    [ -e "$CSQTT_CLI_DIR/install.sh" ] && \
        t_fail "CLI не должен устанавливаться без скачанного источника"
    [ -e "$CSQTT_BIN_DIR/csqttctl" ] && \
        t_fail "без источника симлинк csqttctl создаваться не должен"
    printf '%s' "$out" | grep -Fq 'CLI не установлен' || \
        t_fail "нужно явное предупреждение с причиной (вывод: $out)"
    return 0
}

# ---------------------------------------------------------------------------
# Кейсы: Task 9 — csqttctl: credentials/status/logs/panel/uninstall
# ---------------------------------------------------------------------------

test_logs_prints_install_journal() {
    t_begin "logs prints the install journal"
    t_require_sandbox_runtime_paths
    t_stub_exit docker 1
    local journal="$CSQTT_INSTALL_LOG_FILE"
    printf 'journal-line-marker\n' > "$journal"
    local out
    out="$(t_run 'main logs')"
    printf '%s' "$out" | grep -Fq -- "$journal" || \
        t_fail "logs обязан печатать путь журнала установки (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'journal-line-marker' || \
        t_fail "logs обязан показывать содержимое журнала (вывод: $out)"
    printf '%s' "$out" | grep -Fq '/dev/null' && \
        t_fail "logs не должен подменять журнал на /dev/null (вывод: $out)"
    return 0
}

test_credentials_prints_panel_url_without_tunnel_password() {
    t_begin "credentials prints panel url without tunnel password"
    t_require_sandbox_runtime_paths
    t_stub_exit docker 1
    printf 'CSQTT_WEB_USER="panelowner"\nCSQTT_WEB_PASS="PanelPass123"\nCSQTT_PUBLIC_IP="panel.example.com"\nCSQTT_WEB_SECRET_PATH="secret-abc"\n' \
        > "$FAKE_CFG/csqtt.env"
    t_seed_install_state systemd domain panel.example.com 46000 443 22
    printf 'TUNNEL_SECRET_SHOULD_NOT_LEAK\n' > "$FAKE_CFG/csqtt.db"
    local out status=0
    out="$(t_run 'do_credentials')" || status=$?
    t_assert_eq "$status" "0" "credentials обязан завершиться успешно"
    printf '%s' "$out" | grep -Fq 'https://panel.example.com/secret-abc' || \
        t_fail "доменный URL панели обязан быть без порта и с secret path (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'Логин:  panelowner' || \
        t_fail "логин панели обязан печататься (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'Пароль: PanelPass123' || \
        t_fail "пароль панели обязан печататься (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'только в панели' || \
        t_fail "нужно предупреждение, что клиенты/ссылки меняются только в панели (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'TUNNEL_SECRET_SHOULD_NOT_LEAK' && \
        t_fail "credentials не должен печатать туннельные пароли из csqtt.db"
    [ -e "$FAKE_CFG/credentials.env" ] && \
        t_fail "credentials.env не должен создаваться"

    # IP-режим: порт панели входит в URL.
    printf 'CSQTT_WEB_USER="admin"\nCSQTT_WEB_PASS="PanelPass123"\nCSQTT_PUBLIC_IP="203.0.113.7"\nCSQTT_WEB_SECRET_PATH="/secret-ip/"\n' \
        > "$FAKE_CFG/csqtt.env"
    t_seed_install_state systemd ip 203.0.113.7 46000 46002 22
    out="$(t_run 'do_credentials')"
    printf '%s' "$out" | grep -Fq 'https://203.0.113.7:46002/secret-ip' || \
        t_fail "IP-URL обязан содержать порт панели и secret path без лишних слешей (вывод: $out)"
    return 0
}

test_credentials_prints_secret_path_url() {
    t_begin "credentials prints secret path in the panel url"
    t_require_sandbox_runtime_paths
    t_stub_exit docker 1
    printf 'CSQTT_WEB_USER="panelowner"\nCSQTT_WEB_PASS="PanelOwnerPass123"\nCSQTT_PUBLIC_IP="203.0.113.7"\nCSQTT_WEB_SECRET_PATH="panel-secret-1"\n' \
        > "$FAKE_CFG/csqtt.env"
    t_seed_install_state systemd ip 203.0.113.7 46000 46002 22
    local out
    out="$(t_run 'do_credentials')"
    printf '%s' "$out" | grep -Fq 'https://203.0.113.7:46002/panel-secret-1' || \
        t_fail "URL обязан содержать порт и secret path (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'Логин:  panelowner' || \
        t_fail "логин из env обязан печататься (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'Пароль: PanelOwnerPass123' || \
        t_fail "пароль из env обязан печататься (вывод: $out)"
    return 0
}

test_cli_survives_cleanup_path() {
    t_begin "cli survives cleanup path"
    t_require_sandbox_runtime_paths
    printf '#!/usr/bin/env bash\nprintf "downloaded\\n"\n' > "$SANDBOX/downloaded-install.sh"
    t_run 'CSQTT_INSTALLER_SOURCE="$SANDBOX/downloaded-install.sh"; install_cli' || \
        t_fail "install_cli обязан поставить CLI"
    [ -f "$CSQTT_CLI_DIR/install.sh" ] || t_fail "CLI обязан существовать до cleanup"
    t_stub_exit ip 1
    local output
    if ! output="$(t_run 'csqtt_cleanup' 2>&1)"; then
        printf '%s\n' "$output" >&2
        t_fail "cleanup обязан пройти целиком на переопределённых путях"
    fi
    [ -f "$CSQTT_CLI_DIR/install.sh" ] || \
        t_fail "csqtt_cleanup не должен сносить CLI (CSQTT_CLI_DIR вне CSQTT_LIB_DIR)"
    [ -L "$CSQTT_BIN_DIR/csqttctl" ] || \
        t_fail "csqtt_cleanup не должен сносить симлинк csqttctl"
    t_assert_eq "$(readlink "$CSQTT_BIN_DIR/csqttctl")" "$CSQTT_CLI_DIR/install.sh" \
        "симлинк csqttctl обязан пережить cleanup"
    return 0
}

test_uninstall_removes_cli_not_state() {
    t_begin "uninstall removes cli not state"
    t_require_sandbox_runtime_paths
    mkdir -p "$CSQTT_CLI_DIR" "$CSQTT_BIN_DIR"
    printf '#!/usr/bin/env bash\nprintf "cli\\n"\n' > "$CSQTT_CLI_DIR/install.sh"
    chmod 0755 "$CSQTT_CLI_DIR/install.sh"
    ln -s "$CSQTT_CLI_DIR/install.sh" "$CSQTT_BIN_DIR/csqttctl"
    t_seed_install_state systemd ip 203.0.113.7 46000 46002 22
    printf 'important-db\n' > "$FAKE_CFG/csqtt.db"
    printf 'CSQTT_WEB_PASS="kept"\n' > "$FAKE_CFG/csqtt.env"
    printf 'le-account\n' > "$FAKE_LE/account.txt"
    t_stub_exit ip 1
    local output
    if ! output="$(t_run 'do_uninstall' 2>&1)"; then
        printf '%s\n' "$output" >&2
        t_fail "uninstall обязан пройти целиком на переопределённых путях"
    fi
    [ -e "$CSQTT_CLI_DIR/install.sh" ] && t_fail "uninstall обязан удалить CLI install.sh"
    [ -e "$CSQTT_BIN_DIR/csqttctl" ] && t_fail "uninstall обязан удалить симлинк csqttctl"
    [ -f "$FAKE_CFG/install.json" ] || t_fail "uninstall без --purge обязан сохранить install.json"
    [ -f "$FAKE_CFG/csqtt.db" ] || t_fail "uninstall без --purge обязан сохранить csqtt.db"
    [ -f "$FAKE_CFG/csqtt.env" ] || t_fail "uninstall без --purge обязан сохранить csqtt.env"
    [ -f "$FAKE_LE/account.txt" ] || t_fail "uninstall не должен трогать /etc/letsencrypt"
    return 0
}

# uninstall обязан брать тот же lock, что install/update: иначе он снесёт
# runtime под идущим cutover.
test_uninstall_takes_install_lock() {
    t_begin "uninstall takes the install lock"
    local marks="$SANDBOX/uninstall-order"
    t_run "
        check_root() { printf 'root\n' >> '$marks'; }
        acquire_install_lock() { printf 'lock\n' >> '$marks'; }
        do_uninstall() { printf 'uninstall\n' >> '$marks'; }
        uninstall_main
    "
    t_assert_contains "$marks" "lock" "uninstall_main обязан брать install lock"
    t_assert_before "$marks" "lock" "uninstall" "lock обязан браться до удаления runtime"
}

test_update_replaces_cli_atomically() {
    t_begin "update replaces cli atomically"
    t_require_sandbox_runtime_paths
    printf '#!/usr/bin/env bash\nprintf "v1\\n"\n' > "$SANDBOX/install-v1.sh"
    printf '#!/usr/bin/env bash\nprintf "v2\\n"\n' > "$SANDBOX/install-v2.sh"
    t_run 'CSQTT_INSTALLER_SOURCE="$SANDBOX/install-v1.sh"; install_cli' || \
        t_fail "первичная установка CLI обязана пройти"
    t_run 'CSQTT_INSTALLER_SOURCE="$SANDBOX/install-v2.sh"; install_cli' || \
        t_fail "update обязан заменить CLI"
    local installed="$CSQTT_CLI_DIR/install.sh" count leftover
    t_assert_contains "$installed" 'v2' "update обязан заменить содержимое CLI"
    t_assert_eq "$(stat -c '%a' "$installed")" "755" "CLI после update обязан быть 0755"
    t_assert_eq "$(readlink "$CSQTT_BIN_DIR/csqttctl")" "$installed" \
        "симлинк обязан указывать на новый CLI"
    count="$(find "$CSQTT_CLI_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"
    t_assert_eq "$count" "1" "повторный update не должен плодить копии CLI"
    leftover="$(find "$CSQTT_CLI_DIR" -maxdepth 1 -name '.install.sh.*' -print -quit)"
    [ -z "$leftover" ] || t_fail "после update не должно оставаться временных файлов: $leftover"
    return 0
}

test_binary_version_does_not_reexec() {
    t_begin "binary version does not reexec"
    local marker="$SANDBOX/binary-reexec-ran"
    cat > "$SANDBOX/child-installer.sh" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
    chmod 0755 "$SANDBOX/child-installer.sh"
    t_run 'BINARY_PATH="/tmp/local-csqtt"; VERSION_OVERRIDE=v9.9.9; CSQTT_UPDATE_REEXEC=""; CSQTT_INSTALLER_SOURCE="$SANDBOX/child-installer.sh"; maybe_reexec_version v9.9.9'
    t_assert_eq "$?" "0" "--binary с другой версией не должен падать"
    [ -e "$marker" ] && t_fail "при --binary re-exec не должен запускаться"
    return 0
}

# ---------------------------------------------------------------------------
# Кейсы: Task 6 — fresh/update/adoption и csqtt.env
# ---------------------------------------------------------------------------

t_seed_install_state() {
    local mode="$1" panel_mode="$2" panel_host="$3" peer="$4" web="$5" ssh="$6" version
    # Версия берётся из установщика, а не литералом: иначе каждый бамп версии
    # ломает кейсы «та же версия → no-op».
    version="$(sed -n 's/^readonly SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$DEPLOY_SCRIPT" | head -n 1)"
    [ -n "$version" ] || version="2.5.2"
    mkdir -p "$FAKE_CFG"
    printf '{"version":"%s","mode":"%s","panel_mode":"%s","panel_host":"%s","peer_port":"%s","web_port":"%s","ssh_port":"%s","tls":"","installed_at":"1","updated_at":"1"}\n' \
        "$version" "$mode" "$panel_mode" "$panel_host" "$peer" "$web" "$ssh" > "$FAKE_CFG/install.json"
}

panel_env_value() {
    local key="$1"
    t_run "env_file_value ${key} \"${FAKE_CFG}/csqtt.env\""
}

test_fresh_install_generates_random_panel_identity() {
    t_begin "fresh install generates random panel identity"
    t_stub_exit docker 1
    t_run 'parse_cli --host 203.0.113.7 --yes; resolve_install_configuration; setup_csqtt_environment'
    t_assert_eq "$?" "0" "fresh install обязан записать csqtt.env"
    [ -e "$FAKE_CFG/deploy-overrides.json" ] && \
        t_fail "новый установщик не должен создавать deploy-overrides.json"
    [ -f "$FAKE_CFG/csqtt.env" ] || t_fail "csqtt.env обязан существовать"

    local user pass secret
    user="$(panel_env_value CSQTT_WEB_USER)"
    pass="$(panel_env_value CSQTT_WEB_PASS)"
    secret="$(panel_env_value CSQTT_WEB_SECRET_PATH)"

    [ "$user" != "admin" ] || t_fail "fresh-логин не должен быть admin"
    [[ "$user" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || t_fail "логин невалиден: $user"
    [ "${#pass}" -ge 16 ] || t_fail "пароль короче 16 символов: ${#pass}"
    [[ "$pass" =~ ^[A-Za-z0-9]+$ ]] || t_fail "пароль содержит недопустимые символы: $pass"
    [ -n "$secret" ] || t_fail "secret path не должен быть пустым"
    [[ "$secret" =~ ^[A-Za-z0-9_-]{8,64}$ ]] || t_fail "secret path невалиден: $secret"
    [ "$user" != "$pass" ] || t_fail "логин и пароль не должны совпадать"
    [ "$user" != "$secret" ] || t_fail "логин и secret path не должны совпадать"
    [ "$pass" != "$secret" ] || t_fail "пароль и secret path не должны совпадать"

    t_assert_contains "$FAKE_CFG/csqtt.env" 'CSQTT_PUBLIC_IP="203.0.113.7"' "host обязан попасть в env"
    t_assert_eq "$(stat -c '%a' "$FAKE_CFG/csqtt.env")" "600" "csqtt.env обязан быть 0600"
    return 0
}

test_fresh_install_accepts_explicit_web_credentials() {
    t_begin "fresh install accepts explicit web credentials"
    t_stub_exit docker 1
    # Пароль через окружение.
    CSQTT_WEB_PASS='ExplicitPanelPass123' t_run '
        parse_cli --host 203.0.113.7 --yes --web-user ops.login --secret-path secret_PATH-123
        resolve_install_configuration
        setup_csqtt_environment
    '
    t_assert_eq "$?" "0" "fresh install с явными доступами обязан пройти"
    t_assert_eq "$(panel_env_value CSQTT_WEB_USER)" "ops.login" "явный логин обязан сохраниться"
    t_assert_eq "$(panel_env_value CSQTT_WEB_PASS)" "ExplicitPanelPass123" "пароль из env обязан сохраниться"
    t_assert_eq "$(panel_env_value CSQTT_WEB_SECRET_PATH)" "secret_PATH-123" "явный secret path обязан сохраниться"

    # Пароль через --web-pass-stdin (в тесте — файл вместо TTY). Второй прогон
    # должен быть fresh: без этого существующий csqtt.env включит preservation.
    rm -f "$FAKE_CFG/csqtt.env"
    printf 'StdinPanelPass123456\n' > "$SANDBOX/pass-stdin"
    CSQTT_TTY_PATH="$SANDBOX/pass-stdin" t_run '
        parse_cli --host 198.51.100.5 --yes --web-user stdinuser --secret-path stdin_secret_1 --web-pass-stdin
        read_web_password_if_requested
        resolve_install_configuration
        setup_csqtt_environment
    ' < "$SANDBOX/pass-stdin"
    t_assert_eq "$?" "0" "--web-pass-stdin обязан принять пароль"
    t_assert_eq "$(panel_env_value CSQTT_WEB_USER)" "stdinuser" "--web-user обязан сохраниться"
    t_assert_eq "$(panel_env_value CSQTT_WEB_PASS)" "StdinPanelPass123456" "пароль из stdin обязан сохраниться"
    t_assert_eq "$(panel_env_value CSQTT_WEB_SECRET_PATH)" "stdin_secret_1" "--secret-path обязан сохраниться"
    return 0
}

test_update_preserves_panel_identity() {
    t_begin "update preserves panel identity"
    t_stub_exit docker 1
    mkdir -p "$FAKE_CFG"
    printf 'CSQTT_WEB_USER="legacyuser"\nCSQTT_WEB_PASS="LegacyPanelPass123"\nCSQTT_PUBLIC_IP="panel.example.com"\nCSQTT_WEB_SECRET_PATH="legacySecret1"\n' \
        > "$FAKE_CFG/csqtt.env"
    t_seed_install_state systemd domain panel.example.com 46000 443 22

    # --reconfigure --host меняет только host: env перезаписывается, identity — нет.
    # csqtt_cleanup удаляет csqtt.env до build, поэтому identity должна быть снята
    # в глобалы на этапе resolve.
    t_run '
        parse_cli update --reconfigure --host new.example.com --yes
        resolve_install_configuration
        rm -f "$CSQTT_ENV_FILE"
        setup_csqtt_environment
    '
    t_assert_eq "$?" "0" "update с перезаписью env обязан пройти"
    t_assert_eq "$(panel_env_value CSQTT_WEB_USER)" "legacyuser" "update не должен менять логин"
    t_assert_eq "$(panel_env_value CSQTT_WEB_PASS)" "LegacyPanelPass123" "update не должен менять пароль"
    t_assert_eq "$(panel_env_value CSQTT_WEB_SECRET_PATH)" "legacySecret1" "update не должен менять secret path"
    t_assert_eq "$(panel_env_value CSQTT_PUBLIC_IP)" "new.example.com" "update обязан обновить host"

    # Пустой secret path старой установки остаётся пустым: иначе сменится URL.
    printf 'CSQTT_WEB_USER="legacyuser"\nCSQTT_WEB_PASS="LegacyPanelPass123"\nCSQTT_PUBLIC_IP="new.example.com"\nCSQTT_WEB_SECRET_PATH=""\n' \
        > "$FAKE_CFG/csqtt.env"
    t_run '
        parse_cli update --reconfigure --host newer.example.com --yes
        resolve_install_configuration
        rm -f "$CSQTT_ENV_FILE"
        setup_csqtt_environment
    '
    t_assert_eq "$?" "0" "update с пустым secret path обязан пройти"
    t_assert_eq "$(panel_env_value CSQTT_WEB_SECRET_PATH)" "" "пустой secret path обязан остаться пустым"
    t_assert_eq "$(panel_env_value CSQTT_WEB_USER)" "legacyuser" "update не должен подменять логин при пустом secret path"
    return 0
}

test_panel_identity_validation_rejects_bad_values() {
    t_begin "panel identity validation rejects bad values"
    t_stub_exit docker 1
    t_run_fails \
        'parse_cli --host 203.0.113.7 --yes --web-user a; resolve_install_configuration' \
        'Логин панели' "короткий логин обязан быть отклонён" 2
    t_run_fails \
        'parse_cli --host 203.0.113.7 --yes --secret-path "/bad/path/here"; resolve_install_configuration' \
        'Secret path' "secret path со слешами обязан быть отклонён" 2
    t_run_fails \
        'parse_cli --host 203.0.113.7 --yes --secret-path ""; resolve_install_configuration' \
        'Secret path' "пустой явный secret path обязан быть отклонён" 2
    t_run_fails \
        'CSQTT_WEB_PASS=shortpass; parse_cli --host 203.0.113.7 --yes; resolve_install_configuration' \
        'не короче 16' "короткий fresh-пароль обязан быть отклонён" 2

    : > "$SANDBOX/empty-pass"
    local out status=0
    out="$(CSQTT_TTY_PATH="$SANDBOX/empty-pass" t_run '
        parse_cli --host 203.0.113.7 --yes --web-pass-stdin
        read_web_password_if_requested
    ' < "$SANDBOX/empty-pass" 2>&1)" || status=$?
    t_assert_eq "$status" "2" "пустой пароль из stdin обязан завершиться кодом 2"
    printf '%s' "$out" | grep -Fq 'пустой пароль' || \
        t_fail "отказ обязан объяснить, что пароль пуст (вывод: $out)"
    return 0
}

test_interactive_panel_customization_defaults_to_generated() {
    t_begin "interactive panel customization defaults to generated"
    t_stub_exit docker 1
    local out user pass secret

    # Ответ N (дефолт) — случайные значения.
    out="$(printf 'N\n' | t_run '
        CSQTT_ASSUME_TTY=1
        parse_cli --host 203.0.113.7 --peer-port 46000 --web-port 46002 --mode systemd
        resolve_install_configuration
        setup_csqtt_environment
        printf "PANEL|%s|%s|%s\n" \
            "$(env_file_value CSQTT_WEB_USER "$CSQTT_ENV_FILE")" \
            "$(env_file_value CSQTT_WEB_PASS "$CSQTT_ENV_FILE")" \
            "$(env_file_value CSQTT_WEB_SECRET_PATH "$CSQTT_ENV_FILE")"
    ' 2>/dev/null | sed -n 's/^PANEL|//p' | tail -n 1)"
    IFS='|' read -r user pass secret <<< "$out"
    [ "$user" != "admin" ] || t_fail "ответ N не должен давать admin"
    [[ "$user" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || t_fail "логин после N невалиден: $user"
    [ "${#pass}" -ge 16 ] || t_fail "пароль после N короче 16 символов"
    [[ "$secret" =~ ^[A-Za-z0-9_-]{8,64}$ ]] || t_fail "secret path после N невалиден: $secret"

    # Ответ y и явные значения. Второй прогон fresh: иначе env включит preservation.
    rm -f "$FAKE_CFG/csqtt.env"
    out="$(printf 'y\ncustomuser\nCustomPanelPass123\ncustom-secret-1\n' | t_run '
        CSQTT_ASSUME_TTY=1
        parse_cli --host 203.0.113.7 --peer-port 46000 --web-port 46002 --mode systemd
        resolve_install_configuration
        setup_csqtt_environment
        printf "PANEL|%s|%s|%s\n" \
            "$(env_file_value CSQTT_WEB_USER "$CSQTT_ENV_FILE")" \
            "$(env_file_value CSQTT_WEB_PASS "$CSQTT_ENV_FILE")" \
            "$(env_file_value CSQTT_WEB_SECRET_PATH "$CSQTT_ENV_FILE")"
    ' 2>/dev/null | sed -n 's/^PANEL|//p' | tail -n 1)"
    IFS='|' read -r user pass secret <<< "$out"
    t_assert_eq "$user" "customuser" "интерактивный логин обязан примениться"
    t_assert_eq "$pass" "CustomPanelPass123" "интерактивный пароль обязан примениться"
    t_assert_eq "$secret" "custom-secret-1" "интерактивный secret path обязан примениться"
    return 0
}

test_interactive_mode_prompt_reasks_on_invalid_input() {
    t_begin "interactive mode prompt re-asks on invalid input"
    t_stub_exit docker 1
    local out

    # peer (Enter), web (Enter), mode: «y» отвергается и переспрашивается,
    # затем docker, затем identity (N).
    out="$(printf '\n\ny\ndocker\nN\n' | t_run '
        CSQTT_ASSUME_TTY=1
        parse_cli --host 203.0.113.7
        resolve_install_configuration
        printf "MODE=%s|PEER=%s|WEB=%s\n" "$DEPLOY_MODE" "$PEER_PORT" "$WEB_PORT"
    ' 2>/dev/null | sed -n 's/^MODE=//p' | tail -n 1)"
    t_assert_eq "$out" "docker|PEER=46000|WEB=46002" \
        "невалидный режим обязан переспросить, валидный — примениться"
    return 0
}

test_interactive_port_prompt_reasks_on_invalid_input() {
    t_begin "interactive port prompt re-asks on invalid input"
    t_stub_exit docker 1
    local out

    # peer: «abc» отвергается, затем 47000; web (Enter), mode (Enter), identity (N).
    out="$(printf 'abc\n47000\n\n\nN\n' | t_run '
        CSQTT_ASSUME_TTY=1
        parse_cli --host 203.0.113.7
        resolve_install_configuration
        printf "PEER=%s|MODE=%s\n" "$PEER_PORT" "$DEPLOY_MODE"
    ' 2>/dev/null | sed -n 's/^PEER=//p' | tail -n 1)"
    t_assert_eq "$out" "47000|MODE=systemd" \
        "невалидный порт обязан переспросить, валидный — примениться"
    return 0
}

test_interactive_domain_answer_selects_domain_mode() {
    t_begin "interactive domain answer selects domain mode"
    t_stub_exit docker 1
    local out

    # domain, peer (Enter), mode (Enter), identity (N). Порт панели в доменном
    # режиме не спрашивается.
    out="$(printf 'vpn.example.com\n\n\nN\n' | t_run '
        CSQTT_ASSUME_TTY=1
        parse_cli
        resolve_install_configuration
        printf "MODE=%s|HOST=%s|WEB=%s\n" "${PANEL_MODE:-}" "${PANEL_HOST:-}" "$WEB_PORT"
    ' 2>/dev/null | sed -n 's/^MODE=//p' | tail -n 1)"
    t_assert_eq "$out" "domain|HOST=vpn.example.com|WEB=443" \
        "ответ доменом обязан включать доменный режим"
    return 0
}

test_interactive_domain_choice_accepts_domain_with_matching_a_record() {
    t_begin "domain choice accepts a domain whose A record matches"
    t_stub_exit docker 1
    local out

    # y → домен → peer/web/mode (Enter) → identity (N).
    out="$(printf 'y\nvpn.example.com\n\n\n\nN\n' | t_run '
        CSQTT_ASSUME_TTY=1
        detect_public_ipv4() { printf "203.0.113.7\n"; }
        resolve_a_record_addresses() { printf "203.0.113.7\n"; }
        parse_cli
        resolve_install_configuration
        printf "MODE=%s|HOST=%s|WEB=%s\n" "${PANEL_MODE:-}" "${PANEL_HOST:-}" "$WEB_PORT"
    ' 2>/dev/null | sed -n 's/^MODE=//p' | tail -n 1)"
    t_assert_eq "$out" "domain|HOST=vpn.example.com|WEB=443" \
        "домен с совпадающей A-записью обязан включить доменный режим"
    return 0
}

test_interactive_domain_choice_falls_back_to_ip_on_mismatch() {
    t_begin "domain choice falls back to IP on A record mismatch"
    t_stub_exit docker 1
    local out err status=0

    # y → домен (A чужая) → переспрос → пустой ответ = IP → порты/режим → identity.
    err="$(printf 'y\nvpn.example.com\n\n\n\n\nN\n' | t_run '
        CSQTT_ASSUME_TTY=1
        detect_public_ipv4() { printf "203.0.113.7\n"; }
        resolve_a_record_addresses() { printf "198.51.100.9\n"; }
        parse_cli
        resolve_install_configuration
        printf "MODE=%s|HOST=%s|WEB=%s\n" "${PANEL_MODE:-}" "${PANEL_HOST:-}" "$WEB_PORT"
    ' 2>&1)" || status=$?
    t_assert_eq "$status" "0" "несовпадение A-записи не должно ронять установку"
    printf '%s' "$err" | grep -Fq '198.51.100.9' || \
        t_fail "переспрос обязан показать найденную A-запись (вывод: $err)"
    printf '%s' "$err" | sed -n 's/^MODE=//p' | tail -n 1 > "$SANDBOX/mode.txt"
    t_assert_eq "$(cat "$SANDBOX/mode.txt")" "ip|HOST=203.0.113.7|WEB=46002" \
        "пустой ответ после несовпадения обязан вернуть IP-режим"
    return 0
}

test_interactive_no_domain_choice_goes_straight_to_ip() {
    t_begin "answering n skips the domain question"
    t_stub_exit docker 1
    local out

    # n → peer/web/mode (Enter) → identity (N). Второго вопроса про домен нет.
    out="$(printf 'n\n\n\n\nN\n' | t_run '
        CSQTT_ASSUME_TTY=1
        detect_public_ipv4() { printf "203.0.113.7\n"; }
        parse_cli
        resolve_install_configuration
        printf "MODE=%s|HOST=%s|WEB=%s\n" "${PANEL_MODE:-}" "${PANEL_HOST:-}" "$WEB_PORT"
    ' 2>/dev/null | sed -n 's/^MODE=//p' | tail -n 1)"
    t_assert_eq "$out" "ip|HOST=203.0.113.7|WEB=46002" \
        "ответ n обязан сразу включать IP-режим"
    return 0
}

test_interactive_default_enter_falls_back_to_ip() {
    t_begin "Enter, then an empty domain, falls back to IP"
    t_stub_exit docker 1
    local out

    # Enter = «да, домен», Enter на домене = остаться на IP, затем порты/режим/identity.
    out="$(printf '\n\n\n\n\nN\n' | t_run '
        CSQTT_ASSUME_TTY=1
        detect_public_ipv4() { printf "203.0.113.7\n"; }
        parse_cli
        resolve_install_configuration
        printf "MODE=%s|HOST=%s|WEB=%s\n" "${PANEL_MODE:-}" "${PANEL_HOST:-}" "$WEB_PORT"
    ' 2>/dev/null | sed -n 's/^MODE=//p' | tail -n 1)"
    t_assert_eq "$out" "ip|HOST=203.0.113.7|WEB=46002" \
        "Enter-Enter обязан давать IP-режим"
    return 0
}

test_update_interactive_can_switch_to_domain() {
    t_begin "interactive update can switch the panel to a domain"
    t_stub_exit docker 1
    t_seed_previous_runtime
    t_seed_install_state systemd ip 203.0.113.7 46000 46002 22
    local out

    out="$(printf 'y\nvpn.example.com\n' | t_run '
        CSQTT_ASSUME_TTY=1
        detect_public_ipv4() { printf "203.0.113.7\n"; }
        resolve_a_record_addresses() { printf "203.0.113.7\n"; }
        parse_cli
        resolve_install_configuration
        printf "MODE=%s|HOST=%s|WEB=%s|RECONFIG=%s\n" \
            "${PANEL_MODE:-}" "${PANEL_HOST:-}" "$WEB_PORT" "${RECONFIGURE:-0}"
    ' 2>/dev/null | sed -n 's/^MODE=//p' | tail -n 1)"
    t_assert_eq "$out" "domain|HOST=vpn.example.com|WEB=443|RECONFIG=1" \
        "ответ y и домен обязаны переключить установку в доменный режим"
    return 0
}

test_update_interactive_keeps_address_by_default() {
    t_begin "interactive update keeps the address by default"
    t_stub_exit docker 1
    t_seed_previous_runtime
    t_seed_install_state systemd ip 203.0.113.7 46000 46002 22
    local out

    out="$(printf '\n' | t_run '
        CSQTT_ASSUME_TTY=1
        detect_public_ipv4() { printf "203.0.113.7\n"; }
        resolve_a_record_addresses() { printf "203.0.113.7\n"; }
        parse_cli
        resolve_install_configuration
        printf "MODE=%s|HOST=%s|WEB=%s|RECONFIG=%s\n" \
            "${PANEL_MODE:-}" "${PANEL_HOST:-}" "$WEB_PORT" "${RECONFIGURE:-0}"
    ' 2>/dev/null | sed -n 's/^MODE=//p' | tail -n 1)"
    t_assert_eq "$out" "ip|HOST=203.0.113.7|WEB=46002|RECONFIG=0" \
        "Enter на вопросе о смене адреса обязан оставить всё как было"
    return 0
}

test_update_preserves_env_verbatim() {
    t_begin "update preserves csqtt.env verbatim"
    t_stub_exit docker 1
    mkdir -p "$FAKE_CFG"
    printf 'CSQTT_WEB_USER="admin"\nCSQTT_WEB_PASS="PreservedPass123"\nCSQTT_PUBLIC_IP="panel.example.com"\nCSQTT_WEB_SECRET_PATH="secret-path"\n' \
        > "$FAKE_CFG/csqtt.env"
    t_seed_install_state systemd domain panel.example.com 46000 443 22
    local before after
    before="$(sha256sum "$FAKE_CFG/csqtt.env" | awk '{print $1}')"
    t_run 'parse_cli update --yes; resolve_install_configuration; setup_csqtt_environment'
    t_assert_eq "$?" "0" "update обязан пройти без конфликтов"
    after="$(sha256sum "$FAKE_CFG/csqtt.env" | awk '{print $1}')"
    t_assert_eq "$after" "$before" "update без флагов обязан сохранить csqtt.env байт-в-байт"
    return 0
}

test_conflicting_port_without_reconfigure_fails() {
    t_begin "conflicting port without reconfigure fails"
    t_stub_exit docker 1
    t_seed_install_state systemd ip 203.0.113.7 46000 46002 22
    t_run_fails 'parse_cli --peer-port 46001 --yes; resolve_install_configuration' \
        '--reconfigure' "смена порта без --reconfigure обязана быть отклонена" 2
    return 0
}

test_failed_install_does_not_change_install_json() {
    t_begin "failed install does not rewrite install.json"
    t_stub_exit docker 1
    t_seed_install_state systemd domain old.example.com 46000 443 22
    local before after
    before="$(sha256sum "$FAKE_CFG/install.json" | awk '{print $1}')"
    # Разрешение конфигурации — самое раннее место, где раньше писался state.
    # Оно обязано только прочитать установку; запись — после успешной активации.
    t_run 'parse_cli --reconfigure --host new.example.com --yes; resolve_install_configuration'
    t_assert_eq "$?" "0" "разрешение конфигурации обязано завершиться успешно"
    after="$(sha256sum "$FAKE_CFG/install.json" | awk '{print $1}')"
    t_assert_eq "$after" "$before" \
        "install.json не должен меняться до успешной активации"
    return 0
}

test_reconfigure_without_mode_preserves_docker() {
    t_begin "reconfigure without mode preserves docker"
    t_stub_exit docker 1
    t_seed_install_state docker domain old.example.com 46000 443 22
    local out before after
    before="$(sha256sum "$FAKE_CFG/install.json" | awk '{print $1}')"
    out="$(t_run 'parse_cli --reconfigure --host new.example.com --yes; resolve_install_configuration; printf "%s|%s|%s" "$DEPLOY_MODE" "$PANEL_MODE" "$PANEL_HOST"')"
    t_assert_eq "$out" "docker|domain|new.example.com" \
        "--reconfigure --host не должен менять DEPLOY_MODE и обязан обновить host"
    after="$(sha256sum "$FAKE_CFG/install.json" | awk '{print $1}')"
    t_assert_eq "$after" "$before" \
        "resolve_install_configuration не должен писать install.json до активации"
    return 0
}

test_install_configuration_uses_install_json_not_unit() {
    t_begin "install configuration comes from install.json, not from the unit"
    t_stub_exit docker 1
    mkdir -p "$CSQTT_SYSTEMD_DIR"
    cat > "$CSQTT_SYSTEMD_DIR/csqtt.service" <<EOF
[Service]
ExecStart=${CSQTT_BIN_DIR}/csqtt --listen 0.0.0.0:46000 --web-port 46002 --config-dir ${CSQTT_CONFIG_DIR}
EOF
    printf 'CSQTT_PUBLIC_IP="panel.example.com"\n' > "$FAKE_CFG/csqtt.env"
    t_seed_install_state systemd ip 203.0.113.7 47000 47002 2222
    local out
    out="$(t_run 'parse_cli --yes; resolve_install_configuration; printf "%s|%s|%s|%s|%s" \
        "$DEPLOY_MODE" "$PEER_PORT" "$WEB_PORT" "$PANEL_MODE" "$PANEL_HOST"')"
    t_assert_eq "$?" "0" "resolve_install_configuration обязан завершиться успешно"
    t_assert_eq "$out" "systemd|47000|47002|ip|203.0.113.7" \
        "install.json — источник истины; unit и env не подменяют режим, порты и host"
    return 0
}

test_install_configuration_ignores_unit_with_foreign_config_dir() {
    t_begin "install configuration ignores a unit with a different config dir"
    t_stub_exit docker 1
    mkdir -p "$CSQTT_SYSTEMD_DIR"
    local other="$SANDBOX/other-config"
    cat > "$CSQTT_SYSTEMD_DIR/csqtt.service" <<EOF
[Service]
ExecStart=${CSQTT_BIN_DIR}/csqtt --listen 0.0.0.0:46000 --web-port 46002 --config-dir ${other}
EOF
    t_seed_install_state docker ip 203.0.113.7 46000 46002 22
    local before after out
    before="$(sha256sum "$FAKE_CFG/install.json" | awk '{print $1}')"
    out="$(t_run 'parse_cli --yes; resolve_install_configuration; printf "%s|%s|%s" \
        "$DEPLOY_MODE" "$PANEL_MODE" "$PANEL_HOST"')"
    t_assert_eq "$?" "0" "чужой unit не должен ронять установку по install.json"
    t_assert_eq "$out" "docker|ip|203.0.113.7" \
        "режим и host берутся из install.json, а не из чужого --config-dir"
    after="$(sha256sum "$FAKE_CFG/install.json" | awk '{print $1}')"
    t_assert_eq "$after" "$before" "resolve не должен переписывать install.json"
    [ -e "$other" ] && t_fail "чужой config-dir не должен создаваться"
    return 0
}

test_check_without_panel_host_reports_and_install_requires_host() {
    t_begin "check without panel_host reports, install requires --host"
    t_stub_exit docker 1
    t_seed_install_state systemd ip "" 46000 46002 22
    local out status=0 before after
    before="$(sha256sum "$FAKE_CFG/install.json" | awk '{print $1}')"
    out="$(t_run 'parse_cli --check; resolve_install_configuration; printf "CHECK_DONE\n"')" || status=$?
    t_assert_eq "$status" "0" "--check при state без host обязан выйти 0"
    printf '%s' "$out" | grep -Fq 'Обнаружена существующая установка' || \
        t_fail "--check обязан напечатать найденное (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'ADOPTION_AMBIGUOUS=1' || \
        t_fail "--check обязан сообщить об отсутствии host (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'CHECK_DONE' || t_fail "--check обязан дойти до конца"
    after="$(sha256sum "$FAKE_CFG/install.json" | awk '{print $1}')"
    t_assert_eq "$after" "$before" "--check не должен писать install.json"
    t_run_fails 'parse_cli install --yes; resolve_install_configuration' \
        '--host' "install без host в state обязан требовать --host/--reconfigure" 2
    return 0
}

# ---------------------------------------------------------------------------
# Кейсы: Task 7 — онлайн-установка, TTY и --check
# ---------------------------------------------------------------------------

# Готовит no-op подмены для install_main: тест проверяет только порядок шагов.
# prepare_candidate_release, run_platform_preflight и probe_nat_and_firewall
# намеренно не подменяются — их и проверяют кейсы порядка.
t_install_stage_stubs() {
    local file="$1" marks="$2"
    cat > "$file" <<EOF
check_root() { printf 'root\n' >> "$marks"; }
require_tty_guard() { printf 'tty\n' >> "$marks"; }
acquire_install_lock() { printf 'lock\n' >> "$marks"; }
read_web_password_if_requested() { printf 'password\n' >> "$marks"; }
validate_binary_options() { :; }
resolve_install_configuration() { printf 'config\n' >> "$marks"; }
resolve_panel_mode() { :; }
print_installer_header() { :; }
detect_os() { printf 'os\n' >> "$marks"; }
install_prerequisites() { printf 'deps\n' >> "$marks"; }
require_runtime_tools() { printf 'arch\n' >> "$marks"; }
ensure_docker() { printf 'docker\n' >> "$marks"; }
setup_sysctl() { printf 'sysctl\n' >> "$marks"; }
tune_cpu_mitigations() { :; }
prepare_installer_source() { printf 'installer_source\n' >> "$marks"; }
maybe_reexec_version() { :; }
prepare_docker_candidate() { printf 'docker_preflight\n' >> "$marks"; }
run_domain_mode_preflight() { printf 'domain_preflight\n' >> "$marks"; }
preserve_existing_csqtt_env() { printf 'preserve\n' >> "$marks"; }
snapshot_runtime() { printf 'snapshot\n' >> "$marks"; }
csqtt_cleanup() { printf 'cleanup\n' >> "$marks"; printf 'CLEANUP_REACHED\n'; }
setup_nat_and_firewall() { printf 'nat\n' >> "$marks"; }
install_network_helper() { printf 'helper\n' >> "$marks"; }
setup_csqtt_environment() { printf 'env\n' >> "$marks"; }
setup_web_panel_tls() { printf 'tls\n' >> "$marks"; }
setup_csqtt_binary() { printf 'binary\n' >> "$marks"; }
force_stop_csqtt_processes() { printf 'stop\n' >> "$marks"; }
assert_web_port_is_available() { printf 'port\n' >> "$marks"; }
setup_csqtt_docker() { printf 'activate\n' >> "$marks"; }
setup_csqtt_service() { printf 'activate\n' >> "$marks"; }
start_csqtt() { printf 'health\n' >> "$marks"; }
install_cli() { printf 'cli\n' >> "$marks"; }
write_install_state() { printf 'state\n' >> "$marks"; }
EOF
}

test_non_root_rejected_before_tty_guard() {
    t_begin "non-root is rejected before the TTY guard"
    local out status=0
    out="$(t_run 'id() { printf "1000\n"; }; install_main' </dev/null 2>&1)" || status=$?
    t_assert_eq "$status" "2" "non-root обязан получить exit 2"
    printf '%s' "$out" | grep -Fq 'sudo bash' || \
        t_fail "отказ обязан показать путь curl -o && sudo bash (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'curl' || \
        t_fail "отказ обязан показать curl (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'TTY' && \
        t_fail "non-root не должен упираться в TTY-guard (вывод: $out)"

    local marks="$SANDBOX/order"
    status=0
    t_run "
        check_root() { printf 'root\n' >> '$marks'; }
        require_tty_guard() { printf 'tty\n' >> '$marks'; }
        acquire_install_lock() { printf 'lock\n' >> '$marks'; exit 7; }
        install_main
    " </dev/null >/dev/null 2>&1 || status=$?
    t_assert_eq "$status" "7" "порядок проверяется остановкой на lock"
    t_assert_before "$marks" "root" "tty" "root-check обязан идти до TTY-guard"
    t_assert_before "$marks" "tty" "lock" "TTY-guard обязан идти до flock"
    return 0
}

test_non_tty_without_yes_is_rejected() {
    t_begin "no TTY without --yes is rejected"
    local out status=0
    out="$(t_run 'require_tty_guard' </dev/null 2>&1)" || status=$?
    t_assert_eq "$status" "2" "без TTY и --yes обязан быть exit 2"
    printf '%s' "$out" | grep -Fq 'sudo bash' || \
        t_fail "отказ обязан показать curl -o && sudo bash (вывод: $out)"
    printf '%s' "$out" | grep -Fq -- '--yes' || \
        t_fail "отказ обязан упомянуть --yes (вывод: $out)"
    t_run 'YES=1 require_tty_guard </dev/null' || t_fail "--yes обязан снимать TTY-guard"
    t_run 'CHECK_ONLY=1 require_tty_guard </dev/null' || \
        t_fail "--check не должен требовать TTY"
}

test_check_does_not_create_log_dir() {
    t_begin "--check does not create the log directory"
    t_stub_exit docker 1
    export CSQTT_INSTALL_LOG_FILE="$SANDBOX/missing-dir/deep/install.log"
    local out status=0
    out="$(t_run 'parse_cli --check --host 203.0.113.7 --yes; check_only_main' 2>&1)" || status=$?
    t_assert_eq "$status" "0" "--check обязан выйти 0"
    printf '%s' "$out" | grep -Fq 'CSQTT_INSTALL_CHECK_OK' || \
        t_fail "--check обязан напечатать маркер успеха (вывод: $out)"
    printf '%s' "$out" | grep -Fq '203.0.113.7' || \
        t_fail "--check обязан напечатать resolved host (вывод: $out)"
    [ -e "$SANDBOX/missing-dir" ] && \
        t_fail "--check не имеет права создавать каталог журнала"
    [ -e "$FAKE_CFG/install.json" ] && t_fail "--check не должен писать install.json"
    [ -e "$FAKE_CFG/csqtt.env" ] && t_fail "--check не должен создавать csqtt.env"
    return 0
}

test_prerequisites_add_openssl_and_ca_bundle() {
    t_begin "prerequisites add openssl and ca-certificates"
    local out=""
    out="$(t_run '
        command() {
            case "$1 $2" in
                "-v openssl"|"-v curl") return 1 ;;
            esac
            builtin command "$@"
        }
        ca_certificates_present() { return 1; }
        PKG_MGR=apt; OS_ID=debian
        install_prerequisites
    ' 2>&1)" || t_fail "install_prerequisites обязан пройти без пакетов (вывод: $out)"
    t_assert_contains "$CALL_LOG" "apt-get install" "пакеты обязаны ставиться через пакетный менеджер"
    t_assert_contains "$CALL_LOG" "openssl" "openssl обязан попасть в список пакетов"
    t_assert_contains "$CALL_LOG" "ca-certificates" "ca-certificates обязан попасть в список пакетов"
    t_assert_contains "$CALL_LOG" "curl" "curl обязан попасть в список пакетов"
    return 0
}

test_prerequisites_skip_installed_openssl() {
    t_begin "prerequisites do not reinstall present openssl"
    local out=""
    out="$(t_run '
        ca_certificates_present() { return 0; }
        PKG_MGR=apt; OS_ID=debian
        install_prerequisites
    ' 2>&1)" || t_fail "install_prerequisites обязан пройти (вывод: $out)"
    if [ -s "$CALL_LOG" ]; then
        grep -Fq "apt-get install" "$CALL_LOG" && \
            t_fail "при полном наборе зависимостей пакеты не ставятся (журнал: $(cat "$CALL_LOG"))"
    fi
    printf '%s' "$out" | grep -Fq 'уже установлены' || \
        t_fail "обязано быть сообщение, что зависимости уже стоят (вывод: $out)"
    return 0
}

test_check_reports_missing_packages_instead_of_failing() {
    t_begin "--check reports missing packages instead of failing"
    t_stub_exit docker 1
    local out status=0
    out="$(t_run '
        command() {
            case "$1 $2" in
                "-v iptables"|"-v sysctl"|"-v openssl") return 1 ;;
            esac
            builtin command "$@"
        }
        parse_cli --check --host 203.0.113.7 --yes
        check_only_main
    ' 2>&1)" || status=$?
    t_assert_eq "$status" "0" "--check обязан выйти 0 без iptables/sysctl/openssl"
    printf '%s' "$out" | grep -Fq 'CSQTT_INSTALL_CHECK_OK' || \
        t_fail "--check обязан напечатать маркер успеха (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'будут добавлены' || \
        t_fail "--check обязан перечислить пакеты, которые добавит установка (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'iptables' || \
        t_fail "в списке обязан быть iptables (вывод: $out)"
    return 0
}

test_check_still_rejects_foreign_architecture() {
    t_begin "--check rejects unsupported architecture"
    t_stub_exit docker 1
    t_stub_stdout uname 'aarch64'
    local out status=0
    out="$(t_run 'parse_cli --check --host 203.0.113.7 --yes; check_only_main' 2>&1)" || status=$?
    t_assert_eq "$status" "20" "чужая архитектура обязана дать preflight exit 20"
    printf '%s' "$out" | grep -Fq 'не поддерживается' || \
        t_fail "отказ обязан назвать архитектуру (вывод: $out)"
    return 0
}

test_certificate_without_openssl_is_not_user_managed() {
    t_begin "certificate is never classified as user-managed without openssl"
    t_seed_le_certificate ip 203.0.113.7
    t_run_fails '
        command() {
            case "$1 $2" in
                "-v openssl") return 1 ;;
            esac
            builtin command "$@"
        }
        web_certificate_is_user_managed
    ' "без openssl сертификат reCSQTT нельзя объявить пользовательским"
    return 0
}


test_web_probe_waits_for_slow_start() {
    t_begin "web probe waits for a slow-starting runtime"
    local counter="$SANDBOX/probe-counter"
    : > "$counter"
    local out status=0
    out="$(CSQTT_WEB_PROBE_SECONDS=30 t_run '
        WEB_PORT=46002
        probe_file_marker=0
        curl() {
            local n
            n=$(( $(cat "'"$counter"'" 2>/dev/null || echo 0) + 1 ))
            printf "%s" "$n" > "'"$counter"'"
            if [ "$n" -le 60 ]; then
                sleep 0.1
                return 7
            fi
            printf "200"
        }
        verify_web_panel
    ' 2>&1)" || status=$?
    t_assert_eq "$status" "0" "медленный старт в пределах дедлайна обязан дождаться панели"
    printf '%s' "$out" | grep -Fq 'health-проверке' || \
        t_fail "успех обязан быть залогирован (вывод: $out)"
    [ "$(cat "$counter")" -gt 48 ] || \
        t_fail "проба обязана пережить больше 24 итераций (вызовов: $(cat "$counter"))"
    return 0
}

test_web_probe_uses_installer_work_dir() {
    t_begin "web probe stays in the installer work dir"
    mkdir -p "$CSQTT_WORK_DIR"
    local host_tmp="${TMPDIR:-/tmp}" before after out
    before="$(find "$host_tmp" -maxdepth 1 -name 'csqtt-web-probe.*' 2>/dev/null | wc -l | tr -d ' ')"
    out="$(t_run 'WEB_PORT=46002; verify_web_panel' 2>&1)"
    t_assert_eq "$?" "0" "health-проба панели обязана пройти"
    printf '%s' "$out" | grep -Fq 'health-проверке' || \
        t_fail "проба обязана сообщить об успехе (вывод: $out)"
    after="$(find "$host_tmp" -maxdepth 1 -name 'csqtt-web-probe.*' 2>/dev/null | wc -l | tr -d ' ')"
    t_assert_eq "$after" "$before" "проба не должна оставлять файл в host TMPDIR"
    [ -z "$(find "$CSQTT_WORK_DIR" -maxdepth 1 -name 'csqtt-web-probe.*' 2>/dev/null)" ] || \
        t_fail "временный файл пробы обязан удаляться из work-dir"
    return 0
}

test_install_order_checksum_before_cleanup() {
    t_begin "checksum failure stops before cleanup"
    local base="https://github.com/w3struk/recsqtt" tag="v2.5.2" binary digest marks status=0 out
    binary='#!/usr/bin/env bash
printf "csqtt 2.5.2\n"'
    digest="$(printf '%s\n' "$binary" | sha256sum | awk '{print $1}')"
    : "$digest"
    t_http_fixture "$base/releases/download/$tag/recsqtt-linux-amd64" "$binary"
    t_http_fixture "$base/releases/download/$tag/SHA256SUMS" \
        "0000000000000000000000000000000000000000000000000000000000000000  recsqtt-linux-amd64"
    marks="$SANDBOX/order"
    t_install_stage_stubs "$SANDBOX/stages.sh" "$marks"
    out="$(t_run "
        VERSION_OVERRIDE='$tag'
        . '$SANDBOX/stages.sh'
        run_platform_preflight() { printf 'platform\n' >> '$marks'; }
        probe_nat_and_firewall() { printf 'nat_probe\n' >> '$marks'; }
        install_main
    " 2>&1)" || status=$?
    t_assert_eq "$status" "20" "битый checksum обязан дать preflight exit 20"
    printf '%s' "$out" | grep -Fq 'SHA-256' || \
        t_fail "отказ обязан назвать SHA-256 (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'CLEANUP_REACHED' && \
        t_fail "checksum-провал не должен доходить до csqtt_cleanup"
    [ -e "$marks" ] && grep -qx 'cleanup' "$marks" && \
        t_fail "csqtt_cleanup не должен вызываться до проверки checksum"
    return 0
}

test_same_version_without_force_is_noop() {
    t_begin "same version without --force is a no-op"
    t_stub_exit docker 1
    t_seed_install_state systemd domain panel.example.com 46000 443 22
    local marks="$SANDBOX/order" status=0 out
    t_install_stage_stubs "$SANDBOX/stages.sh" "$marks"
    out="$(t_run "
        . '$SANDBOX/stages.sh'
        FORCE=0
        install_main
    " 2>&1)" || status=$?
    t_assert_eq "$status" "0" "повтор той же версии без --force обязан выйти 0"
    printf '%s' "$out" | grep -Fq 'уже последняя версия' || \
        t_fail "no-op обязан объяснить, что версия уже последняя (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'CSQTT_INSTALL_ALREADY_CURRENT' || \
        t_fail "no-op обязан напечатать маркер (вывод: $out)"
    [ -e "$marks" ] && grep -qx 'cleanup' "$marks" && \
        t_fail "no-op не должен доходить до csqtt_cleanup"
    return 0
}

test_force_reinstalls_same_version() {
    t_begin "--force reinstalls the same version"
    t_stub_exit docker 1
    t_seed_install_state systemd domain panel.example.com 46000 443 22
    local marks="$SANDBOX/order" status=0 out
    t_install_stage_stubs "$SANDBOX/stages.sh" "$marks"
    out="$(t_run "
        . '$SANDBOX/stages.sh'
        prepare_candidate_release() { :; }
        run_platform_preflight() { :; }
        probe_nat_and_firewall() { :; }
        FORCE=1
        install_main
    " 2>&1)" || status=$?
    t_assert_eq "$status" "0" "--force обязан пройти установку той же версии"
    printf '%s' "$out" | grep -Fq 'CLEANUP_REACHED' || \
        t_fail "--force обязан дойти до csqtt_cleanup (вывод: $out)"
    t_assert_before "$marks" "snapshot" "cleanup" "--force обязан пройти через snapshot"
    return 0
}

test_reconfigure_bypasses_same_version_noop() {
    t_begin "reconfiguration bypasses the same-version no-op"
    t_stub_exit docker 1
    t_seed_install_state systemd domain panel.example.com 46000 443 22
    local marks="$SANDBOX/order" status=0 out
    t_install_stage_stubs "$SANDBOX/stages.sh" "$marks"
    out="$(t_run "
        . '$SANDBOX/stages.sh'
        prepare_candidate_release() { :; }
        run_platform_preflight() { :; }
        probe_nat_and_firewall() { :; }
        FORCE=0
        RECONFIGURE=1
        install_main
    " 2>&1)" || status=$?
    t_assert_eq "$status" "0" "reconfiguration обязан пройти установку"
    printf '%s' "$out" | grep -Fq 'CLEANUP_REACHED' || \
        t_fail "reconfiguration не должен уходить в ALREADY_CURRENT (вывод: $out)"
    if printf '%s' "$out" | grep -Fq 'CSQTT_INSTALL_ALREADY_CURRENT'; then
        t_fail "reconfiguration не должен печатать ALREADY_CURRENT"
    fi
    t_assert_before "$marks" "snapshot" "cleanup" "reconfiguration обязан пройти через snapshot"
    return 0
}

test_release_verified_before_cleanup() {
    t_begin "release is verified before cleanup"
    local base="https://github.com/w3struk/recsqtt" tag="v2.5.2" binary digest marks status=0 out
    binary='#!/usr/bin/env bash
printf "csqtt 2.5.2\n"'
    digest="$(printf '%s\n' "$binary" | sha256sum | awk '{print $1}')"
    t_http_fixture "$base/releases/download/$tag/recsqtt-linux-amd64" "$binary"
    t_http_fixture "$base/releases/download/$tag/SHA256SUMS" "$digest  recsqtt-linux-amd64"
    marks="$SANDBOX/order"
    t_install_stage_stubs "$SANDBOX/stages.sh" "$marks"
    out="$(t_run "
        VERSION_OVERRIDE='$tag'
        . '$SANDBOX/stages.sh'
        run_platform_preflight() { printf 'platform\n' >> '$marks'; }
        probe_nat_and_firewall() { printf 'nat_probe\n' >> '$marks'; }
        install_main
    " 2>&1)" || status=$?
    t_assert_eq "$status" "0" "проверенный релиз обязан дойти до конца"
    printf '%s' "$out" | grep -Fq 'скачан и проверен по SHA-256' || \
        t_fail "нужен явный маркер проверки кандидата (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'CLEANUP_REACHED' || \
        t_fail "после успешной проверки установка обязана дойти до cleanup (вывод: $out)"
    t_assert_before "$marks" "snapshot" "cleanup" "snapshot обязан идти до cleanup"
    [ -x "$CSQTT_WORK_DIR/recsqtt-linux-amd64" ] || \
        t_fail "проверенный CANDIDATE_BINARY обязан оставаться в work-dir"
    return 0
}

test_install_probes_tun_and_nat_before_cutover() {
    t_begin "TUN and NAT probes run before cutover"
    local marks="$SANDBOX/order" status=0 out
    t_install_stage_stubs "$SANDBOX/stages.sh" "$marks"
    out="$(t_run "
        . '$SANDBOX/stages.sh'
        prepare_candidate_release() { printf 'candidate\n' >> '$marks'; }
        check_kernel_compatibility() { printf 'kernel\n' >> '$marks'; }
        probe_tun_support() { printf 'tun\n' >> '$marks'; }
        detect_firewall() { printf 'firewall\n' >> '$marks'; }
        detect_wan_interface() { printf 'eth0\n'; }
        install_main
    " 2>&1)" || status=$?
    t_assert_eq "$status" "0" "пробы обязаны пройти до cutover"
    t_assert_before "$marks" "kernel" "snapshot" "kernel preflight обязан идти до snapshot"
    t_assert_before "$marks" "tun" "snapshot" "TUN-проба обязана идти до snapshot/cutover"
    t_assert_before "$marks" "firewall" "snapshot" "NAT-проба обязана идти до snapshot/cutover"
    t_assert_before "$marks" "firewall" "cleanup" "NAT-проба обязана идти до csqtt_cleanup"
    printf '%s' "$out" | grep -Fq 'NAT/firewall проверены' || \
        t_fail "NAT-проба обязана подтвердить nat (вывод: $out)"
    return 0
}

test_activation_paths_are_direct() {
    t_begin "activation installs the candidate directly"
    printf '#!/bin/sh\nprintf "candidate\\n"\n' > "$SANDBOX/candidate"
    chmod 0755 "$SANDBOX/candidate"
    t_run 'CANDIDATE_BINARY="$SANDBOX/candidate"; setup_csqtt_binary'
    t_assert_eq "$?" "0" "setup_csqtt_binary обязан установить кандидата"
    [ -f "$CSQTT_BIN_DIR/csqtt" ] || t_fail "бинарник обязан лежать в CSQTT_BIN_DIR"
    t_assert_eq "$(stat -c '%a' "$CSQTT_BIN_DIR/csqtt")" "755" "бинарник обязан быть 0755"
    t_assert_contains "$CSQTT_BIN_DIR/csqtt" "candidate" "установлен именно кандидат"
    t_assert_contains "$DEPLOY_SCRIPT" \
        'install -m 0755 "$CANDIDATE_BINARY" "${CSQTT_BIN_DIR}/csqtt"' \
        "активация обязана ставить кандидата напрямую"
    t_assert_not_contains "$DEPLOY_SCRIPT" 'UPLOAD_' "upload-путь обязан исчезнуть"
    t_assert_not_contains "$DEPLOY_SCRIPT" '/tmp/.csqtt-upload' \
        "staged upload-кандидата быть не должно"
    t_assert_not_contains "$CALL_LOG" "csqtt-cascade" \
        "активация не должна трогать легаси-каскад"
    t_assert_not_contains "$CALL_LOG" "hev-socks5" \
        "активация не должна трогать легаси hev-socks5"
}

test_cleanup_preserves_db_wal_and_migration_backup() {
    t_begin "cleanup preserves db, wal, shm and migration backups"
    t_require_sandbox_runtime_paths
    printf 'db\n' > "$FAKE_CFG/csqtt.db"
    printf 'wal\n' > "$FAKE_CFG/csqtt.db-wal"
    printf 'shm\n' > "$FAKE_CFG/csqtt.db-shm"
    printf 'mig\n' > "$FAKE_CFG/csqtt.db.pre-owner-migration"
    printf 'mig-wal\n' > "$FAKE_CFG/csqtt.db.pre-owner-migration-wal"
    printf 'mig-shm\n' > "$FAKE_CFG/csqtt.db.pre-owner-migration-shm"
    printf 'json\n' > "$FAKE_CFG/passwords.json"
    printf 'json-imported\n' > "$FAKE_CFG/passwords.json.imported"
    printf 'IP=203.0.113.7\n' > "$FAKE_CFG/letsencrypt-ip.env"
    printf 'stray\n' > "$FAKE_CFG/stray.txt"
    t_run 'clear_runtime_config_preserving_database'
    t_assert_eq "$?" "0" "очистка runtime-конфига обязана пройти"
    local file
    for file in csqtt.db csqtt.db-wal csqtt.db-shm \
                csqtt.db.pre-owner-migration csqtt.db.pre-owner-migration-wal \
                csqtt.db.pre-owner-migration-shm passwords.json \
                passwords.json.imported letsencrypt-ip.env; do
        [ -f "$FAKE_CFG/$file" ] || t_fail "whitelist обязан сохранить $file"
    done
    [ -e "$FAKE_CFG/stray.txt" ] && t_fail "не-whitelist файл обязан быть удалён"
    return 0
}

test_flock_rejects_second_instance() {
    t_begin "flock rejects a second instance"
    mkdir -p "$(dirname "$CSQTT_INSTALL_LOCK")"
    : > "$CSQTT_INSTALL_LOCK"
    exec 7>"$CSQTT_INSTALL_LOCK"
    flock -n 7 || t_fail "тест не смог взять lock для имитации первого экземпляра"
    t_run_fails 'acquire_install_lock' 'Другой экземпляр' \
        "второй экземпляр обязан быть отклонён" 2
    exec 7>&-
    t_run 'acquire_install_lock' || t_fail "после освобождения lock обязан взяться"
    return 0
}

test_web_pass_stdin_does_not_eat_piped_script() {
    t_begin "--web-pass-stdin does not read the piped script body"
    printf 'BODY_PASSWORD\n' > "$SANDBOX/piped-body"
    local out status=0
    out="$(CSQTT_TTY_PATH="$SANDBOX/no-tty" \
        t_run 'WEB_PASS_STDIN=1; read_web_password_if_requested' \
        < "$SANDBOX/piped-body" 2>&1)" || status=$?
    t_assert_eq "$status" "2" "без TTY пароль обязан быть отклонён, а не прочитан из тела"
    printf '%s' "$out" | grep -Fq -- '--web-pass-stdin' || \
        t_fail "отказ обязан назвать флаг и инструкцию (вывод: $out)"
    printf '%s' "$out" | grep -Fq 'BODY_PASSWORD' && \
        t_fail "тело piped-скрипта не должно приниматься за пароль"
    return 0
}

TESTS=(
    test_smoke_source_does_not_run_main
    test_smoke_stub_captures_argv
    test_runner_refuses_root
    test_install_architecture_aliases
    test_install_rejects_unsupported_architectures
    test_symlinked_config_dir_keeps_link_and_data
    test_dangling_config_symlink_fails_without_deleting
    test_non_directory_config_path_fails_without_deleting
    test_missing_config_dir_is_created
    test_helper_dir_still_gets_recreated
    test_public_ip_selects_ip_mode
    test_domain_selects_domain_mode_on_443
    test_domain_overrides_client_web_port
    test_garbage_web_port_with_domain_still_resolves_to_443
    test_host_is_lowercased
    test_blank_host_fails_before_parsing
    test_private_ipv4_is_rejected
    test_non_address_and_non_domain_is_rejected
    test_quoted_host_value_is_accepted
    test_escaped_host_value_is_accepted
    test_hostname_validator_vectors
    test_domain_mode_removes_46002_rule
    test_ip_mode_removes_443_rule
    test_current_port_rule_is_still_added
    test_removal_stops_on_success
    test_removal_terminates_without_the_rule
    test_cleanup_removes_unmarked_legacy_mss_rules
    test_cleanup_tolerates_missing_legacy_mss_rules
    test_network_helper_closes_the_unused_port
    test_network_helper_keeps_the_reverse_switch
    test_domain_issuance_asks_certbot_for_a_dns_name_only
    test_ip_issuance_is_unchanged
    test_domain_mode_never_falls_back_to_self_signed
    test_ip_mode_still_falls_back_to_self_signed
    test_activation_failure_is_fatal_in_domain_mode
    test_missing_certbot_client_is_fatal_in_domain_mode
    test_occupied_port_80_fails_in_domain_mode
    test_identifier_comes_from_panel_host
    test_certificate_name_and_state_follow_the_mode
    test_ip_certificate_name_keeps_the_dash_form
    test_domain_certificate_is_recognised_as_current
    test_user_supplied_certificate_is_left_alone_in_both_modes
    test_adopt_recovers_a_domain_certificate_after_state_loss
    test_supported_install_does_not_create_legacy_files
    test_cutover_stops_the_renewal_timer
    test_domain_install_does_not_adopt_an_ip_certificate
    test_domain_preflight_dies_before_the_runtime_is_stopped
    test_renewal_helper_renews_the_domain_without_the_short_lived_profile
    test_renewal_helper_never_self_signs_in_domain_mode
    test_renewal_helper_self_signs_in_ip_mode
    test_renewal_helper_exits_when_state_is_missing_in_domain_mode
    test_renewal_helper_renews_on_identifier_mismatch
    test_renewal_helper_exits_quietly_without_identifier
    test_docker_run_grants_net_bind_service
    test_docker_run_passes_unquoted_env
    test_docker_rollback_uses_previous_image
    test_occupied_web_port_fails_before_panel_starts
    test_free_web_port_passes
    test_banners_report_the_effective_port
    test_cli_dir_is_outside_runtime_lib
    test_relative_runtime_path_is_rejected
    test_empty_runtime_override_is_rejected
    test_cleanup_uses_overridden_runtime_paths
    test_sysctl_and_grub_stay_in_sandbox
    test_uninstall_preserves_state_unless_purge
    test_install_state_survives_runtime_cleanup
    test_pre_owner_migration_backup_survives_cleanup
    test_install_state_roundtrip
    test_snapshot_keeps_helpers_and_db
    test_snapshot_keeps_pre_owner_migration_backup
    test_archive_keeps_last_three
    test_failure_after_cutover_rolls_back
    test_rollback_restores_previous_helper
    test_rollback_restores_nat_rules
    test_rollback_skips_nft_when_iptables_restore_succeeds
    test_rollback_uses_nft_only_as_fallback
    test_rollback_starts_letsencrypt_timer
    test_sigterm_after_arming_rolls_back
    test_sigterm_during_snapshot_restarts_runtime
    test_rollback_failure_emits_marker
    test_snapshot_stops_runtime_before_copy
    test_snapshot_failure_restarts_stopped_runtime
    test_cli_parses_host_and_mode
    test_cli_rejects_unknown_flag
    test_cli_docker_alias
    test_cli_mode_is_tristate
    test_cli_check_does_not_require_yes
    test_check_uninstall_is_rejected
    test_check_status_is_rejected
    test_cli_subcommands_dispatch
    test_cli_rejects_removed_password_flags
    test_checksum_mismatch_is_fatal
    test_binary_without_checksum_is_rejected
    test_binary_with_explicit_checksum_is_accepted
    test_release_redirect_resolves_tag
    test_prepare_installer_source_downloads_and_verifies
    test_prepare_installer_source_rejects_bad_checksum
    test_reexec_guard_prevents_loop
    test_reexec_releases_install_lock
    test_reexec_forwards_install_flags
    test_reexec_forwards_reconfigure_and_force
    test_install_cli_uses_downloaded_script_not_stdin
    test_install_cli_refuses_without_downloaded_source
    test_credentials_prints_panel_url_without_tunnel_password
    test_credentials_prints_secret_path_url
    test_logs_prints_install_journal
    test_cli_survives_cleanup_path
    test_uninstall_removes_cli_not_state
    test_uninstall_takes_install_lock
    test_update_replaces_cli_atomically
    test_binary_version_does_not_reexec
    test_fresh_install_generates_random_panel_identity
    test_fresh_install_accepts_explicit_web_credentials
    test_update_preserves_env_verbatim
    test_update_preserves_panel_identity
    test_panel_identity_validation_rejects_bad_values
    test_interactive_panel_customization_defaults_to_generated
    test_interactive_mode_prompt_reasks_on_invalid_input
    test_interactive_port_prompt_reasks_on_invalid_input
    test_interactive_domain_answer_selects_domain_mode
    test_interactive_domain_choice_accepts_domain_with_matching_a_record
    test_interactive_domain_choice_falls_back_to_ip_on_mismatch
    test_interactive_no_domain_choice_goes_straight_to_ip
    test_interactive_default_enter_falls_back_to_ip
    test_update_interactive_can_switch_to_domain
    test_update_interactive_keeps_address_by_default
    test_conflicting_port_without_reconfigure_fails
    test_reconfigure_without_mode_preserves_docker
    test_failed_install_does_not_change_install_json
    test_install_configuration_uses_install_json_not_unit
    test_install_configuration_ignores_unit_with_foreign_config_dir
    test_check_without_panel_host_reports_and_install_requires_host
    test_non_root_rejected_before_tty_guard
    test_non_tty_without_yes_is_rejected
    test_check_does_not_create_log_dir
    test_prerequisites_add_openssl_and_ca_bundle
    test_prerequisites_skip_installed_openssl
    test_check_reports_missing_packages_instead_of_failing
    test_check_still_rejects_foreign_architecture
    test_certificate_without_openssl_is_not_user_managed
    test_web_probe_uses_installer_work_dir
    test_web_probe_waits_for_slow_start
    test_same_version_without_force_is_noop
    test_force_reinstalls_same_version
    test_reconfigure_bypasses_same_version_noop
    test_install_order_checksum_before_cleanup
    test_install_probes_tun_and_nat_before_cutover
    test_activation_paths_are_direct
    test_cleanup_preserves_db_wal_and_migration_backup
    test_release_verified_before_cleanup
    test_flock_rejects_second_instance
    test_web_pass_stdin_does_not_eat_piped_script
)

# ---------------------------------------------------------------------------
# Запуск
# ---------------------------------------------------------------------------

main() {
    local selected=() argument test_name matched
    if [ "$#" -eq 0 ]; then
        selected=("${TESTS[@]}")
    else
        for argument in "$@"; do
            matched=0
            for test_name in "${TESTS[@]}"; do
                if [ "$test_name" = "$argument" ]; then
                    selected+=("$argument")
                    matched=1
                    break
                fi
            done
            [ "$matched" -eq 1 ] && continue
            # Фильтр по префиксу: `deploy_shell_tests.sh test_cli_` гоняет всю группу.
            for test_name in "${TESTS[@]}"; do
                case "$test_name" in
                    "$argument"*) selected+=("$test_name"); matched=1 ;;
                esac
            done
            if [ "$matched" -eq 0 ]; then
                printf 'неизвестный тест: %s\n' "$argument" >&2
                return 1
            fi
        done
    fi
    printf 'reCSQTT install.sh behavioural tests\n'
    printf 'install.sh: %s\n' "$DEPLOY_SCRIPT"
    for test_name in "${selected[@]}"; do
        printf '\n▶ %s\n' "$test_name"
        if ( set +e; "$test_name" ); then
            printf '  ✓ ok\n'
            PASSED=$((PASSED + 1))
        else
            printf '  ✗ FAILED\n' >&2
            FAILED=$((FAILED + 1))
            FAILED_NAMES+=("$test_name")
        fi
    done
    printf '\nитого: %s зелёных, %s красных\n' "$PASSED" "$FAILED"
    if [ "$FAILED" -ne 0 ]; then
        printf 'красные: %s\n' "${FAILED_NAMES[*]}" >&2
        return 1
    fi
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
