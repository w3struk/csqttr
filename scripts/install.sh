#!/bin/bash

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export TERM="${TERM:-xterm}"

readonly SCRIPT_VERSION="2.5.2"
# Журнал установки. Отдельная константа, потому что читающие подкоманды
# (logs/status/credentials/panel) обязаны видеть настоящий путь, а писать в
# журнал им нельзя: main перенаправляет их LOG_FILE в /dev/null.
readonly INSTALL_LOG_FILE="${CSQTT_INSTALL_LOG_FILE:-/var/log/csqtt-install.log}"
# Не readonly: --check не имеет права создавать каталог журнала, поэтому
# check_only_main перенаправляет журнал в /dev/null до первой записи.
LOG_FILE="$INSTALL_LOG_FILE"
PEER_PORT="${CSQTT_PEER_PORT:-46000}"
SSH_PORT="${CSQTT_SSH_PORT:-22}"
WEB_PORT="${CSQTT_WEB_PORT:-46002}"
readonly LE_HTTP_PORT="80"
LE_RENEW_BEFORE_SECONDS="259200"
DEPLOY_MODE="${CSQTT_DEPLOY_MODE:-systemd}"
readonly CSQTT_IFACE="csqtt1"
# Все runtime-пути переопределяемы окружением: shell-тесты подставляют корни
# внутри песочницы, production-дефолты остаются прежними. Любая запись/удаление
# обязана идти через эти переменные, иначе тест снова начнёт трогать host.
# Именно `-`, а не `:-`: явно пустое значение (CSQTT_BIN_DIR=) не должно
# молча подменяться дефолтом, иначе validate_runtime_paths его не увидит.
readonly CSQTT_CONFIG_DIR="${CSQTT_CONFIG_DIR-/etc/csqtt}"
readonly CSQTT_LE_ROOT="${CSQTT_LE_ROOT-/etc/letsencrypt}"
readonly CSQTT_BIN_DIR="${CSQTT_BIN_DIR-/usr/local/bin}"
readonly CSQTT_LIB_DIR="${CSQTT_LIB_DIR-/usr/local/lib/csqtt}"
readonly CSQTT_CLI_DIR="${CSQTT_CLI_DIR-/usr/local/lib/csqtt-installer}"
readonly CSQTT_SYSTEMD_DIR="${CSQTT_SYSTEMD_DIR-/etc/systemd/system}"
readonly CSQTT_RUN_DIR="${CSQTT_RUN_DIR-/run/csqtt}"
readonly CSQTT_INSTALL_LOCK="${CSQTT_INSTALL_LOCK-/run/csqtt-install.lock}"
readonly CSQTT_SYSCTL_DIR="${CSQTT_SYSCTL_DIR-/etc/sysctl.d}"
readonly CSQTT_MODULES_LOAD_DIR="${CSQTT_MODULES_LOAD_DIR-/etc/modules-load.d}"
readonly CSQTT_PROC_SYS_DIR="${CSQTT_PROC_SYS_DIR-/proc/sys}"
readonly CSQTT_GRUB_FILE="${CSQTT_GRUB_FILE-/etc/default/grub}"
readonly CSQTT_CRON_DIR="${CSQTT_CRON_DIR-/etc/cron.d}"
readonly CSQTT_OPT_DIR="${CSQTT_OPT_DIR-/opt/csqtt-certbot}"
readonly CSQTT_VAR_DIR="${CSQTT_VAR_DIR-/var/lib/csqtt}"
readonly CSQTT_LE_CERTBOT="${CSQTT_LE_CERTBOT-${CSQTT_OPT_DIR}/bin/certbot}"
readonly CSQTT_LE_VENV="${CSQTT_LE_VENV-${CSQTT_OPT_DIR}}"
readonly CSQTT_LE_STATE_FILE="${CSQTT_LE_STATE_FILE-${CSQTT_CONFIG_DIR}/letsencrypt.env}"
readonly CSQTT_LE_RENEW_HELPER="${CSQTT_LE_RENEW_HELPER-/usr/local/lib/csqtt-letsencrypt-renew.sh}"
readonly CSQTT_LE_SERVICE="csqtt-letsencrypt.service"
readonly CSQTT_LE_TIMER="csqtt-letsencrypt.timer"
readonly CSQTT_DATABASE_FILE="csqtt.db"
readonly CSQTT_DATABASE_WAL_FILE="csqtt.db-wal"
readonly CSQTT_DATABASE_SHM_FILE="csqtt.db-shm"
readonly CSQTT_ENV_FILE="${CSQTT_CONFIG_DIR}/csqtt.env"
readonly CSQTT_INSTALL_STATE_FILE="${CSQTT_INSTALL_STATE_FILE-${CSQTT_CONFIG_DIR}/install.json}"
readonly CSQTT_RUNTIME_ARCHIVE_DIR="${CSQTT_CONFIG_DIR}/runtime-archive"
# Кандидат живёт в work-dir установщика, а не в общем /tmp: тело piped-скрипта,
# stdin и upload-путь старого app-деплоя больше не участвуют.
CANDIDATE_BINARY=""
CANDIDATE_ENV_FILE=""
readonly CSQTT_SYSCTL_FILE="${CSQTT_SYSCTL_FILE-${CSQTT_SYSCTL_DIR}/99-csqtt.conf}"
readonly CSQTT_UDP_SYSCTL_FILE="${CSQTT_UDP_SYSCTL_FILE-${CSQTT_SYSCTL_DIR}/99-csqtt-udp-buffers.conf}"
readonly IPT_COMMENT="CSQTT_MANAGED"
readonly CSQTT_DOCKER_IMAGE="csqtt:2.5.2"
readonly CSQTT_DOCKER_CONTAINER="csqtt"
readonly CSQTT_DOCKER_PREREQ_SERVICE="csqtt-docker-prereq.service"
readonly CSQTT_DOCKER_PREREQ_HELPER="${CSQTT_DOCKER_PREREQ_HELPER-${CSQTT_LIB_DIR}/docker-prereq.sh}"
readonly CSQTT_RUNTIME_DIR="${CSQTT_RUNTIME_DIR-${CSQTT_RUN_DIR}}"
readonly CSQTT_DOCKER_NETWORK_READY="${CSQTT_RUNTIME_DIR}/docker-network.ready"
readonly XT_WAIT="${CSQTT_XT_WAIT:-2}"
readonly START_STABILITY_SECONDS="${CSQTT_START_STABILITY_SECONDS:-4}"
readonly DOCKER_BUILD_TIMEOUT_SECONDS="${CSQTT_DOCKER_BUILD_TIMEOUT_SECONDS:-180}"
readonly EXIT_INVALID_ARGUMENT=2
readonly EXIT_PREFLIGHT_FAILED=20
readonly EXIT_CUTOVER_FAILED=30

# Число совпадает с production-дефолтом lock-файла; при re-exec дескриптор
# обязан быть закрыт, иначе новый процесс унаследует lock и упрётся в себя.
readonly CSQTT_INSTALL_LOCK_FD=9
readonly CSQTT_RELEASE_BASE="https://github.com/w3struk/csqttr"
# Временный каталог загрузки. Пусто — создать mktemp -d; тесты подставляют свой.
CSQTT_WORK_DIR="${CSQTT_WORK_DIR:-}"
CSQTT_WORK_DIR_OWNED="${CSQTT_WORK_DIR_OWNED:-0}"
CSQTT_INSTALLER_SOURCE=""
RELEASE_TAG=""
# argv, с которым установщик запущен. main сохраняет его до parse_cli, чтобы
# re-exec на другую версию не терял флаги и интерактивные ответы.
INSTALLER_ARGV=()

SYSTEMD_NEEDS_RELOAD=0
DEPLOY_PHASE="initial"
# Состояние отката. ROLLBACK_ARMED выставляется после успешного snapshot и до
# csqtt_cleanup. Между остановкой runtime в snapshot и arming стоит
# RUNTIME_STOPPED=1: ошибка или сигнал в этом окне обязаны вернуть прежний
# runtime, а не оставить сервер выключенным.
ROLLBACK_ARMED=0
RUNTIME_STOPPED=0
IN_ROLLBACK=0
# Снимок, из которого rollback_runtime восстанавливает runtime.
RUNTIME_SNAPSHOT_DIR=""
RUNTIME_SNAPSHOT_MODE=""
# Был ли до cutover старый бинарник — без него откатывать нечего.
RUNTIME_SNAPSHOT_HAS_PREVIOUS=0
# Что именно было остановлено в snapshot_runtime: юниты и контейнеры.
RUNTIME_STOPPED_UNITS=""
RUNTIME_STOPPED_CONTAINERS=""
# Прежний Docker-образ: кандидат не тегируется как основной до health-check,
# поэтому старый tag/ID остаётся нетронутым до успеха.
DOCKER_PREVIOUS_IMAGE_ID=""
DOCKER_PREVIOUS_IMAGE_TAG=""
# Из какого образа запускать контейнер: кандидат до health-check, затем main.
CSQTT_DOCKER_RUN_IMAGE=""
DOCKER_CONTEXT_DIR=""
CSQTT_DOCKER_CANDIDATE_IMAGE=""
DOCKER_ENV_ARGS=()
# Заполняются resolve_panel_mode()/resolve_install_configuration() в начале
# install: ip|domain, хост панели.
PANEL_MODE=""
PANEL_HOST=""
# Результат resolve_install_configuration: fresh|systemd|docker по install.json.
INSTALL_KIND="fresh"
ADOPTION_PERFORMED=0
ADOPTION_AMBIGUOUS=0
# Переписывать ли csqtt.env. Update без явных изменений сохраняет файл
# байт-в-байт, поэтому build_csqtt_env в этом случае не вызывается.
CSQTT_ENV_REWRITE=0
CSQTT_ENV_BACKUP=""
# Web-доступы. Пароль не хранится в argv: --web-pass-stdin читает его отдельно,
# иначе build_csqtt_env генерирует значение. Дефолтов «admin» и пустого secret
# path нет: fresh-установка получает случайную тройку, update/adoption —
# сохраняет существующую из csqtt.env байт-в-байт.
WEB_PASS="${CSQTT_WEB_PASS:-}"
WEB_USER="${CSQTT_WEB_USER:-}"
SECRET_PATH="${CSQTT_WEB_SECRET_PATH:-}"
WEB_USER_EXPLICIT=0
SECRET_PATH_EXPLICIT=0
WEB_PASS_EXPLICIT=0
# 1 — существующая установка: значения читаются из csqtt.env без ротации.
# 0 — fresh: отсутствующие значения генерируются.
PANEL_IDENTITY_PRESERVE=0

validate_port() {
    local name="$1" value="$2"
    case "$value" in
        ''|*[!0-9]*) die "$name должен быть числом от 1 до 65535, получено: $value" ;;
    esac
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        die "$name должен быть в диапазоне 1..65535, получено: $value"
    fi
}

validate_positive_seconds() {
    local name="$1" value="$2"
    case "$value" in
        ''|*[!0-9]*) die "$name должен быть положительным числом секунд, получено: $value" ;;
    esac
    if [ "$value" -lt 1 ] || [ "$value" -gt 900 ]; then
        die "$name должен быть в диапазоне 1..900, получено: $value"
    fi
}

validate_distinct_network_ports() {
    [ "$PEER_PORT" != "$SSH_PORT" ] || die "CSQTT_PEER_PORT не может совпадать с SSH-портом"
    [ "$PEER_PORT" != "$WEB_PORT" ] || die "CSQTT_PEER_PORT не может совпадать с WEB-портом"
    [ "$PEER_PORT" != "$LE_HTTP_PORT" ] || die "CSQTT_PEER_PORT не может совпадать с HTTP-портом"
    [ "$WEB_PORT" != "$SSH_PORT" ] || die "CSQTT_WEB_PORT не может совпадать с SSH-портом"
}

# Путь обязан быть абсолютным и не равен корню: иначе rm -rf по нему уничтожит
# систему, а не runtime CSQTT. Ошибка — всегда exit 2 (ошибка аргументов).
validate_runtime_path() {
    local name="$1" value="$2"
    case "$value" in
        '') die "$name не может быть пустым" "$EXIT_INVALID_ARGUMENT" ;;
        /*) ;;
        *) die "$name должен быть абсолютным путём, получено: $value" "$EXIT_INVALID_ARGUMENT" ;;
    esac
    [ "$value" != "/" ] || die "$name не может быть корнем /" "$EXIT_INVALID_ARGUMENT"
}

validate_runtime_paths() {
    local name value
    for name in \
        CSQTT_BIN_DIR CSQTT_LIB_DIR CSQTT_CLI_DIR \
        CSQTT_SYSTEMD_DIR CSQTT_RUN_DIR CSQTT_INSTALL_LOCK \
        CSQTT_SYSCTL_DIR CSQTT_MODULES_LOAD_DIR CSQTT_PROC_SYS_DIR \
        CSQTT_GRUB_FILE CSQTT_CRON_DIR CSQTT_OPT_DIR CSQTT_VAR_DIR \
        CSQTT_LE_RENEW_HELPER \
        CSQTT_CONFIG_DIR CSQTT_LE_ROOT CSQTT_LE_CERTBOT CSQTT_LE_VENV \
        CSQTT_SYSCTL_FILE CSQTT_UDP_SYSCTL_FILE CSQTT_RUNTIME_DIR \
        CSQTT_DOCKER_PREREQ_HELPER CSQTT_DOCKER_NETWORK_READY \
        CSQTT_INSTALL_STATE_FILE; do
        value="${!name}"
        validate_runtime_path "$name" "$value"
    done
}

C_GREEN=''; C_YELLOW=''; C_RED=''
C_CYAN='';  C_BOLD='';      C_NC=''

log_info()  { echo -e "${C_GREEN}[✓]${C_NC} $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${C_YELLOW}[!]${C_NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${C_RED}[✗]${C_NC} $*" | tee -a "$LOG_FILE"; }
log_step()  { echo -e "${C_CYAN}[►]${C_NC} ${C_BOLD}$*${C_NC}" | tee -a "$LOG_FILE"; }

# Журнал установки содержит пути и служебные сообщения, поэтому создаётся
# сразу с 0600. Существующий журнал не обнуляем — только ужесточаем права.
prepare_install_log() {
    mkdir -p "$(dirname "$LOG_FILE")" || die "Не удалось подготовить каталог журнала: $(dirname "$LOG_FILE")"
    if [ -e "$LOG_FILE" ]; then
        chmod 0600 "$LOG_FILE" 2>/dev/null || true
    else
        install -m 0600 /dev/null "$LOG_FILE" || \
            die "Не удалось создать журнал установки: $LOG_FILE"
    fi
}

default_exit_code() {
    case "$DEPLOY_PHASE" in
        validation) printf '%s' "$EXIT_INVALID_ARGUMENT" ;;
        preflight) printf '%s' "$EXIT_PREFLIGHT_FAILED" ;;
        cutover|activation) printf '%s' "$EXIT_CUTOVER_FAILED" ;;
        *) printf '%s' 1 ;;
    esac
}

die() {
    local message="$1" code="${2:-$(default_exit_code)}"
    log_error "$message"
    printf 'CSQTT_DEPLOY_ERROR|%s|%s\n' "$DEPLOY_PHASE" "$message"
    # После snapshot ошибка не имеет права молча продолжить: откат обязан
    # сработать или явно провалиться. До arming откатывать нечего — runtime уже
    # остановлен snapshot'ом, поэтому его нужно просто вернуть.
    if [ "${ROLLBACK_ARMED:-0}" = "1" ]; then
        rollback_runtime "$message"
    fi
    if [ "${RUNTIME_STOPPED:-0}" = "1" ]; then
        if ! restart_stopped_runtime; then
            log_error "Не удалось перезапустить прежний runtime после ошибки"
            printf 'CSQTT_DEPLOY_ROLLBACK_FAILED|%s|restart after stop failed\n' "$DEPLOY_PHASE"
            cleanup_deploy_artifacts
            exit 31
        fi
    fi
    cleanup_deploy_artifacts
    exit "$code"
}

# Полный откат. Вызывается только из die/обработчика сигналов/ERR-trap, никогда
# из своего же кода: IN_ROLLBACK и trap - ERR отсекают рекурсию. die здесь не
# используется — ошибка отката обязана дать маркер и exit 31, а не уйти в
# повторный rollback.
rollback_runtime() {
    local reason="${1:-unspecified}"
    if [ "${IN_ROLLBACK:-0}" = "1" ]; then
        log_error "Повторный вход в откат: $reason"
        exit 31
    fi
    IN_ROLLBACK=1
    ROLLBACK_ARMED=0
    trap - ERR
    # Откат состоит из множества шагов, каждый из которых может не сработать;
    # решение о провале принимает сам откат, а не errexit.
    set +e
    trap '' INT TERM

    log_error "Установка не удалась ($reason); восстановление предыдущего runtime..."
    if perform_rollback; then
        ROLLBACK_ARMED=0
        RUNTIME_STOPPED=0
        CSQTT_DOCKER_RUN_IMAGE=""
        cleanup_deploy_artifacts
        printf 'CSQTT_DEPLOY_ROLLED_BACK|%s|%s\n' "$DEPLOY_PHASE" "$reason"
        log_info "Предыдущий runtime CSQTT восстановлен"
        exit 30
    fi
    cleanup_deploy_artifacts
    printf 'CSQTT_DEPLOY_ROLLBACK_FAILED|%s|%s\n' "$DEPLOY_PHASE" "$reason"
    log_error "Откат не удался: предыдущий runtime восстановлен не полностью"
    exit 31
}

# Возврат уже остановленного, но ещё не изменённого runtime. Используется в
# окне между остановкой в snapshot_runtime и ROLLBACK_ARMED=1.
restart_stopped_runtime() {
    [ "${RUNTIME_STOPPED:-0}" = "1" ] || return 0
    local unit
    log_warn "Возврат ранее остановленного runtime CSQTT (файлы не изменялись)"
    case "${RUNTIME_SNAPSHOT_MODE:-}" in
        docker)
            command -v docker >/dev/null 2>&1 || { RUNTIME_STOPPED=0; return 0; }
            while IFS= read -r unit; do
                [ -n "$unit" ] || continue
                docker update --restart unless-stopped "$unit" >/dev/null 2>&1 || true
                docker start "$unit" >/dev/null 2>&1 || return 1
            done <<< "$RUNTIME_STOPPED_CONTAINERS"
            RUNTIME_STOPPED=0
            return 0
            ;;
        systemd)
            command -v systemctl >/dev/null 2>&1 || { RUNTIME_STOPPED=0; return 0; }
            while IFS= read -r unit; do
                [ -n "$unit" ] || continue
                systemctl start "$unit" >/dev/null 2>&1 || return 1
            done <<< "$RUNTIME_STOPPED_UNITS"
            RUNTIME_STOPPED=0
            return 0
            ;;
    esac
    # fresh: до установки ничего не работало, возвращать нечего.
    RUNTIME_STOPPED=0
    return 0
}

csqtt_systemd_unit_exists() {
    command -v systemctl >/dev/null 2>&1 || return 1
    local state
    state="$(systemctl show --value -p LoadState csqtt 2>/dev/null || true)"
    [ -n "$state" ] && [ "$state" != "not-found" ]
}

csqtt_systemd_unit_is_managed() {
    csqtt_systemd_unit_exists || return 1
    local unit
    unit="$(systemctl cat csqtt 2>/dev/null || true)"
    printf '%s\n' "$unit" | grep -Fq -- "${CSQTT_BIN_DIR}/csqtt" && return 0
    printf '%s\n' "$unit" | grep -Fq -- "${CSQTT_LIB_DIR}/" && return 0
    return 1
}

csqtt_docker_container_exists() {
    command -v docker >/dev/null 2>&1 && docker inspect "$CSQTT_DOCKER_CONTAINER" >/dev/null 2>&1
}

docker_container_runs_csqtt() {
    local container="$1" container_id proc pid cgroup executable command_line details
    docker inspect "$container" >/dev/null 2>&1 || return 1
    details="$(docker inspect --format '{{.Name}}|{{.Config.Image}}|{{json .Config.Entrypoint}}|{{json .Config.Cmd}}|{{range .Mounts}}{{.Source}}:{{.Destination}}|{{end}}' "$container" 2>/dev/null || true)"
    case "$details" in
        *'|csqtt|'*|*'|csqtt:'*|*'|csqtt-docker-'*|*"${CSQTT_BIN_DIR}/csqtt"*|*":${CSQTT_CONFIG_DIR}"*) return 0 ;;
    esac
    if docker top "$container" -eo pid,args 2>/dev/null | awk -v bin="${CSQTT_BIN_DIR}/csqtt" '
NR > 1 {
    for (i = 1; i <= NF; i++) if ($i == bin) found = 1
}
END { exit !found }
'; then
        return 0
    fi
    container_id="$(docker inspect --format '{{.Id}}' "$container" 2>/dev/null || true)"
    [ -n "$container_id" ] || return 1
    for proc in /proc/[0-9]*; do
        pid="${proc##*/}"
        cgroup="$(cat "$proc/cgroup" 2>/dev/null || true)"
        case "$cgroup" in
            *"docker-${container_id}.scope"*|*"/docker/${container_id}"*) ;;
            *) continue ;;
        esac
        executable="$(readlink "$proc/exe" 2>/dev/null || true)"
        case "$executable" in
            "${CSQTT_BIN_DIR}/csqtt"|"${CSQTT_BIN_DIR}/csqtt (deleted)") return 0 ;;
        esac
        command_line="$({ tr '\0' ' ' < "$proc/cmdline"; } 2>/dev/null || true)"
        case " $command_line " in
            *" ${CSQTT_BIN_DIR}/csqtt "*|*" --config-dir ${CSQTT_CONFIG_DIR} "*) return 0 ;;
        esac
    done
    return 1
}

csqtt_persistent_state_exists() {
    [ -f "$CSQTT_ENV_FILE" ] || [ -f "${CSQTT_CONFIG_DIR}/${CSQTT_DATABASE_FILE}" ] || \
        [ -f "${CSQTT_CONFIG_DIR}/web_cert.pem" ] || [ -f "${CSQTT_CONFIG_DIR}/web_key.pem" ]
}

peer_port_listeners() {
    ss -H -lunp "sport = :${PEER_PORT}" 2>/dev/null || true
}

peer_port_listener_pids() {
    peer_port_listeners | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -un || true
}

docker_container_for_pid() {
    local pid="$1" cgroup container_id
    command -v docker >/dev/null 2>&1 || return 1
    cgroup="$(cat "/proc/$pid/cgroup" 2>/dev/null || true)"
    container_id="$(printf '%s\n' "$cgroup" | sed -nE 's#.*docker-([0-9a-f]{12,64})\.scope.*#\1#p; s#.*/docker/([0-9a-f]{12,64}).*#\1#p' | head -n 1)"
    [ -n "$container_id" ] || return 1
    docker inspect "$container_id" >/dev/null 2>&1 || return 1
    printf '%s\n' "$container_id"
}

csqtt_process_is_owned() {
    local pid="$1" executable command_line
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -r "/proc/$pid/cmdline" ] || return 1
    executable="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    case "$executable" in
        "${CSQTT_BIN_DIR}/csqtt"|"${CSQTT_BIN_DIR}/csqtt (deleted)"|"${CSQTT_LIB_DIR}/"*|"${CSQTT_LIB_DIR}/"*" (deleted)") return 0 ;;
    esac
    command_line="$({ tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null || true)"
    case " $command_line " in
        *" --config-dir ${CSQTT_CONFIG_DIR} "*|*" ${CSQTT_BIN_DIR}/csqtt "*|*" ${CSQTT_LIB_DIR}/"*) ;;
        *) return 1 ;;
    esac
    return 0
}

csqtt_process_owns_peer_port() { csqtt_process_is_owned "$1"; }

all_csqtt_process_pids() {
    local proc pid
    for proc in /proc/[0-9]*; do
        pid="${proc##*/}"
        csqtt_process_is_owned "$pid" && printf '%s\n' "$pid"
    done
    return 0
}

csqtt_peer_port_is_owned() {
    local pid
    while IFS= read -r pid; do
        csqtt_process_owns_peer_port "$pid" && return 0
    done < <(peer_port_listener_pids)
    return 1
}

force_stop_csqtt_processes() {
    local pid attempt found
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        found=0
        while IFS= read -r pid; do
            found=1
            log_warn "Принудительное завершение CSQTT: PID $pid"
            if [ "$attempt" -le 2 ]; then
                kill -TERM "$pid" 2>/dev/null || true
            else
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done < <(all_csqtt_process_pids)
        if [ "$found" -eq 0 ]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

force_release_peer_port() {
    local attempt pid container found
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -z "$(peer_port_listeners)" ] && return 0
        found=0
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            found=1
            container="$(docker_container_for_pid "$pid" 2>/dev/null || true)"
            if [ -n "$container" ]; then
                log_warn "Принудительное удаление Docker runtime на UDP/${PEER_PORT}: ${container:0:12}"
                docker update --restart=no "$container" >/dev/null 2>&1 || true
                docker rm -f "$container" >/dev/null 2>&1 || true
            elif [ "$attempt" -le 2 ]; then
                log_warn "Принудительное завершение runtime на UDP/${PEER_PORT}: PID $pid"
                kill -TERM "$pid" 2>/dev/null || true
            else
                log_warn "Принудительное завершение runtime на UDP/${PEER_PORT}: PID $pid"
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done < <(peer_port_listener_pids)
        if [ "$found" -eq 0 ]; then
            log_error "UDP/${PEER_PORT} занят runtime без доступного PID"
            peer_port_listeners | tee -a "$LOG_FILE" >&2
            return 1
        fi
        sleep 0.2
    done
    peer_port_listeners | tee -a "$LOG_FILE" >&2
    return 1
}

assert_peer_port_is_available() {
    local listeners
    listeners="$(peer_port_listeners)"
    [ -z "$listeners" ] && return 0
    log_warn "UDP/${PEER_PORT} занят; выполняется принудительное освобождение"
    force_release_peer_port || die "Не удалось принудительно освободить UDP/${PEER_PORT}"
    [ -z "$(peer_port_listeners)" ] || die "UDP/${PEER_PORT} остался занят после принудительной очистки"
}

web_port_listeners() {
    ss -ltnH "sport = :${WEB_PORT}" 2>/dev/null || true
}

# Порт панели занимает чужой процесс: принудительного освобождения здесь нет,
# в отличие от assert_peer_port_is_available. Проверка стоит перед стартом
# панели и покрывает обе ветки — systemd и docker.
assert_web_port_is_available() {
    local listeners
    listeners="$(web_port_listeners)"
    [ -z "$listeners" ] && return 0
    log_warn "TCP/${WEB_PORT} занят другим процессом:"
    printf '%s\n' "$listeners" | tee -a "$LOG_FILE" >&2
    die "Порт ${WEB_PORT} занят другим процессом; освободите его и повторите установку"
}

archive_csqtt_docker_state() {
    local container="$1" container_id archive_dir source base copied=0
    container_id="$(docker inspect --format '{{.Id}}' "$container" 2>/dev/null || true)"
    [ -n "$container_id" ] || return 0
    archive_dir="${CSQTT_RUNTIME_ARCHIVE_DIR}/docker-${container_id:0:12}-$(date +%s)"
    umask 077
    mkdir -p "$archive_dir" || die "Не удалось подготовить архив состояния Docker CSQTT"
    for source in "${CSQTT_CONFIG_DIR}/${CSQTT_DATABASE_FILE}" "${CSQTT_CONFIG_DIR}/${CSQTT_DATABASE_WAL_FILE}" "${CSQTT_CONFIG_DIR}/${CSQTT_DATABASE_SHM_FILE}" "${CSQTT_CONFIG_DIR}/passwords.json" "${CSQTT_CONFIG_DIR}/passwords.json.imported"; do
        base="${source##*/}"
        if docker cp "${container}:${source}" "${archive_dir}/${base}" >/dev/null 2>&1; then
            chmod 600 "${archive_dir}/${base}" 2>/dev/null || true
            copied=1
        fi
    done
    if [ "$copied" -eq 1 ]; then
        log_info "Состояние Docker CSQTT сохранено: $archive_dir"
    else
        rmdir "$archive_dir" >/dev/null 2>&1 || true
    fi
}

stop_and_archive_csqtt_docker_container() {
    local container="$1" name running
    docker inspect "$container" >/dev/null 2>&1 || return 0
    name="$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null || printf '%s' "$container")"
    name="${name#/}"
    docker update --restart=no "$container" >/dev/null 2>&1 || true
    running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || printf false)"
    if [ "$running" = "true" ]; then
        timeout 10 docker stop --time 5 "$container" >/dev/null 2>&1 || true
        if [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || printf false)" = "true" ]; then
            docker kill "$container" >/dev/null 2>&1 || true
        fi
    fi
    archive_csqtt_docker_state "$container"
    timeout 10 docker rm -f "$container" >/dev/null 2>&1 || \
        die "Не удалось остановить старый Docker-контейнер CSQTT"
}

remove_all_csqtt_docker_containers() {
    command -v docker >/dev/null 2>&1 || return 0
    local container name
    while IFS= read -r container; do
        [ -n "$container" ] || continue
        docker_container_runs_csqtt "$container" || continue
        name="$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null || printf '%s' "$container")"
        name="${name#/}"
        log_info "Остановка Docker runtime CSQTT: $name"
        stop_and_archive_csqtt_docker_container "$container"
    done < <(docker ps -aq --no-trunc 2>/dev/null || true)
}

systemd_unit_runs_csqtt() {
    local unit="$1" content
    content="$(systemctl cat "$unit" 2>/dev/null || true)"
    printf '%s\n' "$content" | grep -Fq -- "${CSQTT_BIN_DIR}/csqtt" && return 0
    printf '%s\n' "$content" | grep -Fq -- "${CSQTT_LIB_DIR}/" && return 0
    return 1
}

list_csqtt_systemd_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit
    while IFS= read -r unit; do
        case "$unit" in
            *.service) ;;
            *) continue ;;
        esac
        case "$unit" in
            "$CSQTT_DOCKER_PREREQ_SERVICE"|"$CSQTT_LE_SERVICE") continue ;;
        esac
        if systemd_unit_runs_csqtt "$unit"; then
            printf '%s\n' "$unit"
        fi
    done < <({
        systemctl list-units --type=service --all --no-legend --plain 2>/dev/null || true
        systemctl list-unit-files --type=service --no-legend --plain 2>/dev/null || true
    } | awk '{print $1}' | sort -u)
    return 0
}

stop_csqtt_docker_prereq() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local requires_link="${CSQTT_SYSTEMD_DIR}/docker.service.requires/${CSQTT_DOCKER_PREREQ_SERVICE}"
    local wants_link="${CSQTT_SYSTEMD_DIR}/docker.service.wants/${CSQTT_DOCKER_PREREQ_SERVICE}"
    if [ -e "$requires_link" ] || [ -L "$requires_link" ]; then
        rm -f -- "$requires_link"
        SYSTEMD_NEEDS_RELOAD=1
    fi
    if [ -e "$wants_link" ] || [ -L "$wants_link" ]; then
        rm -f -- "$wants_link"
        SYSTEMD_NEEDS_RELOAD=1
    fi
    systemctl disable "$CSQTT_DOCKER_PREREQ_SERVICE" >/dev/null 2>&1 || true
    if [ "$SYSTEMD_NEEDS_RELOAD" -eq 1 ]; then
        systemctl daemon-reload || die "systemctl daemon-reload завершился ошибкой при отключении Docker prerequisites"
        SYSTEMD_NEEDS_RELOAD=0
    fi
    if systemctl is-active --quiet "$CSQTT_DOCKER_PREREQ_SERVICE"; then
        log_info "Остановка Docker prerequisite CSQTT: $CSQTT_DOCKER_PREREQ_SERVICE"
        timeout 10 systemctl stop "$CSQTT_DOCKER_PREREQ_SERVICE" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "$CSQTT_DOCKER_PREREQ_SERVICE"; then
            timeout 2 systemctl kill --kill-who=all --signal=SIGKILL "$CSQTT_DOCKER_PREREQ_SERVICE" >/dev/null 2>&1 || true
        fi
        if systemctl is-active --quiet "$CSQTT_DOCKER_PREREQ_SERVICE"; then
            die "Не удалось остановить Docker prerequisite CSQTT: $CSQTT_DOCKER_PREREQ_SERVICE"
        fi
    fi
}

stop_all_running_csqtt_systemd_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        log_info "Остановка systemd runtime CSQTT: $unit"
        if ! timeout 10 systemctl stop "$unit" >/dev/null 2>&1; then
            log_warn "systemctl stop завершился с ошибкой для $unit; проверяется фактическое состояние"
        fi
        if systemctl is-active --quiet "$unit"; then
            timeout 2 systemctl kill --kill-who=all --signal=SIGKILL "$unit" >/dev/null 2>&1 || true
        fi
        if systemctl is-active --quiet "$unit"; then
            die "Не удалось остановить systemd runtime CSQTT: $unit"
        fi
        systemctl disable "$unit" >/dev/null 2>&1 || true
    done < <(list_csqtt_systemd_units)
    return 0
}

remove_all_csqtt_systemd_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit fragment
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        fragment="$(systemctl show --value -p FragmentPath "$unit" 2>/dev/null || true)"
        case "$fragment" in
            "${CSQTT_SYSTEMD_DIR}"/*)
                rm -f -- "$fragment"
                rm -rf -- "${fragment}.d"
                rm -f -- "${CSQTT_SYSTEMD_DIR}/multi-user.target.wants/${unit}"
                SYSTEMD_NEEDS_RELOAD=1
                ;;
        esac
    done < <(list_csqtt_systemd_units)
    return 0
}

prog() { echo "CSQTT_PROGRESS|$1|$2"; }

run_timed() {
    local label="$1" started=$SECONDS
    shift
    "$@"
    log_info "Время этапа «$label»: $((SECONDS - started))с"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        # Root проверяется ДО TTY-guard: иначе `bash <(curl ...)` без sudo
        # сообщал бы про stdin, хотя настоящая причина — отсутствие прав.
        die "Скрипт должен быть запущен от root. Скачайте установщик и запустите через sudo: curl -fsSL https://github.com/w3struk/csqttr/releases/latest/download/install.sh -o /tmp/csqtt-install.sh && sudo bash /tmp/csqtt-install.sh --yes" "$EXIT_INVALID_ARGUMENT"
    fi
}

# После root-check. Интерактив возможен только с настоящим терминалом;
# неинтерактивный путь — всегда `curl -o && sudo bash ... --yes`.
require_tty_guard() {
    [ "${CHECK_ONLY:-0}" -eq 0 ] || return 0
    [ "${YES:-0}" -eq 0 ] || return 0
    [ -t 0 ] && return 0
    die "Нет TTY для интерактивной установки. Скачайте установщик и запустите неинтерактивно: curl -fsSL https://github.com/w3struk/csqttr/releases/latest/download/install.sh -o /tmp/csqtt-install.sh && sudo bash /tmp/csqtt-install.sh --yes" "$EXIT_INVALID_ARGUMENT"
}

# --web-pass-stdin не имеет права читать тело piped-скрипта как пароль:
# сначала настоящий stdin-TTY, затем отдельный /dev/tty, иначе явный отказ.
read_web_password_from_stdin() {
    local tty="${CSQTT_TTY_PATH:-/dev/tty}"
    if [ -t 0 ]; then
        IFS= read -r -s WEB_PASS || WEB_PASS=""
        printf '\n' >&2
    elif { exec 3<"$tty"; } 2>/dev/null; then
        IFS= read -r -s WEB_PASS <&3 || WEB_PASS=""
        exec 3<&-
        printf '\n' >&2
    else
        die "--web-pass-stdin: stdin занят piped-скриптом, а ${tty} недоступен. Скачайте установщик и повторите: curl -fsSL https://github.com/w3struk/csqttr/releases/latest/download/install.sh -o /tmp/csqtt-install.sh && sudo bash /tmp/csqtt-install.sh --web-pass-stdin --yes" "$EXIT_INVALID_ARGUMENT"
    fi
    [ -n "${WEB_PASS:-}" ] || die "--web-pass-stdin получил пустой пароль" "$EXIT_INVALID_ARGUMENT"
    WEB_PASS_STDIN=0
}

read_web_password_if_requested() {
    [ "${WEB_PASS_STDIN:-0}" -eq 1 ] || return 0
    [ -z "${WEB_PASS:-}" ] || { WEB_PASS_STDIN=0; return 0; }
    read_web_password_from_stdin
}

OS_ID="" ; PKG_MGR=""

detect_os() {
    log_step "Определение операционной системы..."
    if [ ! -f /etc/os-release ]; then
        die "Файл /etc/os-release не найден."
    fi
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop)     PKG_MGR="apt" ;;
        centos|rhel|rocky|almalinux|oracle|ol) PKG_MGR="yum"
            command -v dnf &>/dev/null && PKG_MGR="dnf" ;;
        fedora)                          PKG_MGR="dnf" ;;
        arch|manjaro|endeavouros)        PKG_MGR="pacman" ;;
        *)
            case " ${ID_LIKE:-} " in
                *" debian "*) PKG_MGR="apt" ;;
                *" rhel "*|*" fedora "*)
                    PKG_MGR="yum"
                    command -v dnf &>/dev/null && PKG_MGR="dnf"
                    ;;
                *" arch "*) PKG_MGR="pacman" ;;
                *) die "Неподдерживаемый дистрибутив: $OS_ID" ;;
            esac
            ;;
    esac
    log_info "ОС: ${PRETTY_NAME:-$OS_ID} | PM: $PKG_MGR"
}

pkg_update_done=0

pkg_update() {
    [ "$pkg_update_done" = "1" ] && return 0
    log_step "Обновление индексов пакетов..."
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >>"$LOG_FILE" 2>&1 || log_warn "apt update завершился с ошибкой, пробую продолжить"
            ;;
        dnf)    dnf makecache -y >>"$LOG_FILE" 2>&1 || true ;;
        yum)    yum makecache -y >>"$LOG_FILE" 2>&1 || true ;;
        pacman) : ;;
    esac
    pkg_update_done=1
}

pkg_install() {
    [ "$#" -eq 0 ] && return 0
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y -qq --no-install-recommends "$@" >>"$LOG_FILE" 2>&1
            ;;
        dnf)    dnf install -y "$@" >>"$LOG_FILE" 2>&1 ;;
        yum)    yum install -y "$@" >>"$LOG_FILE" 2>&1 ;;
        pacman) pacman -Syu --noconfirm --needed "$@" >>"$LOG_FILE" 2>&1 ;;
    esac
}

pkg_install_with_refresh() {
    pkg_install "$@" && return 0
    pkg_update
    pkg_install "$@"
}

# ca-certificates не даёт одноимённой команды, поэтому проверяется сам bundle:
# без него curl скачает ассеты по https, но не сможет проверить сертификат
# github.com, и установка на голой системе упадёт на первом же download.
# Оба пути проверяются без PKG_MGR: функция вызывается и из --check, где
# detect_os ещё не выполнялся.
ca_certificates_present() {
    [ -s /etc/ssl/certs/ca-certificates.crt ] || \
        [ -s /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem ]
}

install_prerequisites() {
    # Пакетные зависимости — preflight: отказ обязан дать exit 20, а не 2.
    DEPLOY_PHASE="preflight"
    prog 0.10 "Пакеты..."
    log_step "Проверка базовых зависимостей..."

    local ip_package procps_package
    case "$PKG_MGR" in
        apt)     ip_package="iproute2"; procps_package="procps" ;;
        dnf|yum) ip_package="iproute";  procps_package="procps-ng" ;;
        pacman)  ip_package="iproute2"; procps_package="procps-ng" ;;
    esac

    local -a packages=()
    local need_iptables=0
    command -v ip >/dev/null 2>&1 || packages+=("$ip_package")
    command -v curl >/dev/null 2>&1 || packages+=("curl")
    ca_certificates_present || packages+=("ca-certificates")
    # openssl нужен раньше, чем его ставит ensure_letsencrypt_client: до этого
    # момента setup_web_panel_tls классифицирует уже лежащий сертификат, а без
    # openssl валидный Let's Encrypt-сертификат выглядит «пользовательским».
    command -v openssl >/dev/null 2>&1 || packages+=("openssl")
    command -v modprobe >/dev/null 2>&1 || packages+=("kmod")
    if ! command -v sysctl >/dev/null 2>&1; then
        packages+=("$procps_package")
    fi
    command -v iptables >/dev/null 2>&1 || need_iptables=1

    if [ "$PKG_MGR" = "pacman" ] && [ "$need_iptables" -eq 1 ]; then
        packages+=("iptables")
        need_iptables=0
    fi

    if [ "${#packages[@]}" -eq 0 ] && [ "$need_iptables" -eq 0 ]; then
        log_info "Все системные зависимости уже установлены — обновление пакетов не требуется"
        return 0
    fi

    pkg_update
    if [ "${#packages[@]}" -gt 0 ]; then
        pkg_install "${packages[@]}" || die "Не удалось установить обязательные пакеты: ${packages[*]}"
    fi

    if [ "$need_iptables" -eq 1 ]; then
        case "$PKG_MGR:$OS_ID" in
            dnf:fedora)
                pkg_install iptables-nft || pkg_install iptables || \
                    die "Не удалось установить iptables/iptables-nft"
                ;;
            dnf:*|yum:*)
                pkg_install iptables || pkg_install iptables-nft || \
                    die "Не удалось установить iptables/iptables-nft"
                ;;
            *)
                pkg_install iptables || die "Не удалось установить обязательный пакет iptables"
                ;;
        esac
    fi
}

require_runtime_tools() {
    # Проверка окружения — preflight даже после resolve_install_configuration,
    # который переводит фазу в validation.
    DEPLOY_PHASE="preflight"
    command -v ip >/dev/null 2>&1 || die "Команда ip не найдена. Установите iproute2/iproute."
    command -v iptables >/dev/null 2>&1 || die "Команда iptables не найдена. Она обязательна для TUN и NAT."
    command -v sysctl >/dev/null 2>&1 || die "Команда sysctl не найдена. Установите procps/procps-ng."
    if [ "$DEPLOY_MODE" = "systemd" ]; then
        command -v systemctl >/dev/null 2>&1 || die "systemctl не найден. Для native-установки нужен VPS с systemd."
    fi
    case "$(uname -m)" in
        x86_64|amd64) log_info "Архитектура VPS: amd64" ;;
        *) die "Архитектура VPS $(uname -m) не поддерживается. Поддерживается только x86_64/amd64." ;;
    esac
}

# --check ничего не меняет, поэтому отсутствие пакетов, которые поставил бы
# install_prerequisites, — не отказ: на голой Debian minimal iptables нет, но
# установка его добавит. Блокируют только вещи, которые установщик не исправит:
# архитектура и отсутствие systemd для native-режима.
check_runtime_requirements() {
    DEPLOY_PHASE="preflight"
    case "$(uname -m)" in
        x86_64|amd64) log_info "Архитектура VPS: amd64" ;;
        *) die "Архитектура VPS $(uname -m) не поддерживается. Поддерживается только x86_64/amd64." \
            "$EXIT_PREFLIGHT_FAILED" ;;
    esac
    if [ "$DEPLOY_MODE" = "systemd" ]; then
        command -v systemctl >/dev/null 2>&1 || \
            die "systemctl не найден. Для native-установки нужен VPS с systemd." "$EXIT_PREFLIGHT_FAILED"
    fi

    local -a pending=()
    command -v ip >/dev/null 2>&1 || pending+=("iproute2")
    command -v iptables >/dev/null 2>&1 || pending+=("iptables")
    command -v sysctl >/dev/null 2>&1 || pending+=("procps")
    command -v openssl >/dev/null 2>&1 || pending+=("openssl")
    ca_certificates_present || pending+=("ca-certificates")
    if [ "${#pending[@]}" -gt 0 ]; then
        log_info "При установке будут добавлены пакеты: ${pending[*]}"
    fi
}

detect_wan_interface() {
    local iface fallback=""
    while IFS= read -r iface; do
        iface="${iface%%@*}"
        [ -n "$iface" ] || continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            echo "$iface"
            return 0
        fi
    done <<EOF
$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); break}}')
EOF
    while IFS= read -r iface; do
        iface="${iface%%@*}"
        [ -n "$iface" ] || continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            echo "$iface"
            return 0
        fi
    done <<EOF
$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/@.*/, "", $2); print $2}')
EOF
    while IFS= read -r iface; do
        iface="${iface%%@*}"
        [ -n "$iface" ] || continue
        [ "$iface" = "lo" ] && continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            echo "$iface"
            return 0
        fi
    done <<EOF
$(ls /sys/class/net/ 2>/dev/null || true)
EOF
    [ -n "$fallback" ] && echo "$fallback"
}

is_ignored_wan_interface() {
    local iface="${1%%@*}"
    case "$iface" in
        ""|lo|"$CSQTT_IFACE"|csqtp*|tun*|tap*|wg*|warp*|Warp*|WARP*|CloudflareWARP*|tailscale*|zt*|docker*|br-*|veth*|cni*|flannel*|virbr*|podman*|kube*|dummy*|ifb*)
            return 0
            ;;
    esac
    return 1
}

detect_firewall() {
    command -v iptables >/dev/null 2>&1 || \
        die "iptables не найден: без него сервер не сможет создать рабочий TUN/NAT."
    local ver
    ver="$(iptables --version 2>/dev/null || echo unknown)"
    log_info "Firewall backend: iptables (${ver})"
}

ipt_add_or_ensure() {
    local table="$1" chain="$2"
    shift 2
    local -a targs=()
    [ "$table" = "filter" ] || targs=(-t "$table")
    iptables -w "$XT_WAIT" "${targs[@]}" -C "$chain" "$@" >/dev/null 2>&1 || \
        iptables -w "$XT_WAIT" "${targs[@]}" -I "$chain" 1 "$@" >>"$LOG_FILE" 2>&1
}

fw_add_input_udp() {
    local port="$1"
    ipt_add_or_ensure filter INPUT -p udp --dport "$port" -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
        die "Не удалось открыть ${port}/udp в iptables"
}

fw_add_input_tcp() {
    local port="$1"
    ipt_add_or_ensure filter INPUT -p tcp --dport "$port" -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
        die "Не удалось открыть ${port}/tcp в iptables"
}

# Правила firewall только добавляются, поэтому порт, который панель больше не
# использует, закрывается явно. Цикл ограничен: `iptables -D` возвращает неуспех,
# когда правила нет, а на чистой машине это постоянное состояние — неограниченный
# цикл там завис бы. Перечисление — через `-S INPUT`, как в delete_marked_rules.
fw_remove_input_tcp() {
    local port="$1" attempt listing
    for attempt in 1 2 3 4 5 6 7 8; do
        listing="$(iptables -w "$XT_WAIT" -S INPUT 2>/dev/null || true)"
        printf '%s\n' "$listing" | \
            grep -Eq -- "^-A INPUT .*--dport ${port}([[:space:]]|$).*${IPT_COMMENT}" || return 0
        if iptables -w "$XT_WAIT" -D INPUT -p tcp --dport "$port" \
            -m comment --comment "$IPT_COMMENT" -j ACCEPT >>"$LOG_FILE" 2>&1; then
            return 0
        fi
    done
    log_warn "Не удалось закрыть TCP/${port} в iptables за 8 попыток: правило могло остаться"
    return 1
}

# В доменном режиме панель уезжает на 443, в IP-режиме — обратно на 46002.
fw_close_unused_panel_port() {
    case "${PANEL_MODE:-}" in
        domain) fw_remove_input_tcp "46002" || true ;;
        ip) fw_remove_input_tcp "443" || true ;;
    esac
}

fw_add_forward() {
    ipt_add_or_ensure filter INPUT -i "$CSQTT_IFACE" -s "10.66.67.0/24" -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
        die "Не удалось установить INPUT -i $CSQTT_IFACE"
    ipt_add_or_ensure filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true
    ipt_add_or_ensure filter FORWARD -i "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
        die "Не удалось установить FORWARD -i $CSQTT_IFACE"
    ipt_add_or_ensure filter FORWARD -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
        die "Не удалось установить FORWARD -o $CSQTT_IFACE"
}

fw_add_masquerade() {
    local iface="$1" subnet="$2"
    if [ -n "$iface" ]; then
        iptables -w "$XT_WAIT" -t nat -C POSTROUTING -s "$subnet" -o "$iface" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >/dev/null 2>&1 || \
            iptables -w "$XT_WAIT" -t nat -A POSTROUTING -s "$subnet" -o "$iface" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >>"$LOG_FILE" 2>&1 || true
        local wan_ip
        wan_ip="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
        if [ -n "$wan_ip" ]; then
            iptables -w "$XT_WAIT" -t nat -C POSTROUTING -s "$subnet" -o "$iface" -m comment --comment "$IPT_COMMENT" -j SNAT --to-source "$wan_ip" >/dev/null 2>&1 || \
                iptables -w "$XT_WAIT" -t nat -I POSTROUTING 1 -s "$subnet" -o "$iface" -m comment --comment "$IPT_COMMENT" -j SNAT --to-source "$wan_ip" >>"$LOG_FILE" 2>&1 || true
        fi
    fi
    iptables -w "$XT_WAIT" -t nat -C POSTROUTING -s "$subnet" ! -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >/dev/null 2>&1 || \
        iptables -w "$XT_WAIT" -t nat -A POSTROUTING -s "$subnet" ! -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >>"$LOG_FILE" 2>&1 || \
        die "Не удалось установить NAT MASQUERADE"
}

fw_add_mss_clamping() {
    local subnet="$1"
    ipt_add_or_ensure mangle FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu || \
        die "Не удалось установить исходящий TCP MSS clamping"
    ipt_add_or_ensure mangle FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu || \
        die "Не удалось установить входящий TCP MSS clamping"
}

delete_marked_rules() {
    local table="$1" chain="$2" marker="$3" i numbers number
    local -a targs=()
    [ "$table" = "filter" ] || targs=(-t "$table")
    for i in 1 2 3 4 5 6 7 8; do
        numbers="$(iptables -w "$XT_WAIT" "${targs[@]}" -S "$chain" 2>/dev/null | awk -v chain="$chain" -v marker="$marker" '
$1 == "-A" && $2 == chain {
    n++
    if (index($0, marker)) hit[++h] = n
}
END {
    for (i = h; i >= 1; i--) print hit[i]
}
')" || return 0
        [ -n "$numbers" ] || break
        while IFS= read -r number; do
            [ -n "$number" ] && iptables -w "$XT_WAIT" "${targs[@]}" -D "$chain" "$number" >/dev/null 2>&1 || true
        done <<EOF
$numbers
EOF
    done
}

# Правила TCPMSS ставились до 2.5.2 без комментария CSQTT_MANAGED, поэтому
# delete_marked_rules их не находит. Удаляем по точной форме, пока правило есть:
# отсутствие таких правил — нормальное состояние, а не ошибка.
delete_legacy_mss_clamping_rules() {
    local direction attempt listing
    listing="$(iptables -w "$XT_WAIT" -t mangle -S FORWARD 2>/dev/null || true)"
    case "$listing" in
        *"TCPMSS --clamp-mss-to-pmtu"*) ;;
        *) return 0 ;;
    esac
    for direction in -s -d; do
        for attempt in 1 2 3 4; do
            iptables -w "$XT_WAIT" -t mangle -D FORWARD "$direction" "10.66.67.0/24" \
                -p tcp -m tcp --tcp-flags SYN,RST SYN \
                -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || break
        done
    done
}

cleanup_csqtt_netfilter_rules() {
    local table chain
    for table in filter nat mangle; do
        for chain in INPUT FORWARD PREROUTING POSTROUTING OUTPUT; do
            delete_marked_rules "$table" "$chain" "$IPT_COMMENT"
        done
    done
    delete_legacy_mss_clamping_rules
}

secure_persistent_state() {
    [ -d "$CSQTT_CONFIG_DIR" ] || return 0
    chmod 700 "$CSQTT_CONFIG_DIR" 2>/dev/null || true
    [ -d "$CSQTT_RUNTIME_ARCHIVE_DIR" ] && chmod 700 "$CSQTT_RUNTIME_ARCHIVE_DIR" 2>/dev/null || true

    local file
    for file in \
        "$CSQTT_DATABASE_FILE" \
        "$CSQTT_DATABASE_WAL_FILE" \
        "$CSQTT_DATABASE_SHM_FILE" \
        "passwords.json" \
        "passwords.json.imported" \
        "install.json" \
        "${CSQTT_DATABASE_FILE}.pre-owner-migration" \
        "${CSQTT_DATABASE_FILE}.pre-owner-migration-wal" \
        "${CSQTT_DATABASE_FILE}.pre-owner-migration-shm"; do
        [ -f "$CSQTT_CONFIG_DIR/$file" ] && chmod 600 "$CSQTT_CONFIG_DIR/$file" 2>/dev/null || true
    done
    [ -f "$CSQTT_ENV_FILE" ] && chmod 600 "$CSQTT_ENV_FILE" 2>/dev/null || true
    [ -f "$CSQTT_CONFIG_DIR/web_cert.pem" ] && chmod 644 "$CSQTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true
    [ -f "$CSQTT_CONFIG_DIR/web_key.pem" ] && chmod 600 "$CSQTT_CONFIG_DIR/web_key.pem" 2>/dev/null || true
    [ -f "$CSQTT_LE_STATE_FILE" ] && chmod 600 "$CSQTT_LE_STATE_FILE" 2>/dev/null || true
}

ensure_csqtt_directory() {
    local path="$1" mode="$2"
    if [ -L "$path" ] || [ ! -d "$path" ]; then
        rm -rf -- "$path" || die "Не удалось очистить путь CSQTT: $path"
    fi
    mkdir -p -- "$path" || die "Не удалось подготовить каталог CSQTT: $path"
    chmod "$mode" "$path" || die "Не удалось установить права на каталог CSQTT: $path"
}

# Каталог данных нельзя пересоздавать: владелец мог вынести его на другой диск
# симлинком, и rm -rf по ссылке уничтожил бы саму ссылку, оставив данные «в
# стороне». Здесь ничего не удаляется никогда.
ensure_persistent_directory() {
    local path="$1" mode="$2" resolved
    if [ -L "$path" ]; then
        resolved="$(readlink -f -- "$path" 2>/dev/null || true)"
        [ -n "$resolved" ] || \
            die "Не удалось разрешить символическую ссылку каталога данных CSQTT: $path"
        [ -d "$resolved" ] || \
            die "Символическая ссылка каталога данных CSQTT ведёт в несуществующий путь: $path -> $resolved"
        path="$resolved"
    fi
    if [ -e "$path" ] && [ ! -d "$path" ]; then
        die "Путь каталога данных CSQTT существует, но это не каталог: $path"
    fi
    mkdir -p -- "$path" || die "Не удалось подготовить каталог CSQTT: $path"
    chmod "$mode" "$path" || die "Не удалось установить права на каталог CSQTT: $path"
}

clear_runtime_config_preserving_database() {
    local entry base
    ensure_persistent_directory "$CSQTT_CONFIG_DIR" 700
    shopt -s nullglob dotglob
    for entry in "$CSQTT_CONFIG_DIR"/*; do
        base="${entry##*/}"
        case "$base" in
            "$CSQTT_DATABASE_FILE"|"$CSQTT_DATABASE_WAL_FILE"|"$CSQTT_DATABASE_SHM_FILE"|passwords.json|passwords.json.imported|install.json|csqtt.db.pre-owner-migration|csqtt.db.pre-owner-migration-wal|csqtt.db.pre-owner-migration-shm|web_cert.pem|web_key.pem|letsencrypt-ip.env|letsencrypt.env|runtime-archive) continue ;;
        esac
        rm -rf -- "$entry"
    done
    shopt -u nullglob dotglob
    secure_persistent_state
}

# install.json — плоский JSON, поэтому отдельный парсер на jq не нужен. Значения
# всегда строки: числа и пустые строки тоже пишутся в кавычках, иначе sed-извлечение
# перестанет быть однозначным. Отсутствующий ключ — пустой stdout и exit 1.
json_get() {
    local key="$1" file="$2" value=""
    [ -n "$key" ] || return 1
    case "$key" in
        *[!A-Za-z0-9_]*) return 1 ;;
    esac
    [ -f "$file" ] || return 1
    grep -Eq "\"${key}\"[[:space:]]*:" "$file" || return 1
    value="$(sed -n -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/p" "$file" | head -n 1)"
    printf '%s\n' "$value"
}

load_install_state() {
    json_get "$1" "$CSQTT_INSTALL_STATE_FILE"
}

# Значение ключа из EnvironmentFile без кавычек systemd-формы и экранирования.
# csqtt.env пишется systemd-формой (значения в двойных кавычках), поэтому
# сравнение с install.json идёт по очищенному значению.
env_file_value() {
    local key="$1" file="$2" line value
    [ -n "$key" ] && [ -f "$file" ] || return 1
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | head -n 1 || true)"
    [ -n "$line" ] || return 1
    value="${line#*=}"
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    value="${value//\\\"/\"}"
    value="${value//\\\\/\\}"
    printf '%s\n' "$value"
}

# Приводит host панели к тому виду, с которым работают валидаторы: без кавычек,
# экранирования, пробелов и в нижнем регистре.

# Docker --env-file не снимает кавычки: `CSQTT_WEB_SECRET_PATH="..."` уходит в
# контейнер вместе с кавычками, и панель считает secret path другим — соединение
# закрывается без ответа (TLS-handshake проходит, HTTP ответа нет). Поэтому
# переменные передаются через --env с уже разобранными значениями, тем же
# парсером, что читает systemd EnvironmentFile.
build_docker_env_args() {
    DOCKER_ENV_ARGS=()
    local key value
    for key in CSQTT_WEB_USER CSQTT_WEB_PASS CSQTT_PUBLIC_IP CSQTT_WEB_SECRET_PATH; do
        value="$(env_file_value "$key" "$CSQTT_ENV_FILE" 2>/dev/null || true)"
        [ -n "$value" ] || continue
        DOCKER_ENV_ARGS+=(--env "$key=$value")
    done
}

normalize_panel_host_value() {
    local raw="$1"
    printf '%s' "$raw" | tr -d '\\' | tr -d '"' | tr -d "'" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

# Режим панели по адресу. Пустой stdout — адрес не является ни публичным IPv4,
# ни доменом; вызывающая сторона решает, ошибка это или неоднозначность.
panel_mode_for_host() {
    local host="$1"
    if is_public_ipv4 "$host"; then
        printf 'ip\n'
        return 0
    fi
    if is_dns_hostname "$host"; then
        printf 'domain\n'
        return 0
    fi
    return 1
}

ssh_port_from_connection() {
    local -a fields
    # SSH_CONNECTION — "client_ip client_port server_ip server_port".
    read -r -a fields <<< "${SSH_CONNECTION:-}"
    [ "${#fields[@]}" -ge 4 ] || return 1
    case "${fields[3]}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "${fields[3]}"
}

csqtt_unit_file_is_managed() {
    local unit="${CSQTT_SYSTEMD_DIR}/csqtt.service"
    [ -f "$unit" ] || return 1
    grep -Fq -- "${CSQTT_BIN_DIR}/csqtt" "$unit" && return 0
    grep -Fq -- "${CSQTT_LIB_DIR}/" "$unit" && return 0
    return 1
}

csqtt_docker_image_exists() {
    command -v docker >/dev/null 2>&1 && \
        docker image inspect "$CSQTT_DOCKER_IMAGE" >/dev/null 2>&1
}

# fresh|systemd|docker. Unit обязан существовать и указывать на runtime CSQTT;
# в тестах и при недоступном systemctl эквивалентная проверка делается по
# самому unit-файлу. Docker — контейнер или образ CSQTT.
detect_existing_install() {
    if [ -f "${CSQTT_SYSTEMD_DIR}/csqtt.service" ] && \
       { csqtt_systemd_unit_is_managed || csqtt_unit_file_is_managed; }; then
        printf 'systemd\n'
        return 0
    fi
    if csqtt_docker_container_exists || csqtt_docker_image_exists; then
        printf 'docker\n'
        return 0
    fi
    printf 'fresh\n'
}

print_adoption_summary() {
    [ "$ADOPTION_PERFORMED" = "1" ] || return 0
    printf 'Обнаружена существующая установка: %s\n' "$INSTALL_KIND"
    printf '  режим: %s\n' "${DEPLOY_MODE:-}"
    printf '  порт туннеля: %s\n' "${PEER_PORT:-}"
    printf '  порт панели: %s\n' "${WEB_PORT:-}"
    printf '  хост панели: %s\n' "${PANEL_HOST:-<не определён>}"
    if [ "$ADOPTION_AMBIGUOUS" = "1" ]; then
        printf 'ADOPTION_AMBIGUOUS=1: не удалось однозначно определить host или режим\n'
    fi
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

# Текущий TLS-режим панели для state. Пустое значение — сертификата ещё нет.
current_tls_mode() {
    if web_certificate_is_user_managed; then
        printf 'user\n'
    elif certificate_is_csqtt_letsencrypt; then
        printf 'letsencrypt\n'
    elif certificate_is_csqtt_rcgen; then
        printf 'self-signed\n'
    fi
}

# Пишет install.json атомарно: temp в том же каталоге + mv. installed_at
# сохраняется с прошлой установки, updated_at всегда текущий.
write_install_state() {
    local installed_at updated_at tmp tls_mode

    updated_at="$(date +%s)"
    installed_at="$(load_install_state installed_at 2>/dev/null || true)"
    [ -n "$installed_at" ] || installed_at="$updated_at"
    tls_mode="$(current_tls_mode 2>/dev/null || true)"

    mkdir -p -- "$CSQTT_CONFIG_DIR" || die "Не удалось подготовить каталог состояния: $CSQTT_CONFIG_DIR"
    tmp="$(mktemp "${CSQTT_CONFIG_DIR}/.install.json.XXXXXX")" || \
        die "Не удалось создать временный файл состояния"
    chmod 600 "$tmp" || {
        rm -f -- "$tmp"
        die "Не удалось защитить временный файл состояния"
    }
    if ! printf '{"version":"%s","mode":"%s","panel_mode":"%s","panel_host":"%s","peer_port":"%s","web_port":"%s","ssh_port":"%s","tls":"%s","installed_at":"%s","updated_at":"%s"}\n' \
        "$(json_escape "$SCRIPT_VERSION")" \
        "$(json_escape "$DEPLOY_MODE")" \
        "$(json_escape "${PANEL_MODE:-}")" \
        "$(json_escape "${PANEL_HOST:-}")" \
        "$(json_escape "$PEER_PORT")" \
        "$(json_escape "$WEB_PORT")" \
        "$(json_escape "$SSH_PORT")" \
        "$(json_escape "$tls_mode")" \
        "$(json_escape "$installed_at")" \
        "$(json_escape "$updated_at")" > "$tmp"; then
        rm -f -- "$tmp"
        die "Не удалось записать состояние установки"
    fi
    if ! mv -f -- "$tmp" "$CSQTT_INSTALL_STATE_FILE"; then
        rm -f -- "$tmp"
        die "Не удалось активировать состояние установки"
    fi
}

# Оставляет три последних снимка по mtime; вызывается после успешного snapshot.
prune_runtime_archive() {
    local root="${1:-$CSQTT_RUNTIME_ARCHIVE_DIR}" dir mtime
    [ -d "$root" ] || return 0
    local -a entries=()
    shopt -s nullglob
    for dir in "$root"/*/; do
        entries+=("${dir%/}")
    done
    shopt -u nullglob
    [ "${#entries[@]}" -gt 3 ] || return 0
    while IFS=$'\t' read -r mtime dir; do
        [ -n "$dir" ] || continue
        rm -rf -- "$dir"
    done < <(
        for dir in "${entries[@]}"; do
            printf '%s\t%s\n' "$(stat -c %Y -- "$dir" 2>/dev/null || printf '0')" "$dir"
        done | sort -t $'\t' -k1,1n -k2,2 | head -n -3
    )
}

# Служба/контейнер останавливается ДО копирования: SQLite нельзя копировать на
# живую БД, и именно здесь начинается down-time. RUNTIME_STOPPED=1 взводится
# сразу, чтобы любая ошибка/сигнал в окне «stop → arm» вернул прежний runtime.
stop_runtime_for_snapshot() {
    local mode="${RUNTIME_SNAPSHOT_MODE:-}" unit container
    RUNTIME_STOPPED=1
    RUNTIME_STOPPED_UNITS=""
    RUNTIME_STOPPED_CONTAINERS=""
    case "$mode" in
        systemd)
            command -v systemctl >/dev/null 2>&1 || return 0
            RUNTIME_STOPPED_UNITS="$(list_csqtt_systemd_units 2>/dev/null || true)"
            # Заглушки systemctl в тестах не умеют list-units; production-путь
            # всё равно обязан остановить unit, который нашёлся на диске.
            if [ -z "$RUNTIME_STOPPED_UNITS" ] && [ -e "${CSQTT_SYSTEMD_DIR}/csqtt.service" ]; then
                RUNTIME_STOPPED_UNITS="csqtt"
            fi
            while IFS= read -r unit; do
                [ -n "$unit" ] || continue
                log_info "Остановка runtime перед снимком: $unit" >&2
                timeout 10 systemctl stop "$unit" >/dev/null 2>&1 || \
                    log_warn "systemctl stop $unit завершился ошибкой; проверяется фактическое состояние" >&2
                if systemctl is-active --quiet "$unit"; then
                    timeout 2 systemctl kill --kill-who=all --signal=SIGKILL "$unit" >/dev/null 2>&1 || true
                fi
                if systemctl is-active --quiet "$unit"; then
                    die "Не удалось остановить systemd runtime $unit перед снимком runtime"
                fi
            done <<< "$RUNTIME_STOPPED_UNITS"
            ;;
        docker)
            command -v docker >/dev/null 2>&1 || return 0
            while IFS= read -r container; do
                [ -n "$container" ] || continue
                docker_container_runs_csqtt "$container" || continue
                RUNTIME_STOPPED_CONTAINERS="${RUNTIME_STOPPED_CONTAINERS}${container}
"
                log_info "Остановка Docker runtime перед снимком: ${container:0:12}" >&2
                docker update --restart=no "$container" >/dev/null 2>&1 || true
                timeout 10 docker stop --time 5 "$container" >/dev/null 2>&1 || true
                if [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || printf false)" = "true" ]; then
                    docker kill "$container" >/dev/null 2>&1 || true
                fi
                if [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || printf false)" = "true" ]; then
                    die "Не удалось остановить Docker runtime перед снимком runtime"
                fi
            done < <(docker ps -q --no-trunc 2>/dev/null || true)
            ;;
    esac
}

# Битые/отсутствующие утилиты сети не должны срывать снимок: параметры пишутся
# всегда, дампы — если инструмент есть.
capture_network_snapshot() {
    local archive="$1" iface=""
    iface="$(detect_wan_interface 2>/dev/null || true)"
    {
        printf 'wan_iface=%s\n' "$iface"
        printf 'peer_port=%s\n' "$PEER_PORT"
        printf 'web_port=%s\n' "$WEB_PORT"
        printf 'ssh_port=%s\n' "$SSH_PORT"
        printf 'le_http_port=%s\n' "$LE_HTTP_PORT"
        printf 'csqtt_iface=%s\n' "$CSQTT_IFACE"
        printf 'panel_mode=%s\n' "${PANEL_MODE:-}"
    } > "$archive/network.conf" 2>/dev/null || return 1
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$archive/iptables.rules" 2>/dev/null || rm -f -- "$archive/iptables.rules"
    fi
    if command -v nft >/dev/null 2>&1; then
        nft list ruleset > "$archive/nft.rules" 2>/dev/null || rm -f -- "$archive/nft.rules"
    fi
    return 0
}

# Прежний Docker-образ: ID и тег. Используется rollback'ом, если кандидат так и
# не прошёл health-check. Источник правды — запущенный контейнер: тег
# $CSQTT_DOCKER_IMAGE к моменту снимка уже может указывать на новую версию
# (update), а локально её может не быть вовсе.
capture_docker_image_snapshot() {
    local archive="$1" container_image=""
    DOCKER_PREVIOUS_IMAGE_TAG=""
    DOCKER_PREVIOUS_IMAGE_ID=""
    command -v docker >/dev/null 2>&1 || return 0
    if docker inspect "$CSQTT_DOCKER_CONTAINER" >/dev/null 2>&1; then
        DOCKER_PREVIOUS_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$CSQTT_DOCKER_CONTAINER" 2>/dev/null || true)"
        container_image="$(docker inspect --format '{{.Config.Image}}' "$CSQTT_DOCKER_CONTAINER" 2>/dev/null || true)"
        if [ -n "$container_image" ]; then
            DOCKER_PREVIOUS_IMAGE_TAG="$container_image"
        fi
    fi
    if [ -z "$DOCKER_PREVIOUS_IMAGE_ID" ]; then
        DOCKER_PREVIOUS_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$CSQTT_DOCKER_IMAGE" 2>/dev/null || true)"
    fi
    [ -n "$DOCKER_PREVIOUS_IMAGE_TAG" ] || DOCKER_PREVIOUS_IMAGE_TAG="$CSQTT_DOCKER_IMAGE"
    {
        printf 'tag=%s\n' "$DOCKER_PREVIOUS_IMAGE_TAG"
        printf 'id=%s\n' "$DOCKER_PREVIOUS_IMAGE_ID"
    } > "$archive/docker-image.conf" 2>/dev/null || true
}

# Копия runtime-состояния перед разрушительным шагом. Порядок жёсткий:
# остановить runtime → скопировать. На stdout печатается только путь архива:
# его читают вызывающая сторона и тесты.
snapshot_runtime() {
    local stamp archive src base
    local -a candidates=()
    stamp="$(date +%Y%m%d-%H%M%S)"
    archive="${CSQTT_RUNTIME_ARCHIVE_DIR}/${stamp}"
    mkdir -p -- "$archive" || die "Не удалось создать каталог снимка runtime: $archive"
    chmod 700 -- "$CSQTT_RUNTIME_ARCHIVE_DIR" "$archive" || die "Не удалось защитить каталог снимка runtime: $archive"

    RUNTIME_SNAPSHOT_DIR="$archive"
    RUNTIME_SNAPSHOT_MODE="$(detect_existing_install 2>/dev/null || printf 'fresh')"
    RUNTIME_SNAPSHOT_HAS_PREVIOUS=0
    DOCKER_PREVIOUS_IMAGE_ID=""
    DOCKER_PREVIOUS_IMAGE_TAG=""

    stop_runtime_for_snapshot >&2

    : > "$archive/manifest.tsv" || die "Не удалось подготовить снимок runtime: $archive"

    candidates=(
        "${CSQTT_CONFIG_DIR}/${CSQTT_DATABASE_FILE}"
        "${CSQTT_CONFIG_DIR}/${CSQTT_DATABASE_WAL_FILE}"
        "${CSQTT_CONFIG_DIR}/${CSQTT_DATABASE_SHM_FILE}"
        "$CSQTT_ENV_FILE"
        "$CSQTT_INSTALL_STATE_FILE"
        "${CSQTT_CONFIG_DIR}/web_cert.pem"
        "${CSQTT_CONFIG_DIR}/web_key.pem"
        "${CSQTT_LIB_DIR}/network-up.sh"
        "${CSQTT_LIB_DIR}/tun-recover.sh"
        "$CSQTT_DOCKER_PREREQ_HELPER"
        "$CSQTT_LE_RENEW_HELPER"
    )
    shopt -s nullglob dotglob
    for src in \
        "${CSQTT_CONFIG_DIR}"/csqtt.db.pre-owner-migration* \
        "${CSQTT_CONFIG_DIR}"/passwords.json* \
        "${CSQTT_CONFIG_DIR}"/letsencrypt*.env \
        "${CSQTT_SYSTEMD_DIR}"/csqtt*.service \
        "${CSQTT_SYSTEMD_DIR}"/csqtt*.timer; do
        candidates+=("$src")
    done
    for src in "${candidates[@]}"; do
        [ -e "$src" ] || continue
        base="${src##*/}"
        cp -a -- "$src" "$archive/" || die "Не удалось сохранить $src в снимок runtime"
        printf '%s\t%s\n' "$src" "$base" >> "$archive/manifest.tsv" || \
            die "Не удалось записать манифест снимка runtime"
    done
    shopt -u nullglob dotglob

    if [ -f "${CSQTT_BIN_DIR}/csqtt" ]; then
        cp -a -- "${CSQTT_BIN_DIR}/csqtt" "${CSQTT_BIN_DIR}/csqtt.previous" || \
            die "Не удалось сохранить предыдущий бинарник csqtt"
        RUNTIME_SNAPSHOT_HAS_PREVIOUS=1
    fi
    capture_docker_image_snapshot "$archive" >&2
    capture_network_snapshot "$archive" || log_warn "Не удалось сохранить параметры сети в снимок runtime" >&2

    prune_runtime_archive
    printf '%s\n' "$archive"
}

# --- rollback helpers ------------------------------------------------------

# Останавливает кандидата, не прикасаясь к прежним файлам. Снимаются только
# контейнеры: образ кандидата может быть единственной локальной ссылкой на
# рабочий слой, и `docker image rm` здесь сделал бы откат невосстановимым.
stop_candidate_runtime_for_rollback() {
    local container
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop csqtt >/dev/null 2>&1 || true
        systemctl stop "$CSQTT_DOCKER_PREREQ_SERVICE" >/dev/null 2>&1 || true
    fi
    command -v docker >/dev/null 2>&1 || return 0
    if docker inspect "$CSQTT_DOCKER_CONTAINER" >/dev/null 2>&1; then
        docker update --restart=no "$CSQTT_DOCKER_CONTAINER" >/dev/null 2>&1 || true
        docker rm -f "$CSQTT_DOCKER_CONTAINER" >/dev/null 2>&1 || true
    fi
    while IFS= read -r container; do
        [ -n "$container" ] || continue
        docker_container_runs_csqtt "$container" || continue
        docker update --restart=no "$container" >/dev/null 2>&1 || true
        docker rm -f "$container" >/dev/null 2>&1 || true
    done < <(docker ps -aq --no-trunc 2>/dev/null || true)
}

# Снимок мог быть снят без части файлов (их не было до установки). Восстановление
# обязано вернуть именно то состояние, а не «старое + хвосты кандидата»: иначе
# stale WAL кандидата доиграется поверх восстановленной БД.
restore_runtime_snapshot_files() {
    local archive="$1" src base file
    local -a db_files=(
        "$CSQTT_DATABASE_FILE"
        "$CSQTT_DATABASE_WAL_FILE"
        "$CSQTT_DATABASE_SHM_FILE"
        "csqtt.db.pre-owner-migration"
        "csqtt.db.pre-owner-migration-wal"
        "csqtt.db.pre-owner-migration-shm"
        "letsencrypt.env"
    )
    [ -f "$archive/manifest.tsv" ] || return 1
    while IFS=$'\t' read -r src base; do
        [ -n "$src" ] || continue
        [ -e "$archive/$base" ] || continue
        mkdir -p -- "$(dirname -- "$src")" 2>/dev/null || return 1
        cp -a -- "$archive/$base" "$src" 2>/dev/null || return 1
    done < "$archive/manifest.tsv"

    for file in "${db_files[@]}"; do
        [ -e "$archive/$file" ] && continue
        rm -f -- "${CSQTT_CONFIG_DIR}/${file}" 2>/dev/null || true
    done

    if [ -d "$CSQTT_SYSTEMD_DIR" ] && [ -f "${CSQTT_SYSTEMD_DIR}/csqtt.service" ]; then
        mkdir -p "${CSQTT_SYSTEMD_DIR}/multi-user.target.wants" 2>/dev/null || true
        ln -sfn "${CSQTT_SYSTEMD_DIR}/csqtt.service" \
            "${CSQTT_SYSTEMD_DIR}/multi-user.target.wants/csqtt.service" 2>/dev/null || true
    fi
    # Docker prereq подключается к docker.service через RequiredBy; csqtt_cleanup
    # эти ссылки снимает, поэтому откат обязан вернуть и их, иначе после reboot
    # TUN/xtables lock не будут готовы до старта контейнера.
    if [ -d "$CSQTT_SYSTEMD_DIR" ] && [ -f "${CSQTT_SYSTEMD_DIR}/${CSQTT_DOCKER_PREREQ_SERVICE}" ]; then
        mkdir -p "${CSQTT_SYSTEMD_DIR}/docker.service.requires" 2>/dev/null || true
        ln -sfn "${CSQTT_SYSTEMD_DIR}/${CSQTT_DOCKER_PREREQ_SERVICE}" \
            "${CSQTT_SYSTEMD_DIR}/docker.service.requires/${CSQTT_DOCKER_PREREQ_SERVICE}" 2>/dev/null || true
    fi
    return 0
}

# Правила firewall восстанавливаются из параметров снимка: setup_nat_and_firewall
# зовёт die, а внутри отката это запрещено. Если удалось снять полный дамп —
# сначала он, затем идемпотентная досборка (правила могли не сохраниться).
restore_network_rules_from_snapshot() {
    local archive="$1" iface="" peer="" web="" le="" ssh="" iface_name=""
    local -a targs=()
    [ -n "$archive" ] && [ -d "$archive" ] || return 0

    if [ -f "$archive/network.conf" ]; then
        while IFS='=' read -r src base; do
            case "$src" in
                wan_iface) iface="$base" ;;
                peer_port) peer="$base" ;;
                web_port) web="$base" ;;
                ssh_port) ssh="$base" ;;
                le_http_port) le="$base" ;;
                csqtt_iface) iface_name="$base" ;;
            esac
        done < "$archive/network.conf"
    fi
    [ -n "$peer" ] || peer="$PEER_PORT"
    [ -n "$web" ] || web="$WEB_PORT"
    [ -n "$le" ] || le="$LE_HTTP_PORT"
    [ -n "$ssh" ] || ssh="$SSH_PORT"
    [ -n "$iface_name" ] || iface_name="$CSQTT_IFACE"
    [ -n "$iface" ] || iface="$(detect_wan_interface 2>/dev/null || true)"

    local iptables_restored=0
    if [ -s "$archive/iptables.rules" ] && command -v iptables-restore >/dev/null 2>&1; then
        if iptables-restore < "$archive/iptables.rules" >>"$LOG_FILE" 2>&1; then
            iptables_restored=1
        else
            log_warn "iptables-restore из снимка завершился ошибкой" >&2
        fi
    fi
    # nft -f трогает те же таблицы, что iptables-nft. Если iptables-путь уже
    # восстановил правила, второй проход пересоздаёт таблицы как native nft и
    # ломает iptables-nft («table `filter' is incompatible»). Поэтому nft —
    # только когда iptables-снимка нет или restore не удался.
    if [ "$iptables_restored" -eq 0 ] && [ -s "$archive/nft.rules" ] && command -v nft >/dev/null 2>&1; then
        nft -f "$archive/nft.rules" >>"$LOG_FILE" 2>&1 || \
            log_warn "nft -f из снимка завершился ошибкой" >&2
    fi
    if [ "$iptables_restored" -eq 1 ]; then
        local expected_rules restored_rules
        expected_rules="$(grep -c CSQTT_MANAGED "$archive/iptables.rules" 2>/dev/null || true)"
        if [ "${expected_rules:-0}" -gt 0 ]; then
            restored_rules="$({ iptables -S 2>/dev/null; iptables -t nat -S 2>/dev/null; } | grep -c CSQTT_MANAGED || true)"
            [ "${restored_rules:-0}" -gt 0 ] || \
                log_warn "правила CSQTT не видны после iptables-restore; проверьте backend iptables" >&2
        fi
    fi

    command -v iptables >/dev/null 2>&1 || return 0
    rollback_ensure_rule() {
        local table="$1" chain="$2" pos="$3"
        shift 3
        targs=()
        [ "$table" = "filter" ] || targs=(-t "$table")
        iptables -w "$XT_WAIT" "${targs[@]}" -C "$chain" "$@" >/dev/null 2>&1 && return 0
        iptables -w "$XT_WAIT" "${targs[@]}" -I "$chain" "$pos" "$@" >>"$LOG_FILE" 2>&1 || true
    }
    rollback_ensure_rule filter INPUT 1 -p udp --dport "$peer" -m comment --comment "$IPT_COMMENT" -j ACCEPT
    rollback_ensure_rule filter INPUT 1 -p tcp --dport "$web" -m comment --comment "$IPT_COMMENT" -j ACCEPT
    rollback_ensure_rule filter INPUT 1 -p tcp --dport "$le" -m comment --comment "$IPT_COMMENT" -j ACCEPT
    rollback_ensure_rule filter INPUT 1 -p tcp --dport "$ssh" -m comment --comment "$IPT_COMMENT" -j ACCEPT
    rollback_ensure_rule filter INPUT 1 -i "$iface_name" -s "10.66.67.0/24" -m comment --comment "$IPT_COMMENT" -j ACCEPT
    rollback_ensure_rule filter FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    rollback_ensure_rule filter FORWARD 1 -i "$iface_name" -m comment --comment "$IPT_COMMENT" -j ACCEPT
    rollback_ensure_rule filter FORWARD 1 -o "$iface_name" -m comment --comment "$IPT_COMMENT" -j ACCEPT
    if [ -n "$iface" ]; then
        rollback_ensure_rule nat POSTROUTING 1 -s "10.66.67.0/24" -o "$iface" \
            -m comment --comment "$IPT_COMMENT" -j MASQUERADE
    fi
    rollback_ensure_rule nat POSTROUTING 1 -s "10.66.67.0/24" ! -o "$iface_name" \
        -m comment --comment "$IPT_COMMENT" -j MASQUERADE
    rollback_ensure_rule mangle FORWARD 1 -s "10.66.67.0/24" -p tcp -m tcp \
        --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu
    rollback_ensure_rule mangle FORWARD 1 -d "10.66.67.0/24" -p tcp -m tcp \
        --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu
    unset -f rollback_ensure_rule
    return 0
}

restore_letsencrypt_timer_after_rollback() {
    command -v systemctl >/dev/null 2>&1 || return 0
    [ -f "${CSQTT_SYSTEMD_DIR}/${CSQTT_LE_TIMER}" ] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
    if ! systemctl enable --now "$CSQTT_LE_TIMER" >/dev/null 2>&1; then
        systemctl start "$CSQTT_LE_TIMER" >/dev/null 2>&1 || \
            log_warn "Не удалось перезапустить $CSQTT_LE_TIMER после отката" >&2
    fi
}

run_restored_docker_container() {
    build_docker_env_args
    docker run -d \
        --name "$CSQTT_DOCKER_CONTAINER" \
        --label com.csqtt.managed=true \
        --label com.csqtt.component=server \
        --restart unless-stopped \
        --network host \
        --cap-drop ALL \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        --cap-add NET_BIND_SERVICE \
        --device /dev/net/tun:/dev/net/tun \
        --security-opt seccomp=unconfined \
        --stop-timeout 5 \
        --ulimit nofile=65535:65535 \
        ${DOCKER_ENV_ARGS[@]+"${DOCKER_ENV_ARGS[@]}"} \
        --env CSQTT_SERVICE_MANAGER=docker \
        --volume "$CSQTT_CONFIG_DIR:$CSQTT_CONFIG_DIR" \
        --mount "type=bind,src=${CSQTT_RUNTIME_DIR},dst=${CSQTT_RUNTIME_DIR}" \
        --mount "type=bind,src=/run/xtables.lock,dst=/run/xtables.lock" \
        "${DOCKER_PREVIOUS_IMAGE_ID:-${DOCKER_PREVIOUS_IMAGE_TAG:-$CSQTT_DOCKER_IMAGE}}" \
        --listen "0.0.0.0:${PEER_PORT}" \
        --web-port "$WEB_PORT" \
        --config-dir "$CSQTT_CONFIG_DIR" >>"$LOG_FILE" 2>&1
}

runtime_tun_is_up() {
    command -v ip >/dev/null 2>&1 || return 0
    ip link show "$CSQTT_IFACE" >/dev/null 2>&1
}

restore_runtime_health_check() {
    local attempt=0
    # Окно как у штатного start_csqtt: PID/контейнер сам по себе не доказывает,
    # что TUN поднялся; без него VPN лежит, а «rolled back» был бы ложью.
    while [ "$attempt" -lt 48 ]; do
        attempt=$((attempt + 1))
        case "${RUNTIME_SNAPSHOT_MODE:-}" in
            docker)
                if command -v docker >/dev/null 2>&1 && \
                   [ "$(docker inspect --format '{{.State.Running}}' "$CSQTT_DOCKER_CONTAINER" 2>/dev/null || printf false)" = "true" ] && \
                   runtime_tun_is_up; then
                    return 0
                fi
                ;;
            *)
                if command -v systemctl >/dev/null 2>&1 && \
                   systemctl is-active --quiet csqtt && \
                   runtime_tun_is_up; then
                    return 0
                fi
                ;;
        esac
        sleep 0.25
    done
    return 1
}

start_restored_runtime() {
    local unit
    case "${RUNTIME_SNAPSHOT_MODE:-}" in
        docker)
            command -v docker >/dev/null 2>&1 || return 1
            if ! docker inspect "$CSQTT_DOCKER_CONTAINER" >/dev/null 2>&1; then
                # Запуск идёт по ID снимка: тег мог быть перевешен на кандидата
                # или отсутствовать локально, а ID остаётся валидным.
                run_restored_docker_container || return 1
            fi
            return 0
            ;;
        systemd)
            command -v systemctl >/dev/null 2>&1 || return 1
            systemctl daemon-reload >/dev/null 2>&1 || true
            while IFS= read -r unit; do
                [ -n "$unit" ] || continue
                systemctl start "$unit" >/dev/null 2>&1 || return 1
            done <<< "$RUNTIME_STOPPED_UNITS"
            if [ -z "$RUNTIME_STOPPED_UNITS" ] && [ -f "${CSQTT_SYSTEMD_DIR}/csqtt.service" ]; then
                systemctl start csqtt >/dev/null 2>&1 || return 1
            fi
            return 0
            ;;
    esac
    # fresh: до установки runtime не было, восстанавливать нечего.
    return 0
}

# Последовательность spec §8: остановить кандидата → снять TUN → файлы/бинарник →
# NAT/firewall → LE-таймер → служба/контейнер → health-check. Любой шаг, без
# которого восстановленный runtime не поднимется, считается провалом отката.
perform_rollback() {
    local archive="${RUNTIME_SNAPSHOT_DIR:-}"
    if [ -z "$archive" ] || [ ! -d "$archive" ] || [ ! -f "$archive/manifest.tsv" ]; then
        log_error "Снимок runtime для отката не найден" >&2
        return 1
    fi
    stop_candidate_runtime_for_rollback

    # Кандидат мог создать TUN; старый helper создаст его заново при старте.
    if command -v ip >/dev/null 2>&1; then
        timeout 2 ip link del "$CSQTT_IFACE" >/dev/null 2>&1 || true
    fi

    restore_runtime_snapshot_files "$archive" || {
        log_error "Не удалось восстановить файлы из снимка runtime" >&2
        return 1
    }

    if [ "${RUNTIME_SNAPSHOT_HAS_PREVIOUS:-0}" = "1" ] && [ -f "${CSQTT_BIN_DIR}/csqtt.previous" ]; then
        install -m 0755 "${CSQTT_BIN_DIR}/csqtt.previous" "${CSQTT_BIN_DIR}/csqtt" || {
            log_error "Не удалось восстановить предыдущий бинарник csqtt" >&2
            return 1
        }
    else
        # До установки бинарника не было — кандидат не имеет права остаться.
        rm -f -- "${CSQTT_BIN_DIR}/csqtt" 2>/dev/null || true
    fi

    restore_network_rules_from_snapshot "$archive"
    restore_letsencrypt_timer_after_rollback

    # Остановленный в snapshot runtime нужно вернуть; fresh откатывать нечего.
    case "${RUNTIME_SNAPSHOT_MODE:-}" in
        systemd|docker)
            start_restored_runtime || {
                log_error "Не удалось запустить восстановленный runtime CSQTT" >&2
                return 1
            }
            restore_runtime_health_check || {
                log_error "Восстановленный runtime CSQTT не прошёл health-check" >&2
                return 1
            }
            ;;
    esac
    RUNTIME_STOPPED=0
    return 0
}

remove_managed_work_dir() {
    local path="$1"
    case "$path" in
        /tmp/csqtt-docker.*)
            rm -rf -- "$path"
            ;;
        "")
            ;;
        *)
            log_warn "Отказ от удаления неожиданного временного пути: $path"
            return 1
            ;;
    esac
}

cleanup_deploy_artifacts() {
    local docker_context="$DOCKER_CONTEXT_DIR"
    DOCKER_CONTEXT_DIR=""
    remove_managed_work_dir "$docker_context" || true
    if command -v docker >/dev/null 2>&1 && [ -n "$CSQTT_DOCKER_CANDIDATE_IMAGE" ]; then
        docker image rm "$CSQTT_DOCKER_CANDIDATE_IMAGE" >/dev/null 2>&1 || true
        CSQTT_DOCKER_CANDIDATE_IMAGE=""
    fi
    CANDIDATE_BINARY=""
    CANDIDATE_ENV_FILE=""
}

# ---------------------------------------------------------------------------
# Загрузка релиза, проверка checksum и источник CLI
# ---------------------------------------------------------------------------

# Удаляет только тот каталог, который создал сам установщик. Каталог,
# переданный тестами через CSQTT_WORK_DIR, не трогается.
cleanup_installer_work_dir() {
    if [ "${CSQTT_WORK_DIR_OWNED:-0}" = "1" ] && [ -n "${CSQTT_WORK_DIR:-}" ]; then
        rm -rf -- "$CSQTT_WORK_DIR"
    fi
    CSQTT_WORK_DIR_OWNED=0
    CSQTT_WORK_DIR=""
}

ensure_installer_work_dir() {
    if [ -n "${CSQTT_WORK_DIR:-}" ]; then
        mkdir -p -- "$CSQTT_WORK_DIR" || die "Не удалось подготовить временный каталог: $CSQTT_WORK_DIR"
        chmod 700 -- "$CSQTT_WORK_DIR" || die "Не удалось защитить временный каталог: $CSQTT_WORK_DIR"
        return 0
    fi
    CSQTT_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/csqtt-install.XXXXXX")" || \
        die "Не удалось создать временный каталог установщика" "$EXIT_PREFLIGHT_FAILED"
    CSQTT_WORK_DIR_OWNED=1
    chmod 700 -- "$CSQTT_WORK_DIR" || \
        die "Не удалось защитить временный каталог установщика" "$EXIT_PREFLIGHT_FAILED"
}

# Проверка схемы идёт до curl: http://, file:// и произвольные URL не должны
# даже попадать в загрузчик.
assert_https_url() {
    local url="$1"
    case "$url" in
        https://*) ;;
        *) die "Загрузка разрешена только по HTTPS, получено: $url" "$EXIT_PREFLIGHT_FAILED" ;;
    esac
}

validate_release_tag() {
    local tag="$1"
    if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Некорректный тег релиза: '$tag' (ожидается vX.Y.Z)" "$EXIT_PREFLIGHT_FAILED"
    fi
}

# Печатает тег и сохраняет его в RELEASE_TAG. Источник — redirect
# releases/latest на GitHub (без GitHub API).
resolve_release_tag() {
    DEPLOY_PHASE="preflight"
    local base tag="" effective=""
    base="${CSQTT_RELEASE_BASE}"
    assert_https_url "${base}/releases/latest"
    effective="$(curl -sIL --fail --proto '=https' --tlsv1.2 --retry 3 \
        -o /dev/null -w '%{url_effective}' "${base}/releases/latest" 2>/dev/null || true)"
    case "$effective" in
        */tag/*) tag="${effective##*/tag/}" ;;
        *) tag="" ;;
    esac
    tag="${tag%%[?#]*}"
    tag="${tag%/}"
    validate_release_tag "$tag"
    RELEASE_TAG="$tag"
    printf '%s\n' "$tag"
}

# <base>/releases/download/<tag>/<name>; RELEASE_TAG выставляет
# resolve_release_tag или prepare_installer_source.
download_release_asset() {
    local name="$1" dest="$2" base url
    DEPLOY_PHASE="preflight"
    [ -n "$name" ] && [ -n "$dest" ] || \
        die "download_release_asset требует имя ассета и путь назначения" "$EXIT_PREFLIGHT_FAILED"
    [ -n "${RELEASE_TAG:-}" ] || \
        die "Тег релиза не определён; вызовите resolve_release_tag" "$EXIT_PREFLIGHT_FAILED"
    base="${CSQTT_RELEASE_BASE}"
    url="${base}/releases/download/${RELEASE_TAG}/${name}"
    assert_https_url "$url"
    mkdir -p -- "$(dirname -- "$dest")" || \
        die "Не удалось подготовить каталог загрузки: $(dirname -- "$dest")" "$EXIT_PREFLIGHT_FAILED"
    if ! curl -fsSL --proto '=https' --tlsv1.2 --fail --location --retry 3 \
        -o "$dest" "$url"; then
        die "Не удалось скачать ${name} из релиза ${RELEASE_TAG}" "$EXIT_PREFLIGHT_FAILED"
    fi
    [ -s "$dest" ] || die "Скачанный ${name} пуст (${RELEASE_TAG})" "$EXIT_PREFLIGHT_FAILED"
}

# Строка SHA256SUMS — "<hex>  <basename>" либо "<hex> *<basename>". Сравнение
# точное по basename, а не по всему пути: файл лежит в work-dir.
verify_sha256() {
    local file="$1" sums="$2" base expected actual
    DEPLOY_PHASE="preflight"
    [ -f "$file" ] || die "Файл для проверки не найден: $file" "$EXIT_PREFLIGHT_FAILED"
    [ -f "$sums" ] || die "Файл SHA256SUMS не найден: $sums" "$EXIT_PREFLIGHT_FAILED"
    base="${file##*/}"
    expected="$(awk -v name="$base" '$2 == name || $2 == "*" name { print $1; exit }' "$sums")"
    [ -n "$expected" ] || \
        die "В SHA256SUMS нет записи для ${base}" "$EXIT_PREFLIGHT_FAILED"
    if ! [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
        die "В SHA256SUMS некорректный SHA-256 для ${base}: $expected" "$EXIT_PREFLIGHT_FAILED"
    fi
    actual="$(sha256sum -- "$file" | awk '{print $1}')"
    [ "${actual,,}" = "${expected,,}" ] || \
        die "Несовпадение SHA-256 для ${base}: ожидалось ${expected}, получено ${actual}" "$EXIT_PREFLIGHT_FAILED"
}

# Скачивает install.sh и SHA256SUMS указанного тега, проверяет checksum и
# выставляет CSQTT_INSTALLER_SOURCE. Это единственный допустимый источник для
# CLI и re-exec: $0/BASH_SOURCE[0] при `bash <(curl ...)` указывает на /dev/fd,
# stdin — на pipes.
prepare_installer_source() {
    local tag="$1" source sums
    DEPLOY_PHASE="preflight"
    [ -n "$tag" ] || die "prepare_installer_source требует тег релиза" "$EXIT_PREFLIGHT_FAILED"
    validate_release_tag "$tag"
    RELEASE_TAG="$tag"
    ensure_installer_work_dir
    source="${CSQTT_WORK_DIR}/install.sh"
    sums="${CSQTT_WORK_DIR}/SHA256SUMS"
    download_release_asset "install.sh" "$source"
    download_release_asset "SHA256SUMS" "$sums"
    verify_sha256 "$source" "$sums"
    chmod 0755 -- "$source" || \
        die "Не удалось сделать скачанный install.sh исполняемым" "$EXIT_PREFLIGHT_FAILED"
    CSQTT_INSTALLER_SOURCE="$source"
    printf '%s\n' "$CSQTT_INSTALLER_SOURCE"
}

# Ставит только скачанный и проверенный install.sh. Если источника нет
# (--binary/--check или сбой загрузки), CLI не устанавливается, но установка
# не ломается. Файл активируется temp+mv, симлинк — тоже через временный
# линк и mv: повторный update заменяет обе точки, не оставляя копий.
install_cli() {
    local source="${CSQTT_INSTALLER_SOURCE:-}" target tmp link link_tmp
    if [ -z "$source" ]; then
        log_warn "CLI не установлен: скачанный и проверенный install.sh не подготовлен (--binary/--check)"
        return 0
    fi
    [ -f "$source" ] || die "Источник CLI исчез: $source" "$EXIT_PREFLIGHT_FAILED"
    mkdir -p -- "$CSQTT_CLI_DIR" "$CSQTT_BIN_DIR" || \
        die "Не удалось создать каталог CLI: $CSQTT_CLI_DIR" "$EXIT_PREFLIGHT_FAILED"
    tmp="$(mktemp "${CSQTT_CLI_DIR}/.install.sh.XXXXXX")" || \
        die "Не удалось создать временный файл CLI" "$EXIT_PREFLIGHT_FAILED"
    if ! cp -- "$source" "$tmp"; then
        rm -f -- "$tmp"
        die "Не удалось скопировать CLI из $source" "$EXIT_PREFLIGHT_FAILED"
    fi
    if ! chmod 0755 -- "$tmp"; then
        rm -f -- "$tmp"
        die "Не удалось выставить права CLI" "$EXIT_PREFLIGHT_FAILED"
    fi
    target="${CSQTT_CLI_DIR}/install.sh"
    if ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        die "Не удалось активировать CLI: $target" "$EXIT_PREFLIGHT_FAILED"
    fi
    link="${CSQTT_BIN_DIR}/csqttctl"
    link_tmp="${CSQTT_BIN_DIR}/.csqttctl.$$"
    rm -f -- "$link_tmp"
    if ! ln -s -- "$target" "$link_tmp"; then
        rm -f -- "$link_tmp"
        die "Не удалось создать симлинк CLI: $link" "$EXIT_PREFLIGHT_FAILED"
    fi
    if ! mv -fT -- "$link_tmp" "$link"; then
        rm -f -- "$link_tmp"
        die "Не удалось активировать симлинк CLI: $link" "$EXIT_PREFLIGHT_FAILED"
    fi
    log_info "CLI установлен: $target (csqttctl → $link)"
}

# CLI — не runtime: снимается и обычным uninstall. Каталог удаляется только
# если опустел: туда не кладут ничего, кроме единственного install.sh.
remove_cli_installation() {
    rm -f -- "${CSQTT_CLI_DIR}/install.sh"
    rm -f -- "${CSQTT_BIN_DIR}/csqttctl"
    rmdir -- "$CSQTT_CLI_DIR" 2>/dev/null || true
}

# Перед exec закрывает lock-fd: flock наследуется через open file description,
# и без закрытия следующий экземпляр не сможет взять свой же lock.
maybe_reexec_version() {
    local tag="${1:-${VERSION_OVERRIDE:-}}" source argument skip=0
    local -a argv=()
    [ -n "${VERSION_OVERRIDE:-}" ] || return 0
    [ "$VERSION_OVERRIDE" != "$SCRIPT_VERSION" ] || return 0
    if [ -n "${BINARY_PATH:-}" ]; then
        log_info "Локальный --binary: re-exec на ${VERSION_OVERRIDE} не выполняется"
        return 0
    fi
    if [ "${CSQTT_UPDATE_REEXEC:-0}" = "1" ]; then
        log_info "Re-exec уже выполнялся (CSQTT_UPDATE_REEXEC=1); повторный запуск пропущен"
        return 0
    fi
    source="${CSQTT_INSTALLER_SOURCE:-}"
    [ -n "$source" ] || \
        die "Для версии ${VERSION_OVERRIDE} нужен скачанный install.sh, но источник не подготовлен" "$EXIT_PREFLIGHT_FAILED"
    [ -f "$source" ] || die "Источник re-exec исчез: $source" "$EXIT_PREFLIGHT_FAILED"
    # Закрываем lock-fd безусловно: `exec 9>&-` на незакрытом дескрипторе
    # завершается успешно, а проверка /proc/$$ ломается в subshell ($$ — PID
    # родителя, а fd открыт в текущей подоболочке).
    eval "exec ${CSQTT_INSTALL_LOCK_FD}>&-"
    log_info "Переключение установщика на версию ${tag:-$VERSION_OVERRIDE}"
    CSQTT_UPDATE_REEXEC=1
    export CSQTT_UPDATE_REEXEC
    # Если work-dir создан установщиком, новый процесс должен удалить его сам:
    # EXIT-trap при exec не выполняется. Тестовый (внешний) каталог не трогаем.
    if [ "${CSQTT_WORK_DIR_OWNED:-0}" = "1" ]; then
        export CSQTT_WORK_DIR CSQTT_WORK_DIR_OWNED
    fi
    # Пароль панели не попадает в argv: он передаётся окружением, а новый
    # процесс читает CSQTT_WEB_PASS в parse_cli. --web-pass-stdin при этом
    # снимается из argv: stdin после exec уже не тот, из которого его читали.
    # Только явный пароль: сохранённый на update не должен стать «explicit» в
    # ребёнке и включить перезапись csqtt.env (байт-в-байт сохранение).
    if [ "${WEB_PASS_EXPLICIT:-0}" -eq 1 ] && [ -n "${WEB_PASS:-}" ]; then
        export CSQTT_WEB_PASS="$WEB_PASS"
    fi

    # Исходный argv переносится целиком, затем добавляются разрешённые значения:
    # интерактивные ответы (host, порты) уже получены в этом процессе, и без них
    # новый установщик спросил бы заново или взял дефолты. Последний --version
    # и --yes выигрывают у исходного argv.
    for argument in "${INSTALLER_ARGV[@]}"; do
        if [ "$skip" -eq 1 ]; then
            skip=0
            continue
        fi
        case "$argument" in
            --web-pass-stdin) continue ;;
            --version) skip=1 ;;
        esac
        argv+=("$argument")
    done
    if [ -n "${PANEL_HOST:-}" ]; then
        argv+=(--host "$PANEL_HOST")
    fi
    if [ -n "${PEER_PORT:-}" ]; then
        argv+=(--peer-port "$PEER_PORT")
    fi
    if [ -n "${WEB_PORT:-}" ]; then
        argv+=(--web-port "$WEB_PORT")
    fi
    if [ -n "${SSH_PORT:-}" ]; then
        argv+=(--ssh-port "$SSH_PORT")
    fi
    # Только явные флаги: иначе ребёнок получит *_EXPLICIT=1 и перезапишет
    # csqtt.env на update, ломая байт-в-байт сохранение.
    if [ "${WEB_USER_EXPLICIT:-0}" -eq 1 ] && [ -n "${WEB_USER:-}" ]; then
        argv+=(--web-user "$WEB_USER")
    fi
    if [ "${SECRET_PATH_EXPLICIT:-0}" -eq 1 ] && [ -n "${SECRET_PATH:-}" ]; then
        argv+=(--secret-path "$SECRET_PATH")
    fi
    if [ "${DEPLOY_MODE_EXPLICIT:-0}" -eq 1 ]; then
        argv+=(--mode "$DEPLOY_MODE")
    fi
    if [ "${RECONFIGURE:-0}" -eq 1 ]; then
        argv+=(--reconfigure)
    fi
    if [ "${FORCE:-0}" -eq 1 ]; then
        argv+=(--force)
    fi
    argv+=(--version "$VERSION_OVERRIDE" --yes)
    exec bash "$source" "${argv[@]}"
}

# flock -n на /run/csqtt-install.lock. Второй экземпляр получает exit 2, а не
# ждёт первого. При CSQTT_UPDATE_REEXEC=1 lock не берётся: старый экземпляр
# уже держал его и exec'нулся в новый процесс.
acquire_install_lock() {
    local lock_dir
    if [ "${CSQTT_UPDATE_REEXEC:-0}" = "1" ]; then
        log_info "Lock не берётся: повторный запуск после update"
        return 0
    fi
    command -v flock >/dev/null 2>&1 || \
        die "Команда flock не найдена; установите util-linux" "$EXIT_INVALID_ARGUMENT"
    lock_dir="$(dirname -- "$CSQTT_INSTALL_LOCK")"
    mkdir -p -- "$lock_dir" || die "Не удалось создать каталог lock: $lock_dir"
    if [ ! -e "$CSQTT_INSTALL_LOCK" ]; then
        ( umask 077; : > "$CSQTT_INSTALL_LOCK" ) || \
            die "Не удалось создать lock-файл: $CSQTT_INSTALL_LOCK"
    fi
    chmod 0600 -- "$CSQTT_INSTALL_LOCK" 2>/dev/null || true
    eval "exec ${CSQTT_INSTALL_LOCK_FD}>\"\$CSQTT_INSTALL_LOCK\""
    if ! flock -n "$CSQTT_INSTALL_LOCK_FD"; then
        die "Другой экземпляр установщика уже работает (lock: $CSQTT_INSTALL_LOCK)" "$EXIT_INVALID_ARGUMENT"
    fi
}

resolve_binary_checksum() {
    local sidecar="${1}.sha256" expected=""
    if [ -n "${BINARY_SHA256:-}" ]; then
        printf '%s\n' "$BINARY_SHA256"
        return 0
    fi
    [ -f "$sidecar" ] || return 1
    expected="$(awk 'NR == 1 { print $1 }' "$sidecar")"
    [ -n "$expected" ] || return 1
    printf '%s\n' "$expected"
}

# --binary не имеет релизного SHA256SUMS, поэтому без checksum установка
# отказывается (exit 2); --allow-unverified-binary делает дыру явной.
validate_binary_options() {
    local expected actual
    [ -n "${BINARY_PATH:-}" ] || return 0
    DEPLOY_PHASE="validation"
    [ -f "$BINARY_PATH" ] || \
        die "Локальный бинарник не найден: $BINARY_PATH" "$EXIT_INVALID_ARGUMENT"
    if ! expected="$(resolve_binary_checksum "$BINARY_PATH")"; then
        if [ "${ALLOW_UNVERIFIED_BINARY:-0}" = "1" ]; then
            log_warn "Локальный бинарник ставится без проверки SHA-256 (--allow-unverified-binary)"
            return 0
        fi
        die "Для --binary нужен checksum: --binary-sha256 или sidecar ${BINARY_PATH}.sha256 (либо --allow-unverified-binary)" \
            "$EXIT_INVALID_ARGUMENT"
    fi
    if ! [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
        die "Некорректный SHA-256 для --binary: $expected" "$EXIT_INVALID_ARGUMENT"
    fi
    actual="$(sha256sum -- "$BINARY_PATH" | awk '{print $1}')"
    if [ "${actual,,}" != "${expected,,}" ]; then
        DEPLOY_PHASE="preflight"
        die "SHA-256 локального бинарника не совпадает: ожидалось ${expected}, получено ${actual}" \
            "$EXIT_PREFLIGHT_FAILED"
    fi
}

validate_candidate_environment() {
    local candidate_env="$1"
    # Кандидат csqtt.env содержит только web-ключи: legacy main_password больше
    # не требуется, owner — обычный клиент панели.
    grep -Eq '^[[:space:]]*(export[[:space:]]+)?CSQTT_WEB_USER=.+$' "$candidate_env" || \
        die "В WEB-конфигурации отсутствует CSQTT_WEB_USER" "$EXIT_PREFLIGHT_FAILED"
    grep -Eq '^[[:space:]]*(export[[:space:]]+)?CSQTT_WEB_PASS=.+$' "$candidate_env" || \
        die "В WEB-конфигурации отсутствует CSQTT_WEB_PASS" "$EXIT_PREFLIGHT_FAILED"
}

# Бинарник проверяется запуском до остановки старого runtime: несовместимый
# кандидат не должен стоить простоя.
verify_candidate_binary() {
    local binary="$1" output=""
    [ -x "$binary" ] || \
        die "Кандидат csqtt не исполняемый (проверьте noexec для ${CSQTT_WORK_DIR})" "$EXIT_PREFLIGHT_FAILED"
    if ! output="$(timeout 15 "$binary" --version 2>&1)"; then
        printf '%s\n' "$output" >>"$LOG_FILE"
        die "Кандидат csqtt не запускается: $(printf '%s' "$output" | head -n 1)" "$EXIT_PREFLIGHT_FAILED"
    fi
    [ -n "$output" ] || die "Кандидат csqtt --version не вернул версию" "$EXIT_PREFLIGHT_FAILED"
    log_info "Кандидат csqtt запускается: $(printf '%s' "$output" | head -n 1)"
}

prepare_binary_candidate() {
    DEPLOY_PHASE="preflight"
    CANDIDATE_BINARY="${CSQTT_WORK_DIR}/csqtt-linux-amd64"
    cp -- "$BINARY_PATH" "$CANDIDATE_BINARY" || \
        die "Не удалось скопировать локальный бинарник в work-dir" "$EXIT_PREFLIGHT_FAILED"
    chmod 0755 "$CANDIDATE_BINARY" || \
        die "Не удалось сделать локальный бинарник исполняемым" "$EXIT_PREFLIGHT_FAILED"
    verify_candidate_binary "$CANDIDATE_BINARY"
    log_info "Локальный бинарник проверен до остановки текущего сервиса"
}

# Скачивает csqtt-linux-amd64 и SHA256SUMS, проверяет checksum и оставляет
# проверенный CANDIDATE_BINARY в work-dir. --binary заменяет загрузку локальным
# файлом, но требует checksum (см. validate_binary_options).
prepare_candidate_release() {
    DEPLOY_PHASE="preflight"
    ensure_installer_work_dir
    CANDIDATE_ENV_FILE="${CSQTT_WORK_DIR}/csqtt.env.candidate"

    if [ -n "${BINARY_PATH:-}" ]; then
        prepare_binary_candidate
        return 0
    fi

    local tag="${VERSION_OVERRIDE:-}" sums
    if [ -z "$tag" ]; then
        tag="$(resolve_release_tag)"
    fi
    validate_release_tag "$tag"
    RELEASE_TAG="$tag"
    CANDIDATE_BINARY="${CSQTT_WORK_DIR}/csqtt-linux-amd64"
    sums="${CSQTT_WORK_DIR}/SHA256SUMS"
    log_step "Загрузка csqtt ${tag}..."
    download_release_asset "csqtt-linux-amd64" "$CANDIDATE_BINARY"
    download_release_asset "SHA256SUMS" "$sums"
    verify_sha256 "$CANDIDATE_BINARY" "$sums"
    chmod 0755 "$CANDIDATE_BINARY" || \
        die "Не удалось сделать кандидат csqtt исполняемым" "$EXIT_PREFLIGHT_FAILED"
    verify_candidate_binary "$CANDIDATE_BINARY"
    log_info "Кандидат csqtt ${tag} скачан и проверен по SHA-256"
}

finish_deployment() {
    local current_image_id=""
    ROLLBACK_ARMED=0
    RUNTIME_STOPPED=0
    # Docker: кандидат жил под собственным тегом до health-check. Только успешная
    # установка делает его основным образом; старый образ до этого не трогался.
    if command -v docker >/dev/null 2>&1 && [ -n "$CSQTT_DOCKER_CANDIDATE_IMAGE" ]; then
        if docker tag "$CSQTT_DOCKER_CANDIDATE_IMAGE" "$CSQTT_DOCKER_IMAGE" >/dev/null 2>&1; then
            docker image rm "$CSQTT_DOCKER_CANDIDATE_IMAGE" >/dev/null 2>&1 || true
        else
            log_warn "Не удалось закрепить проверенный Docker-образ как $CSQTT_DOCKER_IMAGE"
        fi
        CSQTT_DOCKER_CANDIDATE_IMAGE=""
    fi
    if command -v docker >/dev/null 2>&1; then
        # Прежний образ после успешной активации — мусор. Удаляется best-effort и
        # только если это не образ, на который теперь указывает основной тег.
        current_image_id="$(docker image inspect --format '{{.Id}}' "$CSQTT_DOCKER_IMAGE" 2>/dev/null || true)"
        if [ -n "${DOCKER_PREVIOUS_IMAGE_ID:-}" ] && \
           [ "${DOCKER_PREVIOUS_IMAGE_ID}" != "$current_image_id" ]; then
            timeout 10 docker image rm "$DOCKER_PREVIOUS_IMAGE_ID" >/dev/null 2>&1 || true
        fi
    fi
    DOCKER_PREVIOUS_IMAGE_ID=""
    DOCKER_PREVIOUS_IMAGE_TAG=""
    CSQTT_DOCKER_RUN_IMAGE=""
    # csqtt.previous — страховка только на время cutover; после успешной
    # активации восстанавливать из него нечего.
    rm -f -- "${CSQTT_BIN_DIR}/csqtt.previous" 2>/dev/null || true
    cleanup_deploy_artifacts
}

remove_csqtt_tun_interface() {
    local attempt waited=0
    if ! ip link show "$CSQTT_IFACE" >/dev/null 2>&1; then
        return 0
    fi

    log_warn "Обнаружен остаточный TUN-интерфейс $CSQTT_IFACE; выполняется восстановление runtime"
    for attempt in 1 2 3 4; do
        if timeout 2 ip link del "$CSQTT_IFACE" >>"$LOG_FILE" 2>&1; then
            waited=0
            while [ "$waited" -lt 20 ]; do
                if ! ip link show "$CSQTT_IFACE" >/dev/null 2>&1; then
                    log_info "Остаточный TUN-интерфейс $CSQTT_IFACE удалён"
                    return 0
                fi
                sleep 0.1
                waited=$((waited + 1))
            done
        fi
        sleep 0.2
    done

    ip -d link show "$CSQTT_IFACE" 2>&1 | tee -a "$LOG_FILE" >&2 || true
    return 1
}

csqtt_cleanup() {
    prog 0.15 "Очистка..."
    echo "🧹 Переключение со старой установки CSQTT..."

    # Таймер продления живёт рядом с хелпером и переживает снос runtime: старый
    # юнит не попадает в list_csqtt_systemd_units (там только *.service за
    # вычетом LE), а rm -rf "$CSQTT_LIB_DIR" не трогает сам хелпер. Пока идёт
    # переключение, он может выстрелить и сразиться за порт 80 либо потратить
    # выпуск. Останавливаем до любых изменений; включает его обратно
    # install_letsencrypt_renewal_timer в конце установки.
    stop_letsencrypt_renewal_timer

    local had_old_install=0 managed_systemd_unit=0
    if csqtt_systemd_unit_is_managed; then
        managed_systemd_unit=1
    fi
    if [ -e "${CSQTT_BIN_DIR}/csqtt" ] || [ -d "$CSQTT_LIB_DIR" ] || \
       [ "$managed_systemd_unit" -eq 1 ] || csqtt_docker_container_exists || \
       csqtt_persistent_state_exists || ip link show "$CSQTT_IFACE" >/dev/null 2>&1 || \
       csqtt_peer_port_is_owned; then
        had_old_install=1
    fi

    remove_all_csqtt_docker_containers

    if command -v systemctl >/dev/null 2>&1; then
        stop_csqtt_docker_prereq
        stop_all_running_csqtt_systemd_units
    fi

    force_stop_csqtt_processes || die "Не удалось завершить процессы CSQTT"
    remove_all_csqtt_systemd_units
    [ -e "${CSQTT_SYSTEMD_DIR}/${CSQTT_DOCKER_PREREQ_SERVICE}" ] && SYSTEMD_NEEDS_RELOAD=1
    rm -f "${CSQTT_SYSTEMD_DIR}/${CSQTT_DOCKER_PREREQ_SERVICE}"
    rm -f "${CSQTT_SYSTEMD_DIR}/docker.service.requires/${CSQTT_DOCKER_PREREQ_SERVICE}"
    rm -f "${CSQTT_SYSTEMD_DIR}/docker.service.wants/${CSQTT_DOCKER_PREREQ_SERVICE}"
    if [ "$SYSTEMD_NEEDS_RELOAD" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || die "systemctl daemon-reload завершился ошибкой после удаления старого runtime"
        SYSTEMD_NEEDS_RELOAD=0
    fi
    rm -f "${CSQTT_BIN_DIR}/csqtt"
    rm -rf "$CSQTT_LIB_DIR"
    clear_runtime_config_preserving_database

    assert_peer_port_is_available

    remove_csqtt_tun_interface || die "Не удалось освободить TUN-интерфейс $CSQTT_IFACE; переключение отменено"
    if [ "$had_old_install" -eq 1 ]; then
        cleanup_csqtt_netfilter_rules || true
    fi

    echo "✓ Старый runtime удалён; SQLite/state сохранён"
}

setup_sysctl() {
    prog 0.25 "Sysctl..."
    echo "⚙️  Настройка сетевых параметров..."

    modprobe tcp_bbr 2>/dev/null || true
    if [ -d "$CSQTT_MODULES_LOAD_DIR" ]; then
        echo "tcp_bbr" > "${CSQTT_MODULES_LOAD_DIR}/bbr.conf" 2>/dev/null || true
    fi

    echo 1 > "${CSQTT_PROC_SYS_DIR}/net/ipv4/ip_forward" 2>/dev/null || true
    echo 2 > "${CSQTT_PROC_SYS_DIR}/net/ipv4/conf/all/rp_filter" 2>/dev/null || true
    echo 2 > "${CSQTT_PROC_SYS_DIR}/net/ipv4/conf/default/rp_filter" 2>/dev/null || true
    echo 0 > "${CSQTT_PROC_SYS_DIR}/net/ipv6/conf/all/disable_ipv6" 2>/dev/null || true
    echo 0 > "${CSQTT_PROC_SYS_DIR}/net/ipv6/conf/default/disable_ipv6" 2>/dev/null || true
    echo 1 > "${CSQTT_PROC_SYS_DIR}/net/ipv6/conf/all/forwarding" 2>/dev/null || true
    echo 1 > "${CSQTT_PROC_SYS_DIR}/net/ipv6/conf/default/forwarding" 2>/dev/null || true
    echo 2 > "${CSQTT_PROC_SYS_DIR}/net/ipv6/conf/all/accept_ra" 2>/dev/null || true
    echo 2 > "${CSQTT_PROC_SYS_DIR}/net/ipv6/conf/default/accept_ra" 2>/dev/null || true
    for dev in "${CSQTT_PROC_SYS_DIR}/net/ipv6/conf/"*; do
        if [ -d "$dev" ]; then
            echo 0 > "$dev/disable_ipv6" 2>/dev/null || true
            echo 2 > "$dev/accept_ra" 2>/dev/null || true
        fi
    done
    mkdir -p "$CSQTT_SYSCTL_DIR"
    cat > "$CSQTT_SYSCTL_FILE" << 'SYSEOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3
SYSEOF

    cat > "$CSQTT_UDP_SYSCTL_FILE" << 'SYSEOF'
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
SYSEOF

    sysctl -p "$CSQTT_SYSCTL_FILE" >>"$LOG_FILE" 2>&1 || log_warn "Не удалось применить обязательные параметры маршрутизации"
    sysctl -p "$CSQTT_UDP_SYSCTL_FILE" >>"$LOG_FILE" 2>&1 || log_warn "Ядро ограничило лимиты сетевых буферов; сервер продолжит работу с доступными значениями"

    [ "$(cat "${CSQTT_PROC_SYS_DIR}/net/ipv4/ip_forward" 2>/dev/null || echo 0)" = "1" ] || \
        die "IPv4 forwarding невозможно включить на этом VPS"

    echo "✓ Sysctl настроен (IPv4/IPv6 forwarding + BBR + буферы)"
}

tune_cpu_mitigations() {
    if [ -f "$CSQTT_GRUB_FILE" ]; then
        if ! grep -q "mitigations=off" "$CSQTT_GRUB_FILE"; then
            sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)/\1 mitigations=off nowatchdog/' "$CSQTT_GRUB_FILE" 2>/dev/null || true
            update-grub >>"$LOG_FILE" 2>&1 || grub2-mkconfig -o /boot/grub2/grub.cfg >>"$LOG_FILE" 2>&1 || true
            log_info "Оптимизация CPU: mitigations=off добавлено в GRUB"
        fi
    fi
}

setup_nat_and_firewall() {
    prog 0.40 "NAT + Firewall..."
    echo "🛡  Настройка NAT и фаервола..."

    local iface
    iface=$(detect_wan_interface)

    if [ -z "$iface" ]; then
        die "Не удалось определить WAN-интерфейс для NAT подсети 10.66.67.0/24"
    fi
    ip link show "$iface" >/dev/null 2>&1 || die "Определённый WAN-интерфейс $iface не существует"

    log_info "WAN-интерфейс: $iface"
    sysctl -w "net.ipv4.conf.${iface}.rp_filter=2" >>"$LOG_FILE" 2>&1 || true
    sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" >>"$LOG_FILE" 2>&1 || true
    sysctl -w "net.ipv6.conf.${iface}.accept_ra=2" >>"$LOG_FILE" 2>&1 || true
    sysctl -w "net.ipv6.conf.${iface}.forwarding=1" >>"$LOG_FILE" 2>&1 || true
    command -v netplan >/dev/null 2>&1 && netplan apply >>"$LOG_FILE" 2>&1 || true

    local gw_ip
    gw_ip="$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); break}}')"
    if [ -n "$gw_ip" ]; then
        ip route replace "$gw_ip" dev "$iface" scope link >>"$LOG_FILE" 2>&1 || true
    fi

    fw_close_unused_panel_port
    fw_add_input_udp "$PEER_PORT"
    fw_add_input_tcp "$WEB_PORT"
    fw_add_input_tcp "$LE_HTTP_PORT"

    fw_add_forward

    fw_add_masquerade "$iface" "10.66.67.0/24"
    
    fw_add_mss_clamping "10.66.67.0/24"

    echo "✓ NAT: MASQUERADE на $iface для 10.66.67.0/24"
    echo "✓ Порты CSQTT: ${PEER_PORT}/udp(PEER), ${WEB_PORT}/tcp(WEB: $(panel_web_mode_label)), ${LE_HTTP_PORT}/tcp(LE)"
    echo "✓ TCP MSS Clamping включен"
}

write_network_helper() {
    local target="$1" stale_web_port=""
    case "${PANEL_MODE:-}" in
        domain) stale_web_port="46002" ;;
        ip) stale_web_port="443" ;;
    esac
    cat > "$target" << NETEOF
#!/bin/sh
set -eu
    PEER_PORT="$PEER_PORT"
WEB_PORT="$WEB_PORT"
STALE_WEB_PORT="$stale_web_port"
LE_HTTP_PORT="$LE_HTTP_PORT"
CSQTT_IFACE="$CSQTT_IFACE"
IPT_COMMENT="$IPT_COMMENT"
SUBNET="10.66.67.0/24"
SUBNET6="fd66:67::/64"
XT_WAIT="$XT_WAIT"
CSQTT_RUNTIME_DIR="$CSQTT_RUNTIME_DIR"
CSQTT_PROC_SYS_DIR="$CSQTT_PROC_SYS_DIR"
NETWORK_READY_FILE="$CSQTT_DOCKER_NETWORK_READY"

command -v ip >/dev/null 2>&1 || exit 20
command -v iptables >/dev/null 2>&1 || exit 21
[ -w "$CSQTT_PROC_SYS_DIR/net/ipv4/ip_forward" ] && echo 1 > "$CSQTT_PROC_SYS_DIR/net/ipv4/ip_forward" 2>/dev/null || true
[ -w "$CSQTT_PROC_SYS_DIR/net/ipv6/conf/all/forwarding" ] && echo 1 > "$CSQTT_PROC_SYS_DIR/net/ipv6/conf/all/forwarding" 2>/dev/null || true
[ -w "$CSQTT_PROC_SYS_DIR/net/ipv4/conf/all/rp_filter" ] && echo 2 > "$CSQTT_PROC_SYS_DIR/net/ipv4/conf/all/rp_filter" 2>/dev/null || true
[ -w "$CSQTT_PROC_SYS_DIR/net/ipv4/conf/default/rp_filter" ] && echo 2 > "$CSQTT_PROC_SYS_DIR/net/ipv4/conf/default/rp_filter" 2>/dev/null || true
[ -w "$CSQTT_PROC_SYS_DIR/net/ipv4/tcp_notsent_lowat" ] && echo 131072 > "$CSQTT_PROC_SYS_DIR/net/ipv4/tcp_notsent_lowat" 2>/dev/null || true

is_ignored_wan_interface() {
    ignored_iface="\${1%%@*}"
    case "\$ignored_iface" in
        ""|lo|"\$CSQTT_IFACE"|csqtp*|tun*|tap*|wg*|warp*|Warp*|WARP*|CloudflareWARP*|tailscale*|zt*|docker*|br-*|veth*|cni*|flannel*|virbr*|podman*|kube*|dummy*|ifb*)
            return 0
            ;;
    esac
    return 1
}

detect_wan_interface() {
    fallback=""
    for iface in \$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") {print \$(i+1); break}}'); do
        iface="\${iface%%@*}"
        [ -n "\$iface" ] || continue
        [ -n "\$fallback" ] || fallback="\$iface"
        if ! is_ignored_wan_interface "\$iface" && ip link show "\$iface" >/dev/null 2>&1; then
            echo "\$iface"
            return 0
        fi
    done
    for iface in \$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/@.*/, "", \$2); print \$2}'); do
        iface="\${iface%%@*}"
        [ -n "\$iface" ] || continue
        [ -n "\$fallback" ] || fallback="\$iface"
        if ! is_ignored_wan_interface "\$iface" && ip link show "\$iface" >/dev/null 2>&1; then
            echo "\$iface"
            return 0
        fi
    done
    for iface in \$(ls /sys/class/net/ 2>/dev/null || true); do
        iface="\${iface%%@*}"
        [ -n "\$iface" ] || continue
        [ "\$iface" = "lo" ] && continue
        [ -n "\$fallback" ] || fallback="\$iface"
        if ! is_ignored_wan_interface "\$iface" && ip link show "\$iface" >/dev/null 2>&1; then
            echo "\$iface"
            return 0
        fi
    done
    [ -n "\$fallback" ] && echo "\$fallback"
}

WAN_IFACE=""
network_waited=0
while [ "\$network_waited" -lt 90 ]; do
    candidate_iface=\$(detect_wan_interface || true)
    if [ -n "\$candidate_iface" ] && ip link show "\$candidate_iface" >/dev/null 2>&1 && \
       ip -o -4 route show default 2>/dev/null | grep -q .; then
        WAN_IFACE="\$candidate_iface"
        break
    fi
    network_waited=\$((network_waited + 1))
    sleep 1
done
[ -n "\$WAN_IFACE" ] || exit 22
[ -w "$CSQTT_PROC_SYS_DIR/net/ipv4/conf/\$WAN_IFACE/rp_filter" ] && echo 2 > "$CSQTT_PROC_SYS_DIR/net/ipv4/conf/\$WAN_IFACE/rp_filter" 2>/dev/null || true
[ -w "$CSQTT_PROC_SYS_DIR/net/ipv4/conf/\$CSQTT_IFACE/rp_filter" ] && echo 2 > "$CSQTT_PROC_SYS_DIR/net/ipv4/conf/\$CSQTT_IFACE/rp_filter" 2>/dev/null || true

# Для /32 сетей с onlink-шлюзом обеспечиваем явный host route к шлюзу
gw=\$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if(\$i=="via") {print \$(i+1); break}}')
if [ -n "\$gw" ]; then
    ip route replace "\$gw" dev "\$WAN_IFACE" scope link 2>/dev/null || true
fi

if ip link show "\$CSQTT_IFACE" >/dev/null 2>&1; then
    ip link set dev "\$CSQTT_IFACE" txqueuelen 1000 2>/dev/null || true
fi

ipt() { iptables -w "\$XT_WAIT" "\$@"; }
# Порт, который в текущем режиме больше не используется, закрывается явно: без
# этого docker-режим пережил бы переключение со старым правилом на месте. Строки
# условны на момент генерации (STALE_WEB_PORT пуст в неизвестном режиме), цикл
# ограничен 8 попытками, синтаксис — POSIX: сгенерированный скрипт это /bin/sh.
if [ -n "\$STALE_WEB_PORT" ]; then
    stale_attempt=1
    while [ "\$stale_attempt" -le 8 ]; do
        stale_listing=\$(ipt -S INPUT 2>/dev/null || true)
        printf '%s\\n' "\$stale_listing" | \
            grep -Eq -- "^-A INPUT .*--dport \${STALE_WEB_PORT}([[:space:]]|\$).*\$IPT_COMMENT" || break
        if ipt -D INPUT -p tcp --dport "\$STALE_WEB_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT >/dev/null 2>&1; then
            break
        fi
        stale_attempt=\$((stale_attempt + 1))
    done
fi
ipt -C INPUT -p udp --dport "\$PEER_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p udp --dport "\$PEER_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C INPUT -p tcp --dport "\$WEB_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p tcp --dport "\$WEB_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C INPUT -p tcp --dport "\$LE_HTTP_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p tcp --dport "\$LE_HTTP_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C INPUT -i "\$CSQTT_IFACE" -s "\$SUBNET" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -i "\$CSQTT_IFACE" -s "\$SUBNET" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ipt -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ipt -C FORWARD -i "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I FORWARD -i "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C FORWARD -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I FORWARD -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -t nat -C POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ipt -t nat -A POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE || true
ipt -t nat -C POSTROUTING -s "\$SUBNET" ! -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ipt -t nat -A POSTROUTING -s "\$SUBNET" ! -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE
WAN_IP="\$(ip -4 -o addr show dev "\$WAN_IFACE" scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n 1)"
if [ -n "\$WAN_IP" ]; then
    ipt -t nat -C POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j SNAT --to-source "\$WAN_IP" 2>/dev/null || \
    ipt -t nat -I POSTROUTING 1 -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j SNAT --to-source "\$WAN_IP" 2>/dev/null || true
fi
ipt -t mangle -C FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ipt -t mangle -I FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu
ipt -t mangle -C FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ipt -t mangle -I FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu

if command -v ip6tables >/dev/null 2>&1 && ip -6 route show default 2>/dev/null | grep -q .; then
    ip6t() { ip6tables -w "\$XT_WAIT" "\$@"; }
    ip6t -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ip6t -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6t -C FORWARD -i "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ip6t -I FORWARD -i "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    ip6t -C FORWARD -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ip6t -I FORWARD -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    ip6t -t nat -C POSTROUTING -s "\$SUBNET6" ! -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ip6t -t nat -A POSTROUTING -s "\$SUBNET6" ! -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE || true
    ip6t -t mangle -C FORWARD -s "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6t -t mangle -I FORWARD -s "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6t -t mangle -C FORWARD -d "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6t -t mangle -I FORWARD -d "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
umask 077
mkdir -p "\$CSQTT_RUNTIME_DIR"
: > "\$NETWORK_READY_FILE"
NETEOF
    chmod 0755 "$target"
}

write_tun_recovery_helper() {
    local target="$1"
    cat > "$target" << RECOVEREOF
#!/bin/sh
set -eu
CSQTT_IFACE="$CSQTT_IFACE"
PEER_PORT="$PEER_PORT"
CSQTT_CONFIG_DIR="$CSQTT_CONFIG_DIR"
CSQTT_BIN_DIR="$CSQTT_BIN_DIR"
CSQTT_LIB_DIR="$CSQTT_LIB_DIR"

peer_port_is_busy() {
    ss -H -lun "sport = :\$PEER_PORT" 2>/dev/null | grep -q .
}

peer_port_pids() {
    ss -H -lunp "sport = :\$PEER_PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -un || true
}

csqtt_process_is_owned() {
    pid="\$1"
    [ -r "/proc/\$pid/cmdline" ] || return 1
    executable="\$(readlink "/proc/\$pid/exe" 2>/dev/null || true)"
    case "\$executable" in
        "\$CSQTT_BIN_DIR/csqtt"|"\$CSQTT_BIN_DIR/csqtt (deleted)"|"\$CSQTT_LIB_DIR/"*|"\$CSQTT_LIB_DIR/"*" (deleted)") return 0 ;;
    esac
    command_line="\$({ tr '\\0' ' ' < "/proc/\$pid/cmdline"; } 2>/dev/null || true)"
    case " \$command_line " in
        *" --config-dir \$CSQTT_CONFIG_DIR "*|*" \$CSQTT_BIN_DIR/csqtt "*|*" \$CSQTT_LIB_DIR/"*) return 0 ;;
        *) return 1 ;;
    esac
}

release_owned_peer_port() {
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        peer_port_is_busy || return 0
        pids="\$(peer_port_pids)"
        if [ -z "\$pids" ]; then
            echo "[CSQTT] UDP/\$PEER_PORT is occupied by a runtime without visible PID" >&2
            ss -H -lunp "sport = :\$PEER_PORT" >&2 || true
            return 24
        fi
        for pid in \$pids; do
            if [ "\$attempt" -le 2 ]; then
                echo "[CSQTT] UDP/\$PEER_PORT runtime PID \$pid; terminating" >&2
                kill -TERM "\$pid" 2>/dev/null || true
            else
                echo "[CSQTT] UDP/\$PEER_PORT runtime PID \$pid; killing" >&2
                kill -KILL "\$pid" 2>/dev/null || true
            fi
        done
        sleep 0.2
    done
    echo "[CSQTT] UDP/\$PEER_PORT did not release" >&2
    ss -H -lunp "sport = :\$PEER_PORT" >&2 || true
    return 24
}

release_owned_peer_port || exit \$?

if ! ip link show "\$CSQTT_IFACE" >/dev/null 2>&1; then
    exit 0
fi

echo "[CSQTT] stale TUN interface \$CSQTT_IFACE detected; recovering runtime" >&2
for attempt in 1 2 3 4; do
    timeout 2 ip link del "\$CSQTT_IFACE" >/dev/null 2>&1 || true
    if ! ip link show "\$CSQTT_IFACE" >/dev/null 2>&1; then
        echo "[CSQTT] stale TUN interface \$CSQTT_IFACE removed" >&2
        exit 0
    fi
    sleep 0.2
done

ip -d link show "\$CSQTT_IFACE" >&2 || true
echo "[CSQTT] unable to release TUN interface \$CSQTT_IFACE" >&2
exit 23
RECOVEREOF
    chmod 0755 "$target"
}

install_network_helper() {
    ensure_csqtt_directory "$CSQTT_LIB_DIR" 755
    write_network_helper "${CSQTT_LIB_DIR}/network-up.sh"
    write_tun_recovery_helper "${CSQTT_LIB_DIR}/tun-recover.sh"
}

verify_configured_network() {
    local iface="${1:-$(detect_wan_interface)}"
    [ -n "$iface" ] || die "WAN-интерфейс не определён при проверке сети"
    [ "$(cat "${CSQTT_PROC_SYS_DIR}/net/ipv4/ip_forward" 2>/dev/null || echo 0)" = "1" ] || die "IPv4 forwarding не включён"
    ip link show "$iface" >/dev/null 2>&1 || die "WAN-интерфейс $iface исчез"
}

setup_csqtt_binary() {
    prog 0.60 "Бинарник..."
    echo "Установка csqtt..."

    [ -n "${CANDIDATE_BINARY:-}" ] || \
        die "Не найден проверенный бинарник-кандидат" "$EXIT_PREFLIGHT_FAILED"
    install -m 0755 "$CANDIDATE_BINARY" "${CSQTT_BIN_DIR}/csqtt" || \
        die "Не удалось установить новый бинарник csqtt"
    echo "✓ csqtt установлен"

    mkdir -p "$CSQTT_CONFIG_DIR"
}

setup_csqtt_environment() {
    ensure_persistent_directory "$CSQTT_CONFIG_DIR" 700
    if [ -n "${CSQTT_ENV_BACKUP:-}" ] && [ -f "$CSQTT_ENV_BACKUP" ]; then
        install -m 0600 "$CSQTT_ENV_BACKUP" "$CSQTT_ENV_FILE" || \
            die "Не удалось восстановить прежнюю WEB-конфигурацию"
        log_info "Конфигурация панели сохранена без изменений (update)"
    elif [ -f "$CSQTT_ENV_FILE" ] && [ "${CSQTT_ENV_REWRITE:-0}" != "1" ]; then
        chmod 0600 -- "$CSQTT_ENV_FILE" 2>/dev/null || true
        log_info "Конфигурация панели сохранена без изменений (update)"
    else
        ensure_installer_work_dir
        CANDIDATE_ENV_FILE="${CSQTT_WORK_DIR}/csqtt.env.candidate"
        build_csqtt_env "$CANDIDATE_ENV_FILE"
        validate_candidate_environment "$CANDIDATE_ENV_FILE"
        install -m 0600 "$CANDIDATE_ENV_FILE" "$CSQTT_ENV_FILE" || \
            die "Не удалось активировать WEB-конфигурацию"
    fi
    echo "✓ Конфигурация запуска установлена безопасным EnvironmentFile"
}

LE_CERTBOT_COMMAND=""

is_public_ipv4() {
    local ip="$1" first second third fourth value
    case "$ip" in
        *[!0-9.]*|*..*|.*|*.) return 1 ;;
    esac
    IFS=. read -r first second third fourth <<< "$ip"
    for value in "$first" "$second" "$third" "$fourth"; do
        case "$value" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$value" -le 255 ] || return 1
    done
    [ "$first" -gt 0 ] || return 1
    [ "$first" -lt 224 ] || return 1
    [ "$first" -ne 10 ] || return 1
    [ "$first" -ne 127 ] || return 1
    [ "$first" -ne 0 ] || return 1
    [ "$first" -ne 169 ] || [ "$second" -ne 254 ] || return 1
    [ "$first" -ne 192 ] || [ "$second" -ne 168 ] || return 1
    [ "$first" -ne 172 ] || [ "$second" -lt 16 ] || [ "$second" -gt 31 ] || return 1
    [ "$first" -ne 100 ] || [ "$second" -lt 64 ] || [ "$second" -gt 127 ] || return 1
    [ "$first" -ne 198 ] || [ "$second" -ne 18 ] || return 1
    [ "$first" -ne 198 ] || [ "$second" -ne 19 ] || return 1
    return 0
}

# Зеркало is_public_ipv4: то, что публичная функция отклоняет как «не публичное»,
# здесь классифицируется как частное, чтобы текст отказа был точным. 198.18/19 —
# фактически /15, как и в is_public_ipv4.
is_private_ipv4() {
    local ip="$1" first second third fourth value
    case "$ip" in
        *[!0-9.]*|*..*|.*|*.) return 1 ;;
    esac
    IFS=. read -r first second third fourth <<< "$ip"
    for value in "$first" "$second" "$third" "$fourth"; do
        case "$value" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$value" -le 255 ] || return 1
    done
    [ "$first" -eq 0 ] && return 0
    [ "$first" -eq 10 ] && return 0
    [ "$first" -eq 127 ] && return 0
    [ "$first" -eq 100 ] && [ "$second" -ge 64 ] && [ "$second" -le 127 ] && return 0
    [ "$first" -eq 169 ] && [ "$second" -eq 254 ] && return 0
    [ "$first" -eq 172 ] && [ "$second" -ge 16 ] && [ "$second" -le 31 ] && return 0
    [ "$first" -eq 192 ] && [ "$second" -eq 168 ] && return 0
    [ "$first" -eq 198 ] && { [ "$second" -eq 18 ] || [ "$second" -eq 19 ]; } && return 0
    [ "$first" -ge 224 ] && return 0
    return 1
}

# IDN/punycode не транскодируется осознанно: не-ASCII имя отвергается, человек
# вводит punycode сам. Последняя метка обязана содержать букву — это отсекает
# «1.2.3.4.5», не прошедшее is_public_ipv4.
is_dns_hostname() {
    local name="$1" label last
    [ -n "$name" ] || return 1
    [ "${#name}" -le 253 ] || return 1
    case "$name" in
        *[!A-Za-z0-9.-]*) return 1 ;;
        .*|*.|*..*) return 1 ;;
    esac
    last="${name##*.}"
    case "$last" in
        *[A-Za-z]*) ;;
        *) return 1 ;;
    esac
    local IFS=.
    for label in $name; do
        [ -n "$label" ] || return 1
        [ "${#label}" -le 63 ] || return 1
        case "$label" in
            -*|*-) return 1 ;;
        esac
    done
    return 0
}

# Определяет режим панели один раз в начале установки. Приоритет — уже
# разрешённый PANEL_MODE/PANEL_HOST из resolve_install_configuration, затем
# CSQTT_PUBLIC_IP для ручного запуска.
resolve_panel_mode() {
    local raw="" host=""
    # resolve_install_configuration уже могла выбрать режим из state/флагов.
    # Повторный вызов не должен перезаписывать явный --web-port или молча
    # менять уже принятое значение.
    if [ -n "${PANEL_MODE:-}" ] && [ -n "${PANEL_HOST:-}" ]; then
        case "${PANEL_MODE}" in
            domain)
                WEB_PORT="443"
                LE_RENEW_BEFORE_SECONDS="2592000"
                log_info "Режим панели: домен ${PANEL_HOST}, порт ${WEB_PORT}"
                ;;
            ip)
                LE_RENEW_BEFORE_SECONDS="259200"
                log_info "Режим панели: IP ${PANEL_HOST}, порт ${WEB_PORT}"
                ;;
        esac
        return 0
    fi
    raw="${CSQTT_PUBLIC_IP:-}"
    host="$(normalize_panel_host_value "$raw")"

    if [ -z "$host" ]; then
        die "Поле «IP сервера или домен» не заполнено: укажите публичный IPv4-адрес или доменное имя" "$EXIT_INVALID_ARGUMENT"
    fi

    if is_public_ipv4 "$host"; then
        PANEL_MODE="ip"
        PANEL_HOST="$host"
        WEB_PORT="${CSQTT_WEB_PORT:-46002}"
        LE_RENEW_BEFORE_SECONDS="259200"
        log_info "Режим панели: IP ${PANEL_HOST}, порт ${WEB_PORT}"
        return 0
    fi

    if is_dns_hostname "$host"; then
        PANEL_MODE="domain"
        PANEL_HOST="$host"
        WEB_PORT="443"
        LE_RENEW_BEFORE_SECONDS="2592000"
        log_info "Режим панели: домен ${PANEL_HOST}, порт ${WEB_PORT}"
        return 0
    fi

    if is_private_ipv4 "$host"; then
        die "Панель и туннель требуют публичный IPv4 или домен: ${host} недостижим с TURN-релея и из интернета. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера" "$EXIT_INVALID_ARGUMENT"
    fi

    die "Ожидается публичный IPv4-адрес или доменное имя, получено: ${host}. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера" "$EXIT_INVALID_ARGUMENT"
}

# systemd EnvironmentFile: значение в двойных кавычках с экранированием \ и ".
# Docker env_file принимает голые значения. Формат обязан совпадать с тем, что
# читает приложение.
environment_value() {
    local value="$1"
    if [ "${DEPLOY_MODE:-systemd}" = "systemd" ]; then
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        printf '"%s"' "$value"
    else
        printf '%s' "$value"
    fi
}

# Случайная строка [A-Za-z0-9] нужной длины. openssl есть в зависимостях;
# /dev/urandom — запасной путь для урезанных окружений.
generate_random_alnum() {
    local length="$1" candidate=""
    if command -v openssl >/dev/null 2>&1; then
        candidate="$(openssl rand -base64 64 2>/dev/null | tr -dc 'A-Za-z0-9' || true)"
    fi
    if [ "${#candidate}" -lt "$length" ] && [ -r /dev/urandom ]; then
        candidate="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' || true)"
    fi
    [ "${#candidate}" -ge "$length" ] || \
        die "Не удалось сгенерировать случайное значение для панели" "$EXIT_PREFLIGHT_FAILED"
    printf '%s' "${candidate:0:$length}"
}

# Логин — 10 символов: не «admin» и не предсказуемое слово.
generate_web_user() {
    generate_random_alnum 10
}

# 24 символа — с запасом выше минимума 16 для fresh-пароля.
generate_web_password() {
    generate_random_alnum 24
}

# 16 символов [A-Za-z0-9]: секретный URL панели.
generate_secret_path() {
    generate_random_alnum 16
}

# Валидация применяется только к новым/явно заданным значениям. Значения,
# прочитанные из существующего csqtt.env, сохраняются как есть: ротация при
# update сменила бы URL панели.
validate_panel_username() {
    local value="$1"
    if ! [[ "$value" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; then
        die "Логин панели должен содержать 3–32 символа из [A-Za-z0-9._-], получено: ${value}" \
            "$EXIT_INVALID_ARGUMENT"
    fi
}

validate_panel_secret_path() {
    local value="$1" allow_empty="${2:-0}"
    if [ -z "$value" ]; then
        [ "$allow_empty" -eq 1 ] && return 0
        die "Secret path панели не может быть пустым" "$EXIT_INVALID_ARGUMENT"
    fi
    if ! [[ "$value" =~ ^[A-Za-z0-9_-]{8,64}$ ]]; then
        die "Secret path панели должен содержать 8–64 символа из [A-Za-z0-9_-], получено: ${value}" \
            "$EXIT_INVALID_ARGUMENT"
    fi
}

validate_panel_password() {
    local value="$1" fresh="${2:-0}"
    [ -n "$value" ] || die "Пароль панели не может быть пустым" "$EXIT_INVALID_ARGUMENT"
    case "$value" in
        *$'\n'*|*$'\r'*)
            die "Пароль панели не должен содержать перевод строки" "$EXIT_INVALID_ARGUMENT"
            ;;
    esac
    if [ "$fresh" -eq 1 ] && [ "${#value}" -lt 16 ]; then
        die "Пароль панели для fresh-установки должен быть не короче 16 символов" \
            "$EXIT_INVALID_ARGUMENT"
    fi
}

# Проверяет только явно заданные значения (флаг/env/интерактив). Сгенерированные
# значения валидны по построению, а сохранённые из env не перепроверяются.
validate_panel_identity() {
    local fresh="${1:-0}"
    if [ "${WEB_USER_EXPLICIT:-0}" -eq 1 ]; then
        validate_panel_username "$WEB_USER"
    fi
    if [ "${SECRET_PATH_EXPLICIT:-0}" -eq 1 ]; then
        validate_panel_secret_path "$SECRET_PATH" 0
    fi
    if [ "${WEB_PASS_EXPLICIT:-0}" -eq 1 ] && [ "${WEB_PASS_STDIN:-0}" -ne 1 ]; then
        validate_panel_password "$WEB_PASS" "$fresh"
    fi
}

# Спрашивает одну «да/нет» и при «y» — три значения. Пустой ответ на каждом
# шаге означает сгенерированный дефолт.
prompt_panel_identity() {
    local answer="" custom=""
    read -r -p 'Настроить логин/пароль/secret path вручную? [y/N]: ' answer || answer=""
    case "$answer" in
        y|Y|yes|YES) ;;
        *) return 0 ;;
    esac
    # Поля, заданные флагом/env, не переспрашиваются: явное значение имеет
    # приоритет над интерактивным ответом.
    if [ "${WEB_USER_EXPLICIT:-0}" -eq 0 ]; then
        read -r -p "Логин панели [${WEB_USER}]: " custom || custom=""
        if [ -n "$custom" ]; then
            WEB_USER="$custom"
            WEB_USER_EXPLICIT=1
        fi
    fi
    if [ "${WEB_PASS_EXPLICIT:-0}" -eq 0 ]; then
        IFS= read -r -s -p 'Пароль панели (Enter — сгенерировать): ' custom || custom=""
        printf '\n'
        if [ -n "$custom" ]; then
            WEB_PASS="$custom"
            WEB_PASS_EXPLICIT=1
        fi
    fi
    if [ "${SECRET_PATH_EXPLICIT:-0}" -eq 0 ]; then
        read -r -p "Secret path [${SECRET_PATH}]: " custom || custom=""
        if [ -n "$custom" ]; then
            SECRET_PATH="$custom"
            SECRET_PATH_EXPLICIT=1
        fi
    fi
}

# Fresh: подставляет случайные значения (если явные уже есть — не трогает) и
# предлагает ручную настройку в TTY. Update/adoption ничего не генерирует и не
# спрашивает: identity сохраняется из csqtt.env.
resolve_panel_identity() {
    local fresh=0
    [ "${PANEL_IDENTITY_PRESERVE:-0}" -eq 0 ] && fresh=1
    # Явные флаги/env валидируются всегда — и в --check тоже.
    validate_panel_identity "$fresh"
    [ "$fresh" -eq 1 ] || {
        # Update/adoption: снять существующую identity в глобалы до csqtt_cleanup,
        # который удаляет csqtt.env. Иначе --reconfigure --host перегенерировал бы
        # доступы, а пустой secret path сменил бы URL.
        [ -n "${WEB_USER:-}" ] || \
            WEB_USER="$(env_file_value CSQTT_WEB_USER "$CSQTT_ENV_FILE" 2>/dev/null || true)"
        [ -n "${WEB_PASS:-}" ] || \
            WEB_PASS="$(env_file_value CSQTT_WEB_PASS "$CSQTT_ENV_FILE" 2>/dev/null || true)"
        if [ "${SECRET_PATH_EXPLICIT:-0}" -eq 0 ]; then
            SECRET_PATH="$(env_file_value CSQTT_WEB_SECRET_PATH "$CSQTT_ENV_FILE" 2>/dev/null || true)"
        fi
        return 0
    }
    [ "${CHECK_ONLY:-0}" -eq 0 ] || return 0

    [ -n "${WEB_USER:-}" ] || WEB_USER="$(generate_web_user)"
    [ -n "${WEB_PASS:-}" ] || WEB_PASS="$(generate_web_password)"
    [ -n "${SECRET_PATH:-}" ] || SECRET_PATH="$(generate_secret_path)"

    if install_is_interactive; then
        prompt_panel_identity
        validate_panel_identity 1
    fi
}

# Новый формат авторитетного конфига: только web-ключи и host. Клиентов
# установщик не создаёт. При перезаписи (--reconfigure) существующие
# web-доступы переиспользуются.
build_csqtt_env() {
    local tmp user pass secret host existing_env dest preserve="${PANEL_IDENTITY_PRESERVE:-0}"
    dest="${1:-$CSQTT_ENV_FILE}"
    ensure_persistent_directory "$CSQTT_CONFIG_DIR" 700
    existing_env="$CSQTT_ENV_FILE"
    # Прямой вызов без resolve (утилиты/тесты): существующий env тоже означает
    # сохранение identity, а не fresh-генерацию.
    if [ "$preserve" -eq 0 ] && [ -f "$existing_env" ]; then
        preserve=1
    fi

    user="$WEB_USER"
    if [ -z "$user" ]; then
        user="$(env_file_value CSQTT_WEB_USER "$existing_env" 2>/dev/null || true)"
    fi
    [ -n "$user" ] || user="$(generate_web_user)"

    pass="$WEB_PASS"
    if [ -z "$pass" ]; then
        pass="$(env_file_value CSQTT_WEB_PASS "$existing_env" 2>/dev/null || true)"
    fi
    [ -n "$pass" ] || pass="$(generate_web_password)"
    WEB_PASS="$pass"

    secret="$SECRET_PATH"
    if [ -z "$secret" ]; then
        secret="$(env_file_value CSQTT_WEB_SECRET_PATH "$existing_env" 2>/dev/null || true)"
    fi
    # Существующая установка с пустым secret path остаётся с пустым: генерация
    # сменила бы URL панели. Генерируем только на fresh.
    if [ -z "$secret" ] && [ "$preserve" -eq 0 ]; then
        secret="$(generate_secret_path)"
    fi
    SECRET_PATH="$secret"

    host="${PANEL_HOST:-${CSQTT_PUBLIC_IP:-}}"
    [ -n "$host" ] || die "Не определён адрес панели для csqtt.env" "$EXIT_INVALID_ARGUMENT"

    tmp="$(mktemp "$(dirname -- "$dest")/.csqtt.env.XXXXXX")" || \
        die "Не удалось создать временный csqtt.env" "$EXIT_PREFLIGHT_FAILED"
    chmod 0600 "$tmp" || {
        rm -f -- "$tmp"
        die "Не удалось защитить временный csqtt.env" "$EXIT_PREFLIGHT_FAILED"
    }
    if ! {
        printf 'CSQTT_WEB_USER=%s\n' "$(environment_value "$user")"
        printf 'CSQTT_WEB_PASS=%s\n' "$(environment_value "$pass")"
        printf 'CSQTT_PUBLIC_IP=%s\n' "$(environment_value "$host")"
        printf 'CSQTT_WEB_SECRET_PATH=%s\n' "$(environment_value "$secret")"
    } > "$tmp"; then
        rm -f -- "$tmp"
        die "Не удалось записать csqtt.env" "$EXIT_PREFLIGHT_FAILED"
    fi
    if ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        die "Не удалось активировать csqtt.env" "$EXIT_PREFLIGHT_FAILED"
    fi
    log_info "Конфигурация панели записана в $dest"
}

# Перед csqtt_cleanup (он удаляет всё в /etc/csqtt, кроме whitelist) сохраняет
# существующий env в work-dir. Без этого update не смог бы соблюсти
# «csqtt.env копируется дословно».
preserve_existing_csqtt_env() {
    [ -f "$CSQTT_ENV_FILE" ] || return 0
    [ "${CSQTT_ENV_REWRITE:-0}" = "1" ] && return 0
    ensure_installer_work_dir
    CSQTT_ENV_BACKUP="${CSQTT_WORK_DIR}/csqtt.env.preserved"
    cp -p -- "$CSQTT_ENV_FILE" "$CSQTT_ENV_BACKUP" || \
        die "Не удалось сохранить существующий csqtt.env" "$EXIT_PREFLIGHT_FAILED"
    chmod 0600 -- "$CSQTT_ENV_BACKUP" || \
        die "Не удалось защитить сохранённый csqtt.env" "$EXIT_PREFLIGHT_FAILED"
}

install_is_interactive() {
    [ "${CHECK_ONLY:-0}" -eq 0 ] || return 1
    [ "${YES:-0}" -eq 0 ] || return 1
    # Тестовый hook: позволяет проверить интерактивную ветку без настоящего TTY.
    [ "${CSQTT_ASSUME_TTY:-0}" = "1" ] && return 0
    [ -t 0 ]
}

# Явный --host: классифицирует адрес и при необходимости фиксирует порт 443.
set_panel_host_or_die() {
    local host="$1" mode
    host="$(normalize_panel_host_value "$host")"
    [ -n "$host" ] || die "Поле «IP сервера или домен» не заполнено: укажите публичный IPv4-адрес или доменное имя" "$EXIT_INVALID_ARGUMENT"
    if mode="$(panel_mode_for_host "$host" 2>/dev/null)"; then
        PANEL_MODE="$mode"
        PANEL_HOST="$host"
        case "$mode" in
            domain)
                # В доменном режиме порт панели фиксирован 443 и не спрашивается.
                WEB_PORT="443"
                ;;
        esac
        return 0
    fi
    if is_private_ipv4 "$host"; then
        die "Панель и туннель требуют публичный IPv4 или домен: ${host} недостижим с TURN-релея и из интернета. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера" "$EXIT_INVALID_ARGUMENT"
    fi
    die "Ожидается публичный IPv4-адрес или доменное имя, получено: ${host}. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера" "$EXIT_INVALID_ARGUMENT"
}

config_conflict() {
    local what="$1" explicit="$2" saved="$3"
    DEPLOY_PHASE="validation"
    die "${what}: явно задано ${explicit}, сохранено ${saved}. Повторите с --reconfigure, чтобы изменить существующую установку" "$EXIT_INVALID_ARGUMENT"
}

# Разрешение конфигурации: флаг -> install.json/существующий env -> интерактив
# (только fresh, TTY и не --yes) -> detected/default. Update вопросов не задаёт,
# конфликтующие флаги без --reconfigure — exit 2.
resolve_install_configuration() {
    DEPLOY_PHASE="validation"
    local state_mode state_host state_peer state_web state_ssh state_panel_mode
    local existing=0 base_mode="" base_host="" base_peer="" base_web="" base_ssh=""
    local host="" detected_host="" answer="" candidate="" addresses="" want_domain=0

    INSTALL_KIND="fresh"
    ADOPTION_PERFORMED=0
    ADOPTION_AMBIGUOUS=0
    state_mode="$(load_install_state mode 2>/dev/null || true)"
    state_host="$(load_install_state panel_host 2>/dev/null || true)"
    state_peer="$(load_install_state peer_port 2>/dev/null || true)"
    state_web="$(load_install_state web_port 2>/dev/null || true)"
    state_ssh="$(load_install_state ssh_port 2>/dev/null || true)"
    state_panel_mode="$(load_install_state panel_mode 2>/dev/null || true)"

    # Support floor — установки 2.5.2+ с install.json. Существование определяют
    # state, env и БД; unit и контейнер для догадок о host/портах не читаются:
    # source of truth — install.json, а недостающее берётся из env и флагов.
    if [ -n "$state_mode" ] || [ -f "$CSQTT_INSTALL_STATE_FILE" ] || \
       [ -f "$CSQTT_ENV_FILE" ] || \
       [ -f "${CSQTT_CONFIG_DIR}/${CSQTT_DATABASE_FILE}" ]; then
        existing=1
        INSTALL_KIND="${state_mode:-systemd}"
        ADOPTION_PERFORMED=1
    fi

    if [ "${ACTION:-install}" = "update" ] && [ "$existing" -eq 0 ]; then
        DEPLOY_PHASE="validation"
        die "update требует существующую установку CSQTT; для первой установки используйте install" "$EXIT_INVALID_ARGUMENT"
    fi

    base_mode="${state_mode:-${DEPLOY_MODE:-}}"
    base_host="${state_host:-${PANEL_HOST:-}}"
    if [ "$existing" -eq 1 ]; then
        base_peer="${state_peer:-$PEER_PORT}"
        base_web="${state_web:-$WEB_PORT}"
        base_ssh="${state_ssh:-$SSH_PORT}"
        [ -n "$base_host" ] || base_host="$(env_file_value CSQTT_PUBLIC_IP "$CSQTT_ENV_FILE" 2>/dev/null || true)"
    fi
    # Upload-путь старого app-деплоя удалён: host берётся только из флага,
    # существующего state/env или определяется/спрашивается.
    base_host="$(normalize_panel_host_value "$base_host")"

    # Режим: --reconfigure без --mode режим не меняет.
    if [ "${DEPLOY_MODE_EXPLICIT:-0}" -eq 1 ]; then
        if [ "$existing" -eq 1 ] && [ -n "$base_mode" ] && [ "$DEPLOY_MODE" != "$base_mode" ] && \
           [ "${RECONFIGURE:-0}" -ne 1 ]; then
            config_conflict "Режим runtime" "$DEPLOY_MODE" "$base_mode"
        fi
    elif [ "$existing" -eq 1 ] && [ -n "$base_mode" ]; then
        DEPLOY_MODE="$base_mode"
    fi

    # Порты: значение из state используется, только если флаг не задан явно.
    if [ "${PEER_PORT_EXPLICIT:-0}" -eq 1 ]; then
        if [ "$existing" -eq 1 ] && [ -n "$base_peer" ] && [ "$PEER_PORT" != "$base_peer" ] && \
           [ "${RECONFIGURE:-0}" -ne 1 ]; then
            config_conflict "Порт туннеля" "$PEER_PORT" "$base_peer"
        fi
    elif [ "$existing" -eq 1 ] && [ -n "$base_peer" ]; then
        PEER_PORT="$base_peer"
    fi

    if [ "${WEB_PORT_EXPLICIT:-0}" -eq 1 ]; then
        if [ "$existing" -eq 1 ] && [ -n "$base_web" ] && [ "$WEB_PORT" != "$base_web" ] && \
           [ "${RECONFIGURE:-0}" -ne 1 ]; then
            config_conflict "Порт панели" "$WEB_PORT" "$base_web"
        fi
    elif [ "$existing" -eq 1 ] && [ -n "$base_web" ]; then
        WEB_PORT="$base_web"
    fi

    if [ "${SSH_PORT_EXPLICIT:-0}" -eq 1 ]; then
        if [ "$existing" -eq 1 ] && [ -n "$base_ssh" ] && [ "$SSH_PORT" != "$base_ssh" ] && \
           [ "${RECONFIGURE:-0}" -ne 1 ]; then
            config_conflict "SSH-порт" "$SSH_PORT" "$base_ssh"
        fi
    elif [ "$existing" -eq 1 ] && [ -n "$base_ssh" ]; then
        SSH_PORT="$base_ssh"
    elif [ "${SSH_PORT_EXPLICIT:-0}" -ne 1 ] && [ -z "$base_ssh" ]; then
        SSH_PORT="$(ssh_port_from_connection 2>/dev/null || printf '%s' "$SSH_PORT")"
    fi

    # Host: флаг -> state/env/upload -> интерактив -> публичный IP.
    HOST_OVERRIDE="$(normalize_panel_host_value "${HOST_OVERRIDE:-}")"
    if [ "${HOST_EXPLICIT:-0}" -eq 1 ] && [ -n "$HOST_OVERRIDE" ]; then
        host="$HOST_OVERRIDE"
        if [ "$existing" -eq 1 ] && [ -n "$base_host" ] && [ "$host" != "$base_host" ] && \
           [ "${RECONFIGURE:-0}" -ne 1 ]; then
            config_conflict "Адрес панели" "$host" "$base_host"
        fi
    elif [ "$existing" -eq 1 ] && [ -n "$base_host" ]; then
        host="$base_host"
        if install_is_interactive; then
            read -r -p "Сменить адрес панели (сейчас ${base_host})? [y/N]: " answer || answer=""
            case "$answer" in
                y | Y | yes | YES | Yes)
                    detected_host="$(detect_public_ipv4 2>/dev/null || true)"
                    candidate="$(prompt_panel_address_change "$base_host" "$detected_host")"
                    if [ "$candidate" != "$base_host" ]; then
                        host="$candidate"
                        # Смена адреса меняет режим/порт панели — это reconfiguration.
                        RECONFIGURE=1
                    fi
                    ;;
            esac
        fi
    elif [ -n "$HOST_OVERRIDE" ]; then
        host="$HOST_OVERRIDE"
    elif [ -n "$base_host" ]; then
        host="$base_host"
    fi

    # Host: флаг -> state/env -> интерактив -> публичный IP.
    # Свежая установка (или прерванная до записи env) спрашивает домен сразу.
    # Существующая установка спрашивает только «сменить адрес?» с дефолтом N,
    # чтобы update и adoption не переключали режим случайным Enter.
    if [ -z "$host" ] && [ "$existing" -eq 0 ]; then
        if install_is_interactive; then
            detected_host="$(detect_public_ipv4 2>/dev/null || true)"
            if [ -n "$detected_host" ]; then
                host="$(prompt_panel_host_choice "$detected_host")"
            else
                # IP неизвестен: откатываться некуда, домен или IP обязателен.
                while :; do
                    read -r -p "Публичный IP определить не удалось: введите IP или домен панели: " answer || answer=""
                    [ -n "$answer" ] && {
                        host="$answer"
                        break
                    }
                    printf 'Нужен IP-адрес или доменное имя\n' >&2
                done
            fi
        else
            if [ -n "${CSQTT_PUBLIC_IP:-}" ]; then
                host="$CSQTT_PUBLIC_IP"
            else
                host="$(detect_public_ipv4 2>/dev/null || true)"
            fi
            [ -n "$host" ] || \
                die "Не удалось определить публичный IP; укажите --host <ip|domain>" "$EXIT_INVALID_ARGUMENT"
        fi
    fi

    if [ -n "$host" ]; then
        set_panel_host_or_die "$host"
    elif [ -n "$state_panel_mode" ]; then
        PANEL_MODE="$state_panel_mode"
    fi

    # install.json без panel_host (повреждённый state): host не домысливается ни
    # из unit, ни из контейнера. --check печатает найденное, install требует
    # явного --host, чтобы не записать чужой адрес в state.
    if [ "$existing" -eq 1 ] && [ -z "${PANEL_HOST:-}" ]; then
        ADOPTION_AMBIGUOUS=1
    fi

    # Неоднозначный state: --check печатает найденное, install требует
    # явного решения. После явного host/mode неоднозначности больше нет.
    if [ "$ADOPTION_AMBIGUOUS" -eq 1 ]; then
        if [ "${CHECK_ONLY:-0}" -eq 1 ]; then
            print_adoption_summary
            return 0
        fi
        if [ "${HOST_EXPLICIT:-0}" -ne 1 ] && [ "${RECONFIGURE:-0}" -ne 1 ] && \
           [ -z "${PANEL_HOST:-}" ]; then
            print_adoption_summary
            DEPLOY_PHASE="validation"
            die "Существующая установка распознана неоднозначно: укажите --host <ip|domain> или --reconfigure" "$EXIT_INVALID_ARGUMENT"
        fi
        if [ -n "${PANEL_HOST:-}" ] && [ -n "${DEPLOY_MODE:-}" ]; then
            ADOPTION_AMBIGUOUS=0
        fi
    fi

    # Интерактивные порты/режим — только свежая установка и только TTY.
    # Ввод проверяется на месте: раньше опечатка («y» вместо systemd) молча
    # игнорировалась, а нечисловой порт принимался без проверки.
    if [ "$existing" -eq 0 ] && install_is_interactive; then
        if [ "${PEER_PORT_EXPLICIT:-0}" -ne 1 ]; then
            while :; do
                read -r -p "Порт туннеля [${PEER_PORT}] (Enter — оставить): " answer || answer=""
                [ -n "$answer" ] || break
                if [[ "$answer" =~ ^[0-9]{1,5}$ ]] && ((10#$answer >= 1 && 10#$answer <= 65535)); then
                    PEER_PORT="$answer"
                    break
                fi
                printf 'Нужен номер порта 1–65535 (Enter — оставить %s)\n' "$PEER_PORT" >&2
            done
        fi
        if [ "${PANEL_MODE:-}" = "ip" ] && [ "${WEB_PORT_EXPLICIT:-0}" -ne 1 ]; then
            while :; do
                read -r -p "Порт панели [${WEB_PORT}] (Enter — оставить): " answer || answer=""
                [ -n "$answer" ] || break
                if [[ "$answer" =~ ^[0-9]{1,5}$ ]] && ((10#$answer >= 1 && 10#$answer <= 65535)); then
                    WEB_PORT="$answer"
                    break
                fi
                printf 'Нужен номер порта 1–65535 (Enter — оставить %s)\n' "$WEB_PORT" >&2
            done
        fi
        if [ "${DEPLOY_MODE_EXPLICIT:-0}" -ne 1 ]; then
            while :; do
                read -r -p "Режим runtime: systemd или docker (Enter — ${DEPLOY_MODE}): " answer || answer=""
                case "$answer" in
                    "") break ;;
                    systemd | docker)
                        DEPLOY_MODE="$answer"
                        break
                        ;;
                    *)
                        printf 'Допустимо только systemd или docker (Enter — оставить %s)\n' "$DEPLOY_MODE" >&2
                        ;;
                esac
            done
        fi
    fi

    # Существующая установка сохраняет identity из csqtt.env; fresh генерирует
    # случайные значения и (в TTY) предлагает ручную настройку.
    if [ "$existing" -eq 1 ]; then
        PANEL_IDENTITY_PRESERVE=1
    else
        PANEL_IDENTITY_PRESERVE=0
    fi
    resolve_panel_identity

    # Перезапись env нужна для fresh install и при явной смене host/доступов.
    if [ "$existing" -eq 0 ]; then
        CSQTT_ENV_REWRITE=1
    elif [ -n "$base_host" ] && [ "${PANEL_HOST:-}" != "$base_host" ]; then
        CSQTT_ENV_REWRITE=1
    elif [ "${WEB_USER_EXPLICIT:-0}" -eq 1 ] || [ "${SECRET_PATH_EXPLICIT:-0}" -eq 1 ] || \
         [ "${WEB_PASS_EXPLICIT:-0}" -eq 1 ]; then
        CSQTT_ENV_REWRITE=1
    else
        CSQTT_ENV_REWRITE=0
    fi

    if [ "${CHECK_ONLY:-0}" -eq 1 ]; then
        if [ "$ADOPTION_PERFORMED" -eq 1 ]; then
            print_adoption_summary
        fi
        return 0
    fi
}

# Баннеры установщика печатают режим и хост панели: в доменном режиме порт 443
# и домен, в IP-режиме порт и адрес.
panel_web_mode_label() {
    case "${PANEL_MODE:-ip}" in
        domain) printf 'домен %s\n' "${PANEL_HOST:-}" ;;
        *) printf 'IP %s\n' "${PANEL_HOST:-}" ;;
    esac
}

panel_web_port_label() {
    printf '%s (%s)\n' "$WEB_PORT" "$(panel_web_mode_label)"
}

print_installer_header() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       CSQTT VPN Server — Installer v${SCRIPT_VERSION}                    ║"
    if [ -n "${PANEL_MODE:-}" ]; then
        echo "║       PEER: ${PEER_PORT}  |  SSH: ${SSH_PORT}  | WEB: ${WEB_PORT}       ║"
    else
        echo "║       PEER: ${PEER_PORT}  |  SSH: ${SSH_PORT}                          ║"
    fi
    echo "╚══════════════════════════════════════════════════════════════╝"
}

detect_public_ipv4() {
    local route_ip
    route_ip="$(ip -4 route get 77.88.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1)"
    if [ -n "$route_ip" ] && is_public_ipv4 "$route_ip"; then
        printf '%s\n' "$route_ip"
        return 0
    fi
    local endpoint value
    for endpoint in https://api.ipify.org https://ipv4.icanhazip.com; do
        value="$(curl -4 -fsS --connect-timeout 3 --max-time 7 "$endpoint" 2>/dev/null || true)"
        value="$(printf '%s' "$value" | tr -d '[:space:]')"
        if is_public_ipv4 "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 1
}

# В доменном режиме нужен --domains, в IP-режиме — --ip-address: системный
# certbot без нужного флага не должен приниматься за готового клиента, иначе
# установка уйдёт в лишний venv или в ложный отказ.
panel_certbot_flag() {
    case "${PANEL_MODE:-ip}" in
        domain) printf '%s\n' "--domains" ;;
        *) printf '%s\n' "--ip-address" ;;
    esac
}

certbot_supports() {
    local certbot="$1" flag
    flag="$(panel_certbot_flag)"
    "$certbot" certonly --help all 2>&1 | grep -Fq -- "$flag"
}

letsencrypt_http_port_listeners() {
    ss -ltnH "sport = :${LE_HTTP_PORT}" 2>/dev/null || true
}

# TCP/80 нужен HTTP-01 и должен быть свободен. В доменном режиме занятость —
# фатальная ошибка: подставить самоподписанный сертификат вместо доменного
# нельзя (решение владельца 4).
assert_letsencrypt_http_port_is_available() {
    local listeners
    listeners="$(letsencrypt_http_port_listeners)"
    [ -z "$listeners" ] && return 0
    log_warn "TCP/${LE_HTTP_PORT} занят другим сервисом:"
    printf '%s\n' "$listeners" | tee -a "$LOG_FILE" >&2
    die "Порт ${LE_HTTP_PORT} занят другим сервисом; освободите его: он нужен Let’s Encrypt для проверки домена. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера"
}

ensure_letsencrypt_client() {
    local system_certbot=""
    local -a python_packages=()
    if command -v certbot >/dev/null 2>&1; then
        system_certbot="$(command -v certbot)"
        if certbot_supports "$system_certbot"; then
            LE_CERTBOT_COMMAND="$system_certbot"
            return 0
        fi
    fi
    if [ -x "$CSQTT_LE_CERTBOT" ] && certbot_supports "$CSQTT_LE_CERTBOT"; then
        LE_CERTBOT_COMMAND="$CSQTT_LE_CERTBOT"
        return 0
    fi

    log_step "Подготовка Let’s Encrypt клиента..."
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
        case "$PKG_MGR" in
            apt) python_packages=(python3 python3-venv) ;;
            dnf|yum) python_packages=(python3 python3-pip) ;;
            pacman) python_packages=(python) ;;
        esac
        if ! pkg_install_with_refresh "${python_packages[@]}"; then
            log_warn "Python/venv недоступны; WEB-панель временно останется на self-signed TLS"
            return 1
        fi
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        if ! pkg_install_with_refresh openssl; then
            log_warn "OpenSSL недоступен; проверка и обновление Let’s Encrypt сертификата отложены"
            return 1
        fi
    fi
    if [ ! -x "$CSQTT_LE_CERTBOT" ] || ! "$CSQTT_LE_CERTBOT" --version >/dev/null 2>&1; then
        rm -rf "$CSQTT_LE_VENV"
        if ! python3 -m venv "$CSQTT_LE_VENV" >>"$LOG_FILE" 2>&1; then
            log_warn "Не удалось создать изолированный Let’s Encrypt client; WEB-панель временно останется на self-signed TLS"
            return 1
        fi
    fi
    if ! timeout 180 "$CSQTT_LE_VENV/bin/pip" install --disable-pip-version-check --no-cache-dir --upgrade 'certbot>=5.4,<6' >>"$LOG_FILE" 2>&1; then
        log_warn "Не удалось установить актуальный Certbot с поддержкой IP-сертификатов; WEB-панель временно останется на self-signed TLS"
        return 1
    fi
    if ! certbot_supports "$CSQTT_LE_CERTBOT"; then
        log_warn "Установленный Certbot не поддерживает сертификаты Let’s Encrypt для выбранного режима панели"
        return 1
    fi
    LE_CERTBOT_COMMAND="$CSQTT_LE_CERTBOT"
    return 0
}

# Имя сертификата зависит от режима: IP-сертификат исторически csqtt-ip-<ip>,
# доменный — csqtt-<домен>. Версия с режимом нужна проверкам состояния: они
# сверяют имя с режимом, записанным в state, а не с текущим.
letsencrypt_cert_name_for_mode() {
    local mode="$1" identifier="$2"
    case "$mode" in
        domain) printf 'csqtt-%s\n' "$identifier" ;;
        *) printf 'csqtt-ip-%s\n' "${identifier//./-}" ;;
    esac
}

letsencrypt_cert_name() {
    letsencrypt_cert_name_for_mode "${PANEL_MODE:-ip}" "$1"
}

# SAN сверяется с режимом: домен в SAN — DNS:<домен>, IP — IP Address:<ip>.
panel_san_matches() {
    local mode="$1" identifier="$2" subject_alt_names="$3"
    case "$mode" in
        domain)
            printf '%s\n' "$subject_alt_names" | grep -Fq "DNS:${identifier}"
            ;;
        *)
            printf '%s\n' "$subject_alt_names" | grep -Fq "IP Address:${identifier}" || \
                printf '%s\n' "$subject_alt_names" | grep -Fq "IP:${identifier}"
            ;;
    esac
}

state_value() {
    local key="$1"
    [ -f "$CSQTT_LE_STATE_FILE" ] || return 1
    sed -n "s/^${key}=//p" "$CSQTT_LE_STATE_FILE" | head -n 1
}

certificate_is_csqtt_rcgen() {
    local issuer subject
    [ -s "$CSQTT_CONFIG_DIR/web_cert.pem" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$CSQTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    subject="$(openssl x509 -noout -subject -nameopt RFC2253 -in "$CSQTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    issuer="${issuer#issuer=}"
    subject="${subject#subject=}"
    [ "$subject" = "CN=rcgen self signed cert" ] && [ "$issuer" = "$subject" ]
}

certificate_is_csqtt_letsencrypt() {
    local saved_mode saved_identifier cert_name issuer subject_alt_names
    [ -s "$CSQTT_CONFIG_DIR/web_cert.pem" ] || return 1
    [ -s "$CSQTT_CONFIG_DIR/web_key.pem" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    saved_mode="$(state_value MODE 2>/dev/null || true)"
    saved_identifier="$(state_value IDENTIFIER 2>/dev/null || true)"
    cert_name="$(state_value CERT_NAME 2>/dev/null || true)"
    case "$saved_mode" in
        domain) is_dns_hostname "$saved_identifier" || return 1 ;;
        ip) is_public_ipv4 "$saved_identifier" || return 1 ;;
        *) return 1 ;;
    esac
    [ "$cert_name" = "$(letsencrypt_cert_name_for_mode "$saved_mode" "$saved_identifier")" ] || return 1
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$CSQTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    issuer="${issuer#issuer=}"
    case "$issuer" in
        *"O=Let's Encrypt"*|*ISRG*) ;;
        *) return 1 ;;
    esac
    subject_alt_names="$(openssl x509 -noout -ext subjectAltName -in "$CSQTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    panel_san_matches "$saved_mode" "$saved_identifier" "$subject_alt_names"
}

web_certificate_is_csqtt_managed() {
    certificate_is_csqtt_rcgen || certificate_is_csqtt_letsencrypt
}

web_certificate_is_user_managed() {
    [ -s "$CSQTT_CONFIG_DIR/web_cert.pem" ] || return 1
    # Без openssl классифицировать нельзя: и rcgen-, и Let's Encrypt-проверки
    # молча отказывают, и валидный сертификат CSQTT выглядел бы пользовательским
    # (тогда установщик удалил бы letsencrypt.env и не поставил продление).
    command -v openssl >/dev/null 2>&1 || return 1
    ! web_certificate_is_csqtt_managed
}

letsencrypt_certificate_is_current() {
    local identifier="$1" saved_mode saved_identifier
    certificate_is_csqtt_letsencrypt || return 1
    saved_mode="$(state_value MODE 2>/dev/null || true)"
    [ "$saved_mode" = "${PANEL_MODE:-ip}" ] || return 1
    saved_identifier="$(state_value IDENTIFIER 2>/dev/null || true)"
    [ "$saved_identifier" = "$identifier" ] || return 1
    [ -s "$CSQTT_CONFIG_DIR/web_cert.pem" ] || return 1
    openssl x509 -noout -checkend "$LE_RENEW_BEFORE_SECONDS" -in "$CSQTT_CONFIG_DIR/web_cert.pem" >/dev/null 2>&1
}

disable_letsencrypt_renewal_timer() {
    rm -f -- "${CSQTT_CRON_DIR}/csqtt-letsencrypt"
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl disable --now "$CSQTT_LE_TIMER" >/dev/null 2>&1 || true
}

# Остановка без выключения: таймер обязан замолчать на время переключения, но
# включать его будет install_letsencrypt_renewal_timer в конце установки.
stop_letsencrypt_renewal_timer() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl stop "$CSQTT_LE_TIMER" "$CSQTT_LE_SERVICE" >/dev/null 2>&1 || true
}

install_letsencrypt_certificate() {
    local identifier="$1" cert_name="$2" source_dir cert_tmp key_tmp state_tmp
    source_dir="${CSQTT_LE_ROOT}/live/${cert_name}"
    [ -s "$source_dir/fullchain.pem" ] && [ -s "$source_dir/privkey.pem" ] || return 1
    cert_tmp="$(mktemp "${CSQTT_CONFIG_DIR}/.web_cert.XXXXXX")" || return 1
    key_tmp="$(mktemp "${CSQTT_CONFIG_DIR}/.web_key.XXXXXX")" || {
        rm -f -- "$cert_tmp"
        return 1
    }
    state_tmp="$(mktemp "${CSQTT_CONFIG_DIR}/.letsencrypt.XXXXXX")" || {
        rm -f -- "$cert_tmp" "$key_tmp"
        return 1
    }
    if ! install -m 0644 "$source_dir/fullchain.pem" "$cert_tmp" || \
       ! install -m 0600 "$source_dir/privkey.pem" "$key_tmp"; then
        rm -f -- "$cert_tmp" "$key_tmp" "$state_tmp"
        return 1
    fi
    printf 'MODE=%s\nIDENTIFIER=%s\nCERT_NAME=%s\n' "${PANEL_MODE:-ip}" "$identifier" "$cert_name" > "$state_tmp"
    chmod 0600 "$state_tmp"
    # State пишется последним: если активация файлов не удалась, состояние не
    # должно объявлять режим, которому диск не соответствует.
    mv -f -- "$cert_tmp" "$CSQTT_CONFIG_DIR/web_cert.pem"
    mv -f -- "$key_tmp" "$CSQTT_CONFIG_DIR/web_key.pem"
    mv -f -- "$state_tmp" "$CSQTT_LE_STATE_FILE"
    secure_persistent_state
}

# SAN сертификата, лежащего в web_cert.pem. Нужен adopt-у, которому state уже
# недоступен: в доменном режиме извлекается DNS:<домен>, в IP-режиме — адрес.
letsencrypt_certificate_identifier() {
    local subject_alt_names
    [ -s "$CSQTT_CONFIG_DIR/web_cert.pem" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    subject_alt_names="$(openssl x509 -noout -ext subjectAltName -in "$CSQTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    case "${PANEL_MODE:-ip}" in
        domain) printf '%s\n' "$subject_alt_names" | sed -n -E 's/.*DNS:([A-Za-z0-9.-]+).*/\1/p' | head -n 1 ;;
        *) printf '%s\n' "$subject_alt_names" | sed -n -E 's/.*(IP Address:|IP:)([0-9.]+).*/\2/p' | head -n 1 ;;
    esac
}

adopt_letsencrypt_certificate() {
    local identifier cert_name source_dir issuer
    [ -s "$CSQTT_CONFIG_DIR/web_cert.pem" ] || return 1
    [ -s "$CSQTT_CONFIG_DIR/web_key.pem" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$CSQTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    issuer="${issuer#issuer=}"
    case "$issuer" in
        *"O=Let's Encrypt"*|*ISRG*) ;;
        *) return 1 ;;
    esac
    identifier="$(letsencrypt_certificate_identifier 2>/dev/null || true)"
    # SAN сертификата обязан соответствовать текущему режиму, иначе adopt
    # записал бы чужой режим посреди установки.
    case "${PANEL_MODE:-ip}" in
        domain)
            [ -n "$identifier" ] || return 1
            [ "$identifier" = "$PANEL_HOST" ] || return 1
            ;;
        *)
            is_public_ipv4 "$identifier" || return 1
            ;;
    esac
    cert_name="$(letsencrypt_cert_name "$identifier")"
    source_dir="${CSQTT_LE_ROOT}/live/${cert_name}"
    [ -s "$source_dir/fullchain.pem" ] || return 1
    [ -s "$source_dir/privkey.pem" ] || return 1
    install_letsencrypt_certificate "$identifier" "$cert_name"
}

issue_letsencrypt_certificate() {
    local certbot="$1" identifier="$2" cert_name="$3" public_ip="$2"
    if [ "${PANEL_MODE:-ip}" = "domain" ]; then
        assert_letsencrypt_http_port_is_available
        # Идентификатор доменного режима — это PANEL_HOST; certbot получает его
        # напрямую, чтобы имя в заявке и в панели не могли разойтись.
        if ! timeout 90 "$certbot" certonly --standalone --http-01-port "$LE_HTTP_PORT" \
            --non-interactive --agree-tos --register-unsafely-without-email \
            --domains "$PANEL_HOST" \
            --cert-name "$cert_name" --keep-until-expiring >>"$LOG_FILE" 2>&1; then
            die "Let’s Encrypt не подтвердил домен ${identifier}; смотрите ${LOG_FILE}. Проверьте A-запись и что порт ${LE_HTTP_PORT} доступен из интернета. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера"
        fi
        if ! install_letsencrypt_certificate "$identifier" "$cert_name"; then
            die "Let’s Encrypt выдал сертификат для ${identifier}, но CSQTT не смог безопасно активировать его: проверьте свободное место в ${CSQTT_CONFIG_DIR}. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера"
        fi
        log_info "Let’s Encrypt сертификат активирован для домена ${identifier}"
        return 0
    fi
    if [ -n "$(letsencrypt_http_port_listeners)" ]; then
        log_warn "TCP/${LE_HTTP_PORT} уже занят другим сервисом; Let’s Encrypt IP-сертификат отложен, сохранён self-signed fallback"
        return 1
    fi
    if ! timeout 90 "$certbot" certonly --standalone --http-01-port "$LE_HTTP_PORT" \
        --non-interactive --agree-tos --register-unsafely-without-email \
        --preferred-profile shortlived --ip-address "$public_ip" \
        --cert-name "$cert_name" --keep-until-expiring >>"$LOG_FILE" 2>&1; then
        if ! timeout 90 "$certbot" certonly --standalone --http-01-port "$LE_HTTP_PORT" \
            --non-interactive --agree-tos --register-unsafely-without-email \
            --ip-address "$public_ip" \
            --cert-name "$cert_name" --keep-until-expiring >>"$LOG_FILE" 2>&1; then
            log_warn "Let’s Encrypt не подтвердил IP ${public_ip}; сохранён self-signed fallback, следующая проверка выполнится автоматически"
            return 1
        fi
    fi
    if ! install_letsencrypt_certificate "$identifier" "$cert_name"; then
        log_warn "Let’s Encrypt выдал сертификат, но CSQTT не смог безопасно активировать его"
        return 1
    fi
    log_info "Let’s Encrypt IP-сертификат активирован для ${identifier}"
}

generate_rcgen_fallback_certificate() {
    local cert_tmp key_tmp current_ip="${1:-}" san_ext
    command -v openssl >/dev/null 2>&1 || return 1
    cert_tmp="$(mktemp "${CSQTT_CONFIG_DIR}/.web_cert.XXXXXX")" || return 1
    key_tmp="$(mktemp "${CSQTT_CONFIG_DIR}/.web_key.XXXXXX")" || { rm -f -- "$cert_tmp"; return 1; }
    san_ext="subjectAltName = DNS:localhost,IP:127.0.0.1"
    if [ -n "$current_ip" ] && is_public_ipv4 "$current_ip"; then
        san_ext="${san_ext},IP:${current_ip}"
    fi
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=rcgen self signed cert" \
        -addext "$san_ext" \
        -keyout "$key_tmp" -out "$cert_tmp" >/dev/null 2>&1; then
        if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -subj "/CN=rcgen self signed cert" \
            -keyout "$key_tmp" -out "$cert_tmp" >/dev/null 2>&1; then
            rm -f -- "$cert_tmp" "$key_tmp"
            return 1
        fi
    fi
    mv -f -- "$cert_tmp" "$CSQTT_CONFIG_DIR/web_cert.pem"
    mv -f -- "$key_tmp" "$CSQTT_CONFIG_DIR/web_key.pem"
    chmod 644 "$CSQTT_CONFIG_DIR/web_cert.pem"
    chmod 600 "$CSQTT_CONFIG_DIR/web_key.pem"
    rm -f -- "$CSQTT_LE_STATE_FILE"
}

write_letsencrypt_renewal_helper() {
    install -d -m 0755 "$(dirname "$CSQTT_LE_RENEW_HELPER")"
    cat > "$CSQTT_LE_RENEW_HELPER" << 'LEHELPER'
#!/bin/bash
set -Eeuo pipefail

CERTBOT="${CSQTT_LE_CERTBOT:-}"
if [ -z "$CERTBOT" ] || ! "$CERTBOT" --version >/dev/null 2>&1; then
    if [ -x /opt/csqtt-certbot/bin/certbot ] && /opt/csqtt-certbot/bin/certbot --version >/dev/null 2>&1; then
        CERTBOT="/opt/csqtt-certbot/bin/certbot"
    elif command -v certbot >/dev/null 2>&1 && certbot --version >/dev/null 2>&1; then
        CERTBOT="$(command -v certbot)"
    fi
fi
CONFIG_DIR="${CSQTT_CONFIG_DIR:-/etc/csqtt}"
LE_ROOT="${CSQTT_LE_ROOT:-/etc/letsencrypt}"
LE_IDENTIFIER="${CSQTT_LE_IDENTIFIER:-}"
STATE_FILE="${CONFIG_DIR}/letsencrypt.env"
CERT_PATH="${CONFIG_DIR}/web_cert.pem"
KEY_PATH="${CONFIG_DIR}/web_key.pem"
RENEW_BEFORE_SECONDS="${CSQTT_LE_RENEW_BEFORE_SECONDS:-259200}"
HTTP_PORT="${CSQTT_LE_HTTP_PORT:-80}"
SERVICE_MANAGER="${CSQTT_DEPLOY_MODE:-systemd}"

log() {
    logger -t csqtt-letsencrypt -- "$*" 2>/dev/null || true
    printf '%s\n' "$*"
}

is_public_ipv4() {
    local ip="$1" first second third fourth value
    case "$ip" in
        *[!0-9.]*|*..*|.*|*.) return 1 ;;
    esac
    IFS=. read -r first second third fourth <<< "$ip"
    for value in "$first" "$second" "$third" "$fourth"; do
        case "$value" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$value" -le 255 ] || return 1
    done
    [ "$first" -gt 0 ] && [ "$first" -lt 224 ] && [ "$first" -ne 10 ] && [ "$first" -ne 127 ] || return 1
    [ "$first" -ne 169 ] || [ "$second" -ne 254 ] || return 1
    [ "$first" -ne 192 ] || [ "$second" -ne 168 ] || return 1
    [ "$first" -ne 172 ] || [ "$second" -lt 16 ] || [ "$second" -gt 31 ] || return 1
    [ "$first" -ne 100 ] || [ "$second" -lt 64 ] || [ "$second" -gt 127 ] || return 1
    [ "$first" -ne 198 ] || [ "$second" -ne 18 ] || return 1
    [ "$first" -ne 198 ] || [ "$second" -ne 19 ] || return 1
}

public_ipv4() {
    local route_ip
    route_ip="$(ip -4 route get 77.88.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1)"
    if [ -n "$route_ip" ] && is_public_ipv4 "$route_ip"; then
        printf '%s\n' "$route_ip"
        return 0
    fi
    local endpoint value
    for endpoint in https://api.ipify.org https://ipv4.icanhazip.com; do
        value="$(curl -4 -fsS --connect-timeout 3 --max-time 7 "$endpoint" 2>/dev/null || true)"
        value="$(printf '%s' "$value" | tr -d '[:space:]')"
        if is_public_ipv4 "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    value="$(state_value IDENTIFIER 2>/dev/null || true)"
    if is_public_ipv4 "$value"; then
        printf '%s\n' "$value"
        return 0
    fi
    return 1
}

state_value() {
    local key="$1" value=""
    if [ -f "$STATE_FILE" ]; then
        value="$(sed -n "s/^${key}=//p" "$STATE_FILE" | head -n 1)"
    fi
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

is_dns_name() {
    local name="$1"
    [ -n "$name" ] || return 1
    [ "${#name}" -le 253 ] || return 1
    case "$name" in
        *[!A-Za-z0-9.-]*|.*|*.|*..*) return 1 ;;
    esac
    case "${name##*.}" in
        *[A-Za-z]*) return 0 ;;
    esac
    return 1
}

# Режим читается из state; если state потерян, он выводится из идентификатора,
# который передаёт юнит: адрес — IP-режим, имя — доменный. Пустой идентификатор
# (старый юнит) даёт прежнее поведение IP-режима.
panel_mode() {
    local mode
    mode="$(state_value MODE 2>/dev/null || true)"
    if [ -n "$mode" ]; then
        printf '%s\n' "$mode"
        return 0
    fi
    if [ -n "$LE_IDENTIFIER" ] && ! is_public_ipv4 "$LE_IDENTIFIER"; then
        printf 'domain\n'
        return 0
    fi
    printf 'ip\n'
}

panel_identifier() {
    local identifier
    identifier="$(state_value IDENTIFIER 2>/dev/null || true)"
    if [ -n "$identifier" ]; then
        printf '%s\n' "$identifier"
        return 0
    fi
    printf '%s\n' "$LE_IDENTIFIER"
}

current_identifier() {
    if [ "$(panel_mode)" = "domain" ]; then
        panel_identifier
    else
        public_ipv4
    fi
}

cert_name_for() {
    local mode="$1" identifier="$2"
    if [ "$mode" = "domain" ]; then
        printf 'csqtt-%s\n' "$identifier"
    else
        printf 'csqtt-ip-%s\n' "${identifier//./-}"
    fi
}

certificate_is_csqtt_rcgen() {
    local issuer subject
    [ -s "$CERT_PATH" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$CERT_PATH" 2>/dev/null || true)"
    subject="$(openssl x509 -noout -subject -nameopt RFC2253 -in "$CERT_PATH" 2>/dev/null || true)"
    issuer="${issuer#issuer=}"
    subject="${subject#subject=}"
    [ "$subject" = "CN=rcgen self signed cert" ] && [ "$issuer" = "$subject" ]
}

certificate_is_csqtt_letsencrypt() {
    local mode identifier cert_name issuer subject_alt_names
    [ -s "$CERT_PATH" ] || return 1
    [ -s "$KEY_PATH" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    mode="$(panel_mode)"
    identifier="$(state_value IDENTIFIER 2>/dev/null || true)"
    cert_name="$(state_value CERT_NAME 2>/dev/null || true)"
    if [ -z "$identifier" ] || [ -z "$cert_name" ]; then
        subject_alt_names="$(openssl x509 -noout -ext subjectAltName -in "$CERT_PATH" 2>/dev/null || true)"
        if [ "$mode" = "domain" ]; then
            identifier="$(printf '%s\n' "$subject_alt_names" | sed -n -E 's/.*DNS:([A-Za-z0-9.-]+).*/\1/p' | head -n 1)"
        else
            identifier="$(printf '%s\n' "$subject_alt_names" | sed -n -E 's/.*(IP Address:|IP:)([0-9.]+).*/\2/p' | head -n 1)"
        fi
        cert_name="$(cert_name_for "$mode" "$identifier")"
    fi
    if [ "$mode" = "domain" ]; then
        is_dns_name "$identifier" || return 1
    else
        is_public_ipv4 "$identifier" || return 1
    fi
    [ "$cert_name" = "$(cert_name_for "$mode" "$identifier")" ] || return 1
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$CERT_PATH" 2>/dev/null || true)"
    issuer="${issuer#issuer=}"
    case "$issuer" in
        *"O=Let's Encrypt"*|*ISRG*) ;;
        *) return 1 ;;
    esac
    subject_alt_names="$(openssl x509 -noout -ext subjectAltName -in "$CERT_PATH" 2>/dev/null || true)"
    if [ "$mode" = "domain" ]; then
        printf '%s\n' "$subject_alt_names" | grep -Fq "DNS:${identifier}"
    else
        printf '%s\n' "$subject_alt_names" | grep -Fq "IP Address:${identifier}" || printf '%s\n' "$subject_alt_names" | grep -Fq "IP:${identifier}"
    fi
}

certificate_is_csqtt_managed() {
    certificate_is_csqtt_rcgen || certificate_is_csqtt_letsencrypt
}

# Пустой CSQTT_LE_IDENTIFIER — не расхождение: старый юнит переменную не
# передаёт вовсе, и трактовка пустого значения как mismatch вызвала бы боевой
# перевыпуск на пустом месте (а под set -u — падение).
needs_renewal() {
    local current="$1" saved_identifier
    if certificate_is_csqtt_rcgen; then
        return 0
    fi
    saved_identifier="$(state_value IDENTIFIER 2>/dev/null || true)"
    [ "$saved_identifier" = "$current" ] || return 0
    if [ -z "$LE_IDENTIFIER" ]; then
        log "Let’s Encrypt: юнит не передал CSQTT_LE_IDENTIFIER; сверка режима пропущена"
    elif [ "$saved_identifier" != "$LE_IDENTIFIER" ]; then
        log "Let’s Encrypt: идентификатор в состоянии (${saved_identifier}) расходится с ожидаемым (${LE_IDENTIFIER}); требуется перевыпуск"
        return 0
    fi
    [ -s "$CERT_PATH" ] || return 0
    openssl x509 -noout -checkend "$RENEW_BEFORE_SECONDS" -in "$CERT_PATH" >/dev/null 2>&1 || return 0
    return 1
}

certificate_is_expired() {
    [ -s "$CERT_PATH" ] || return 0
    command -v openssl >/dev/null 2>&1 || return 1
    ! openssl x509 -noout -checkend 0 -in "$CERT_PATH" >/dev/null 2>&1
}

generate_rcgen_fallback() {
    local current_ip="${1:-}" cert_tmp key_tmp san_ext
    command -v openssl >/dev/null 2>&1 || return 1
    cert_tmp="$(mktemp "${CONFIG_DIR}/.web_cert.XXXXXX")" || return 1
    key_tmp="$(mktemp "${CONFIG_DIR}/.web_key.XXXXXX")" || { rm -f -- "$cert_tmp"; return 1; }
    san_ext="subjectAltName = DNS:localhost,IP:127.0.0.1"
    if [ -n "$current_ip" ] && is_public_ipv4 "$current_ip"; then
        san_ext="${san_ext},IP:${current_ip}"
    fi
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=rcgen self signed cert" \
        -addext "$san_ext" \
        -keyout "$key_tmp" -out "$cert_tmp" >/dev/null 2>&1; then
        if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -subj "/CN=rcgen self signed cert" \
            -keyout "$key_tmp" -out "$cert_tmp" >/dev/null 2>&1; then
            rm -f -- "$cert_tmp" "$key_tmp"
            return 1
        fi
    fi
    mv -f -- "$cert_tmp" "$CERT_PATH"
    mv -f -- "$key_tmp" "$KEY_PATH"
    chmod 644 "$CERT_PATH"
    chmod 600 "$KEY_PATH"
    rm -f -- "$STATE_FILE"
}

fallback_if_expired() {
    local current_ip="${1:-}"
    if certificate_is_expired; then
        log "Let’s Encrypt: текущий сертификат истёк; активируется fallback rcgen сертификат"
        if generate_rcgen_fallback "$current_ip"; then
            reload_csqtt_tls
            log "Let’s Encrypt: fallback rcgen сертификат успешно активирован"
        fi
    fi
}

install_certificate() {
    local mode="$1" identifier="$2" cert_name="$3" source_dir cert_tmp key_tmp state_tmp
    source_dir="${LE_ROOT}/live/${cert_name}"
    [ -s "$source_dir/fullchain.pem" ] && [ -s "$source_dir/privkey.pem" ] || return 1
    cert_tmp="$(mktemp "${CONFIG_DIR}/.web_cert.XXXXXX")" || return 1
    key_tmp="$(mktemp "${CONFIG_DIR}/.web_key.XXXXXX")" || { rm -f -- "$cert_tmp"; return 1; }
    state_tmp="$(mktemp "${CONFIG_DIR}/.letsencrypt.XXXXXX")" || { rm -f -- "$cert_tmp" "$key_tmp"; return 1; }
    if ! install -m 0644 "$source_dir/fullchain.pem" "$cert_tmp" || ! install -m 0600 "$source_dir/privkey.pem" "$key_tmp"; then
        rm -f -- "$cert_tmp" "$key_tmp" "$state_tmp"
        return 1
    fi
    printf 'MODE=%s\nIDENTIFIER=%s\nCERT_NAME=%s\n' "$mode" "$identifier" "$cert_name" > "$state_tmp"
    chmod 0600 "$state_tmp"
    # State последним: при неудачной активации файлов состояние не должно
    # объявлять режим, которому диск не соответствует.
    mv -f -- "$cert_tmp" "$CERT_PATH"
    mv -f -- "$key_tmp" "$KEY_PATH"
    mv -f -- "$state_tmp" "$STATE_FILE"
    chmod 644 "$CERT_PATH"
    chmod 600 "$KEY_PATH" "$STATE_FILE"
}

reload_csqtt_tls() {
    if [ "$SERVICE_MANAGER" = "docker" ]; then
        docker kill --signal USR1 csqtt >/dev/null 2>&1 || return 0
    else
        systemctl kill --kill-who=main --signal USR1 csqtt >/dev/null 2>&1 || return 0
    fi
}

main() {
    local mode identifier cert_name
    mode="$(panel_mode)"
    # В доменном режиме без state нечего продлевать: самоподписанный откат
    # запрещён, панель должна честно дождаться переустановки. Проверка идёт до
    # разбора сертификата, иначе свой же старый сертификат был бы принят за
    # пользовательский и причина молчания осталась бы невнятной.
    if [ "$mode" = "domain" ] && [ ! -f "$STATE_FILE" ]; then
        log "Let’s Encrypt: режим домена, но ${STATE_FILE} отсутствует; сертификат не обновляется. Повторите установку, чтобы восстановить состояние"
        return 0
    fi
    if [ -s "$CERT_PATH" ] && ! certificate_is_csqtt_managed; then
        log "Let’s Encrypt: обнаружен пользовательский TLS-сертификат; CSQTT не изменяет его и отключает собственное продление"
        return 0
    fi
    identifier="$(current_identifier 2>/dev/null || true)"
    if [ -z "$CERTBOT" ] || [ ! -x "$CERTBOT" ]; then
        log "Let’s Encrypt: Certbot не найден, обновление отложено"
        [ "$mode" = "domain" ] || fallback_if_expired "$identifier"
        return 0
    fi
    if [ -z "$identifier" ]; then
        log "Let’s Encrypt: публичный адрес не определён, обновление отложено"
        [ "$mode" = "domain" ] || fallback_if_expired ""
        return 0
    fi
    if ! needs_renewal "$identifier"; then
        return 0
    fi
    if ss -ltnH "sport = :${HTTP_PORT}" 2>/dev/null | grep -q .; then
        log "Let’s Encrypt: TCP/${HTTP_PORT} занят, обновление отложено"
        [ "$mode" = "domain" ] || fallback_if_expired "$identifier"
        return 0
    fi
    cert_name="$(cert_name_for "$mode" "$identifier")"
    if [ "$mode" = "domain" ]; then
        if ! timeout 90 "$CERTBOT" certonly --standalone --http-01-port "$HTTP_PORT" --non-interactive --agree-tos --register-unsafely-without-email --domains "$identifier" --cert-name "$cert_name" --force-renewal; then
            log "Let’s Encrypt: перевыпуск сертификата для домена ${identifier} не удался, текущий сертификат сохранён; исправьте причину и повторите установку"
            return 0
        fi
    else
        if ! timeout 90 "$CERTBOT" certonly --standalone --http-01-port "$HTTP_PORT" --non-interactive --agree-tos --register-unsafely-without-email --preferred-profile shortlived --ip-address "$identifier" --cert-name "$cert_name" --force-renewal; then
            if ! timeout 90 "$CERTBOT" certonly --standalone --http-01-port "$HTTP_PORT" --non-interactive --agree-tos --register-unsafely-without-email --ip-address "$identifier" --cert-name "$cert_name" --force-renewal; then
                log "Let’s Encrypt: перевыпуск IP-сертификата не удался, текущий сертификат сохранён"
                fallback_if_expired "$identifier"
                return 0
            fi
        fi
    fi
    if ! install_certificate "$mode" "$identifier" "$cert_name"; then
        log "Let’s Encrypt: не удалось безопасно активировать новый сертификат"
        [ "$mode" = "domain" ] || fallback_if_expired "$identifier"
        return 0
    fi
    reload_csqtt_tls
    log "Let’s Encrypt: сертификат обновлён и TLS-конфигурация CSQTT перезагружена"
}

main "$@"
LEHELPER
    chmod 0755 "$CSQTT_LE_RENEW_HELPER"
}

install_letsencrypt_renewal_timer() {
    rm -f -- "${CSQTT_CRON_DIR}/csqtt-letsencrypt"
    command -v systemctl >/dev/null 2>&1 || {
        log_warn "systemd не найден: автоматическое продление Let’s Encrypt требует systemd"
        return 0
    }
    cat > "${CSQTT_SYSTEMD_DIR}/${CSQTT_LE_SERVICE}" << LEUNIT
[Unit]
Description=Renew CSQTT Let’s Encrypt certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=CSQTT_DEPLOY_MODE=${DEPLOY_MODE}
Environment=CSQTT_LE_CERTBOT=${LE_CERTBOT_COMMAND}
Environment=CSQTT_LE_RENEW_BEFORE_SECONDS=${LE_RENEW_BEFORE_SECONDS}
Environment=CSQTT_LE_ROOT=${CSQTT_LE_ROOT}
Environment=CSQTT_LE_IDENTIFIER=${PANEL_HOST:-}
ExecStart=${CSQTT_LE_RENEW_HELPER}
LEUNIT
    cat > "${CSQTT_SYSTEMD_DIR}/${CSQTT_LE_TIMER}" << LETIMER
[Unit]
Description=Check CSQTT Let’s Encrypt certificate lifetime

[Timer]
OnBootSec=5min
OnUnitInactiveSec=24h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
LETIMER
    systemctl daemon-reload || {
        log_warn "Не удалось обновить systemd unit для Let’s Encrypt"
        return 0
    }
    systemctl enable --now "$CSQTT_LE_TIMER" >/dev/null 2>&1 || \
        log_warn "Не удалось включить автоматическое продление Let’s Encrypt"
}

# Доменный режим: сертификат Let’s Encrypt для PANEL_HOST на порту 443.
# Любая неудача — die. Самоподписанного отката здесь нет: тихая подмена
# сертификата в доменном режиме запрещена решением владельца 4.
setup_domain_web_panel_tls() {
    local identifier="${PANEL_HOST:-}" cert_name
    if ! ensure_letsencrypt_client; then
        die "Certbot с поддержкой --domains недоступен: без него нельзя выпустить сертификат для ${identifier}. Установите certbot и повторите установку. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера"
    fi
    write_letsencrypt_renewal_helper
    assert_letsencrypt_http_port_is_available
    if letsencrypt_certificate_is_current "$identifier"; then
        log_info "Let’s Encrypt сертификат для домена ${identifier} действителен; перевыпуск не требуется"
    else
        cert_name="$(letsencrypt_cert_name "$identifier")"
        issue_letsencrypt_certificate "$LE_CERTBOT_COMMAND" "$identifier" "$cert_name"
    fi
    # Легаси-файл letsencrypt-ip.env больше не читается: установки 2.5.2+ держат
    # состояние только в letsencrypt.env, а чужой файл в каталоге данных остаётся
    # нетронутым (whitelist) — это данные пользователя, не мусор импорта.
    install_letsencrypt_renewal_timer
}

setup_web_panel_tls() {
    local public_ip cert_name
    if ! certificate_is_csqtt_letsencrypt && adopt_letsencrypt_certificate; then
        log_info "Let’s Encrypt-сертификат CSQTT принят под автоматическое продление"
    fi
    if web_certificate_is_user_managed; then
        rm -f -- "$CSQTT_LE_STATE_FILE"
        disable_letsencrypt_renewal_timer
        log_info "Используется заранее установленный TLS-сертификат пользователя; CSQTT сохраняет его и не заменяет Let’s Encrypt"
        return 0
    fi
    if [ "${PANEL_MODE:-ip}" = "domain" ]; then
        setup_domain_web_panel_tls
        return 0
    fi
    public_ip="${PANEL_HOST:-}"
    if ! is_public_ipv4 "$public_ip"; then
        public_ip="$(detect_public_ipv4 2>/dev/null || true)"
    fi
    if [ -z "$public_ip" ]; then
        public_ip="$(state_value IDENTIFIER 2>/dev/null || true)"
    fi
    if ! ensure_letsencrypt_client; then
        if [ ! -s "$CSQTT_CONFIG_DIR/web_cert.pem" ] || ! openssl x509 -noout -checkend 0 -in "$CSQTT_CONFIG_DIR/web_cert.pem" >/dev/null 2>&1; then
            generate_rcgen_fallback_certificate "$public_ip" || true
        fi
        return 0
    fi
    write_letsencrypt_renewal_helper
    if [ -z "$public_ip" ]; then
        log_warn "Публичный IPv4 не определён; WEB-панель временно останется на self-signed TLS"
        if [ ! -s "$CSQTT_CONFIG_DIR/web_cert.pem" ] || ! openssl x509 -noout -checkend 0 -in "$CSQTT_CONFIG_DIR/web_cert.pem" >/dev/null 2>&1; then
            generate_rcgen_fallback_certificate "" || true
        fi
        install_letsencrypt_renewal_timer
        return 0
    fi
    if letsencrypt_certificate_is_current "$public_ip"; then
        log_info "Let’s Encrypt IP-сертификат действителен; перевыпуск не требуется"
    else
        cert_name="$(letsencrypt_cert_name "$public_ip")"
        if ! issue_letsencrypt_certificate "$LE_CERTBOT_COMMAND" "$public_ip" "$cert_name"; then
            if [ ! -s "$CSQTT_CONFIG_DIR/web_cert.pem" ] || ! openssl x509 -noout -checkend 0 -in "$CSQTT_CONFIG_DIR/web_cert.pem" >/dev/null 2>&1; then
                generate_rcgen_fallback_certificate "$public_ip" || true
            fi
        fi
    fi
    install_letsencrypt_renewal_timer
}

# Две дешёвые проверки доменного режима. Выполняются ДО csqtt_cleanup: если порт
# 80 занят или certbot не умеет --domains, установка падает, не трогая
# работающую панель.
run_domain_mode_preflight() {
    [ "${PANEL_MODE:-}" = "domain" ] || return 0
    assert_letsencrypt_http_port_is_available
    assert_domain_points_to_this_server
    if ! ensure_letsencrypt_client; then
        die "Certbot с поддержкой --domains недоступен: без него нельзя выпустить сертификат для ${PANEL_HOST}. Установите certbot и повторите установку. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера"
    fi
}

verify_web_panel() {
    local scheme code probe_file probe_dir
    # Проба не должна оставлять файл в общем /tmp: используем work-dir
    # установщика, если он уже создан, иначе mktemp с TMPDIR.
    probe_dir="${CSQTT_WORK_DIR:-${TMPDIR:-/tmp}}"
    [ -d "$probe_dir" ] || probe_dir="${TMPDIR:-/tmp}"
    probe_file="$(mktemp "${probe_dir%/}/csqtt-web-probe.XXXXXX")" || \
        die "Не удалось создать временный файл health-проверки" "$EXIT_PREFLIGHT_FAILED"
    local secret_path="${CSQTT_WEB_SECRET_PATH:-}"
    if [ -z "$secret_path" ] && [ -f "$CSQTT_ENV_FILE" ]; then
        secret_path="$(grep -E '^[[:space:]]*(export[[:space:]]+)?CSQTT_WEB_SECRET_PATH=' "$CSQTT_ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"' | tr -d "'\"'" | tr -d '[:space:]' || true)"
    fi
    local probe_path=""
    if [ -n "$secret_path" ]; then
        probe_path="${secret_path#/}"
    fi

    # Общий дедлайн, а не число попыток: при быстром «connection refused»
    # (контейнер ещё стартует) 24 итерации исчерпывались за ~6 секунд, и
    # установка откатывалась до того, как Docker-контейнер успевал открыть порт.
    local deadline=$((SECONDS + ${CSQTT_WEB_PROBE_SECONDS:-60}))
    while ((SECONDS < deadline)); do
        for scheme in https http; do
            code="$(curl -k -sS -o "$probe_file" -w "%{http_code}" \
                --connect-timeout 1 --max-time 2 \
                "${scheme}://127.0.0.1:${WEB_PORT}/${probe_path}" 2>>"$LOG_FILE" || true)"
            case "$code" in
                200|301|302|401)
                    rm -f -- "$probe_file"
                    log_info "WEB-панель ответила локальной health-проверке (${scheme}, HTTP ${code})"
                    return 0
                    ;;
            esac
        done
        sleep 0.5
    done
    rm -f -- "$probe_file"
    die "WEB-панель не ответила на локальную health-проверку порта ${WEB_PORT} за ${CSQTT_WEB_PROBE_SECONDS:-60}с"
}

ensure_docker() {
    log_step "Проверка Docker Engine..."

    if ! command -v docker >/dev/null 2>&1; then
        pkg_update
        if [ "$PKG_MGR" = "pacman" ]; then
            pkg_install docker || die "Не удалось установить Docker Engine"
        else
            pkg_install ca-certificates curl || die "Не удалось установить curl и ca-certificates для Docker"
            local installer
            installer="$(mktemp)"
            curl -fsSL https://get.docker.com -o "$installer" || die "Не удалось загрузить официальный установщик Docker"
            sh "$installer" >>"$LOG_FILE" 2>&1 || {
                rm -f "$installer"
                die "Не удалось установить Docker Engine"
            }
            rm -f "$installer"
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >>"$LOG_FILE" 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service docker start >>"$LOG_FILE" 2>&1 || true
    fi

    docker --version | tee -a "$LOG_FILE"
    docker info >>"$LOG_FILE" 2>&1 || die "Docker установлен, но демон недоступен; проверьте docker info"
    log_info "Docker Engine готов"
}

ensure_tun_device() {
    if [ -c /dev/net/tun ]; then
        chmod 666 /dev/net/tun 2>/dev/null || true
        return 0
    fi
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tun >>"$LOG_FILE" 2>&1 || true
    fi
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 >>"$LOG_FILE" 2>&1 || true
    [ -c /dev/net/tun ] || die "Устройство /dev/net/tun недоступно на этом VPS"
    chmod 666 /dev/net/tun 2>/dev/null || true
}

check_kernel_compatibility() {
    [ "$(uname -s)" = "Linux" ] || die "CSQTT Server поддерживает только Linux"
    local release base major minor
    release="$(uname -r)"
    base="${release%%-*}"
    major="${base%%.*}"
    base="${base#*.}"
    minor="${base%%.*}"
    case "$major:$minor" in
        *[!0-9:]*|:*) log_warn "Не удалось разобрать версию ядра $release; решающей будет рабочая проверка TUN" ;;
        *)
            if [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -lt 5 ]; }; then
                log_warn "Ядро $release старше проверенного диапазона 5.5–7.x; установка продолжится только при успешных рабочих пробах"
            else
                log_info "Ядро Linux $release входит в поддерживаемый диапазон"
            fi
            ;;
    esac
}

load_kernel_network_modules() {
    command -v modprobe >/dev/null 2>&1 || return 0
    local module
    for module in tun nf_tables ip_tables iptable_filter iptable_nat iptable_mangle nf_nat nf_conntrack xt_comment xt_MASQUERADE xt_TCPMSS; do
        modprobe "$module" >>"$LOG_FILE" 2>&1 || true
    done
}

probe_tun_support() {
    ensure_tun_device
    local probe_iface="cqtprobe$(( $$ % 100000 ))"
    ip link del "$probe_iface" >>"$LOG_FILE" 2>&1 || true
    if ! ip tuntap add dev "$probe_iface" mode tun >>"$LOG_FILE" 2>&1; then
        load_kernel_network_modules
        ip link del "$probe_iface" >>"$LOG_FILE" 2>&1 || true
        if ! ip tuntap add dev "$probe_iface" mode tun >>"$LOG_FILE" 2>&1; then
            die "TUN существует, но ядро или политика VPS запрещает TUNSETIFF/CAP_NET_ADMIN"
        fi
    fi
    if ! ip link del "$probe_iface" >>"$LOG_FILE" 2>&1; then
        die "Рабочий TUN создан, но тестовый интерфейс $probe_iface не удалось удалить"
    fi
    log_info "TUN проверен реальным созданием и удалением интерфейса"
}

# Читающая проверка NAT/firewall до cutover: подтверждает, что WAN-интерфейс
# существует и таблица nat доступна, но не меняет ни одного правила.
probe_nat_and_firewall() {
    DEPLOY_PHASE="preflight"
    log_step "Проверка NAT и firewall до переключения runtime..."
    detect_firewall
    local iface
    iface="$(detect_wan_interface 2>/dev/null || true)"
    [ -n "$iface" ] || \
        die "Не удалось определить WAN-интерфейс для NAT подсети 10.66.67.0/24" "$EXIT_PREFLIGHT_FAILED"
    ip link show "$iface" >/dev/null 2>&1 || \
        die "Определённый WAN-интерфейс $iface не существует" "$EXIT_PREFLIGHT_FAILED"
    iptables -w "$XT_WAIT" -t nat -S POSTROUTING >/dev/null 2>&1 || \
        die "Таблица nat iptables недоступна: без неё невозможен MASQUERADE для TUN" "$EXIT_PREFLIGHT_FAILED"
    log_info "NAT/firewall проверены: WAN $iface, таблица nat доступна"
}

run_platform_preflight() {
    prog 0.35 "Совместимость ядра..."
    log_step "Проверка совместимости ядра и VPS..."
    check_kernel_compatibility
    probe_tun_support
}

# A-запись домена обязана указывать на публичный IP этого сервера: иначе
# HTTP-01 не пройдёт, а Cloudflare-прокси подменит адрес. AAAA не требуется.
resolve_a_record_addresses() {
    local host="$1" addresses="" timeout_cmd=()
    # Битый или медленный резолвер не должен подвешивать установку.
    if command -v timeout >/dev/null 2>&1; then
        timeout_cmd=(timeout 5)
    fi
    if command -v getent >/dev/null 2>&1; then
        addresses="$(${timeout_cmd[@]+"${timeout_cmd[@]}"} getent ahosts "$host" 2>/dev/null | awk '$2 == "STREAM" { print $1 }' | sort -u || true)"
    fi
    if [ -z "$addresses" ] && command -v dig >/dev/null 2>&1; then
        addresses="$(${timeout_cmd[@]+"${timeout_cmd[@]}"} dig +short A "$host" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u || true)"
    fi
    printf '%s\n' "$addresses"
}

# prompt_panel_host_choice <detected_ip> — интерактивный выбор адреса панели.
# Печатает выбранный host (домен или IP) в stdout; вопросы и предупреждения
# идут в stderr, поэтому результат можно ловить через $(...).
# Домен проверяется по A-записи сразу: иначе Let's Encrypt упадёт на cutover,
# уже после снимка и остановки runtime.
prompt_panel_host_choice() {
    local detected="$1" answer="" candidate="" addresses=""
    while :; do
        read -r -p "Использовать домен для панели? [Y/n]: " answer || answer=""
        case "$answer" in
            "") break ;;
            y | Y | yes | YES | Yes) break ;;
            n | N | no | NO | No)
                printf '%s\n' "$detected"
                return 0
                ;;
            *) printf 'Ответьте y или n (Enter — да, домен)\n' >&2 ;;
        esac
    done
    while :; do
        read -r -p "Домен панели (Enter — остаться на IP ${detected}): " answer || answer=""
        if [ -z "$answer" ]; then
            printf '%s\n' "$detected"
            return 0
        fi
        candidate="$(normalize_panel_host_value "$answer")"
        if ! is_dns_hostname "$candidate"; then
            printf "Нужно доменное имя, например vpn.example.com (получено: '%s'; Enter — остаться на IP)\n" "$answer" >&2
            continue
        fi
        addresses="$(resolve_a_record_addresses "$candidate")"
        if printf '%s\n' "$addresses" | grep -qx -- "$detected"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        if [ -z "$addresses" ]; then
            printf 'У %s нет A-записи (нужна A → %s). Введите другой домен или Enter — остаться на IP.\n' \
                "$candidate" "$detected" >&2
        else
            printf 'A-запись %s: %s, сервер: %s. Исправьте DNS, введите другой домен или Enter — остаться на IP.\n' \
                "$candidate" "${addresses//$'\n'/, }" "$detected" >&2
        fi
    done
}

# prompt_panel_address_change <current> <detected_ip> — смена адреса на уже
# установленной панели. Принимает домен (с проверкой A-записи) или IP;
# пустой ответ оставляет текущий адрес. Печатает адрес в stdout.
prompt_panel_address_change() {
    local current="$1" detected="$2" answer="" candidate="" addresses=""
    while :; do
        read -r -p "Новый адрес панели: домен или IP (Enter — оставить ${current}): " answer || answer=""
        if [ -z "$answer" ]; then
            printf '%s\n' "$current"
            return 0
        fi
        candidate="$(normalize_panel_host_value "$answer")"
        if is_public_ipv4 "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        if ! is_dns_hostname "$candidate"; then
            printf "Нужен домен или публичный IP (получено: '%s'; Enter — оставить %s)\n" "$candidate" "$current" >&2
            continue
        fi
        if [ -z "$detected" ]; then
            # Публичный IP неизвестен — A-запись проверит preflight доменного режима.
            printf '%s\n' "$candidate"
            return 0
        fi
        addresses="$(resolve_a_record_addresses "$candidate")"
        if printf '%s\n' "$addresses" | grep -qx -- "$detected"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        if [ -z "$addresses" ]; then
            printf 'У %s нет A-записи (нужна A → %s). Введите другой адрес или Enter — оставить %s.\n' \
                "$candidate" "$detected" "$current" >&2
        else
            printf 'A-запись %s: %s, сервер: %s. Исправьте DNS, введите другой адрес или Enter — оставить %s.\n' \
                "$candidate" "${addresses//$'\n'/, }" "$detected" "$current" >&2
        fi
    done
}

assert_domain_points_to_this_server() {
    [ "${PANEL_MODE:-}" = "domain" ] || return 0
    local server_ip addresses
    server_ip="$(detect_public_ipv4 2>/dev/null || true)"
    [ -n "$server_ip" ] || \
        die "Не удалось определить публичный IP сервера для проверки A-записи домена ${PANEL_HOST}" "$EXIT_PREFLIGHT_FAILED"
    addresses="$(resolve_a_record_addresses "$PANEL_HOST")"
    if [ -z "$addresses" ]; then
        die "У домена ${PANEL_HOST} нет A-записи. Укажите A-запись на ${server_ip} и повторите установку. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера" "$EXIT_PREFLIGHT_FAILED"
    fi
    printf '%s\n' "$addresses" | grep -qx -- "$server_ip" || \
        die "A-запись ${PANEL_HOST} (${addresses//$'\n'/, }) не совпадает с публичным IP ${server_ip}. Cloudflare-прокси и подобные схемы не подходят: нужна прямая A-запись. Чтобы вернуть предыдущий режим, повторите установку, указав IP-адрес сервера" "$EXIT_PREFLIGHT_FAILED"
    log_info "A-запись ${PANEL_HOST} указывает на этот сервер (${server_ip})"
}

install_docker_boot_prerequisite() {
    command -v systemctl >/dev/null 2>&1 || \
        die "Docker-режим требует systemd для подготовки TUN до автозапуска контейнера"

    ensure_csqtt_directory "$CSQTT_LIB_DIR" 755
    cat > "$CSQTT_DOCKER_PREREQ_HELPER" << PREREQ
#!/bin/sh
set -eu

if [ ! -c /dev/net/tun ]; then
    command -v modprobe >/dev/null 2>&1 && modprobe tun || true
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200
fi

[ -c /dev/net/tun ] || exit 20
chmod 666 /dev/net/tun 2>/dev/null || true
mkdir -p "${CSQTT_RUN_DIR}"
chmod 0755 "${CSQTT_RUN_DIR}" 2>/dev/null || true
rm -f "${CSQTT_DOCKER_NETWORK_READY}"
touch /run/xtables.lock
chmod 600 /run/xtables.lock 2>/dev/null || true
PREREQ
    chmod 0755 "$CSQTT_DOCKER_PREREQ_HELPER"

    local unit_tmp
    unit_tmp="$(mktemp)"
    cat > "$unit_tmp" << PREREQUNIT
[Unit]
Description=Prepare CSQTT Docker TUN and xtables lock
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${CSQTT_DOCKER_PREREQ_HELPER}

[Install]
RequiredBy=docker.service
PREREQUNIT
    install -m 0644 "$unit_tmp" "${CSQTT_SYSTEMD_DIR}/${CSQTT_DOCKER_PREREQ_SERVICE}"
    rm -f "$unit_tmp"
    systemctl daemon-reload || die "Не удалось обновить systemd для Docker prerequisites"
    systemctl enable "$CSQTT_DOCKER_PREREQ_SERVICE" >/dev/null 2>&1 || \
        die "Не удалось включить Docker prerequisites"
    "$CSQTT_DOCKER_PREREQ_HELPER" || \
        die "Не удалось обновить Docker runtime prerequisites"
    systemctl start "$CSQTT_DOCKER_PREREQ_SERVICE" || \
        die "Не удалось подготовить TUN/xtables lock для Docker"
}

write_csqtt_dockerfile() {
    local target="$1"
    cat > "$target" << 'DOCKERFILE'
FROM alpine:3.21
ARG CSQTT_BUILD_DNS_PRIMARY
ARG CSQTT_BUILD_DNS_SECONDARY
RUN set -eu; if [ -n "${CSQTT_BUILD_DNS_PRIMARY:-}" ]; then printf 'nameserver %s\n' "$CSQTT_BUILD_DNS_PRIMARY" > /etc/resolv.conf; fi; if [ -n "${CSQTT_BUILD_DNS_SECONDARY:-}" ]; then printf 'nameserver %s\n' "$CSQTT_BUILD_DNS_SECONDARY" >> /etc/resolv.conf; fi; timeout -k 5s 120s apk add --no-cache --no-progress ca-certificates iproute2 iptables; rm -rf /var/cache/apk/*
COPY csqtt /usr/local/bin/csqtt
COPY network-up.sh /usr/local/lib/csqtt/network-up.sh
COPY tun-recover.sh /usr/local/lib/csqtt/tun-recover.sh
RUN chmod 0755 /usr/local/bin/csqtt /usr/local/lib/csqtt/network-up.sh /usr/local/lib/csqtt/tun-recover.sh
ENTRYPOINT ["/bin/sh", "-ec", "/usr/local/lib/csqtt/network-up.sh; /usr/local/lib/csqtt/tun-recover.sh; exec /usr/local/bin/csqtt \"$@\"", "--"]
DOCKERFILE
}

docker_build_candidate_image() {
    local image="$1" context_dir="$2" primary_log fallback_log
    primary_log="$(mktemp)" || return 1
    if timeout -k 15s "${DOCKER_BUILD_TIMEOUT_SECONDS}s" docker build --network host -t "$image" "$context_dir" >"$primary_log" 2>&1; then
        cat "$primary_log" >>"$LOG_FILE"
        rm -f -- "$primary_log"
        return 0
    fi
    cat "$primary_log" >>"$LOG_FILE"
    if ! grep -Eqi 'Temporary failure resolving|Could not resolve|Name or service not known|Connection timed out|Could not connect|Network is unreachable|Failed to fetch|apk|returned a non-zero code: 124' "$primary_log"; then
        rm -f -- "$primary_log"
        return 1
    fi
    rm -f -- "$primary_log"
    log_warn "Docker build не получил DNS через сеть VPS; повтор с резервными DNS Яндекса"
    fallback_log="$(mktemp)" || return 1
    if timeout -k 15s "${DOCKER_BUILD_TIMEOUT_SECONDS}s" docker build --network default \
        --build-arg CSQTT_BUILD_DNS_PRIMARY=77.88.8.8 \
        --build-arg CSQTT_BUILD_DNS_SECONDARY=77.88.8.1 \
        -t "$image" "$context_dir" >"$fallback_log" 2>&1; then
        cat "$fallback_log" >>"$LOG_FILE"
        rm -f -- "$fallback_log"
        log_info "Docker-образ собран через резервные DNS Яндекса"
        return 0
    fi
    cat "$fallback_log" >>"$LOG_FILE"
    rm -f -- "$fallback_log"
    return 1
}

prepare_docker_candidate() {
    local source_binary="$1" context_dir
    [ -x "$source_binary" ] || \
        die "Docker-образ нельзя собрать без установленного бинарника csqtt" "$EXIT_PREFLIGHT_FAILED"
    ensure_tun_device
    DOCKER_CONTEXT_DIR="$(mktemp -d /tmp/csqtt-docker.XXXXXX)" || \
        die "Не удалось создать Docker staging context" "$EXIT_PREFLIGHT_FAILED"
    context_dir="$DOCKER_CONTEXT_DIR"
    install -m 0755 "$source_binary" "$context_dir/csqtt" || \
        die "Не удалось подготовить Docker-бинарник" "$EXIT_PREFLIGHT_FAILED"
    write_network_helper "$context_dir/network-up.sh" || \
        die "Не удалось подготовить Docker network helper" "$EXIT_PREFLIGHT_FAILED"
    write_tun_recovery_helper "$context_dir/tun-recover.sh" || \
        die "Не удалось подготовить Docker TUN recovery helper" "$EXIT_PREFLIGHT_FAILED"
    write_csqtt_dockerfile "$context_dir/Dockerfile"

    CSQTT_DOCKER_CANDIDATE_IMAGE="${CSQTT_DOCKER_IMAGE}-candidate-$$"
    if ! docker_build_candidate_image "$CSQTT_DOCKER_CANDIDATE_IMAGE" "$context_dir"; then
        tail -n 80 "$LOG_FILE" | sed 's/^/   >> /' >&2 || true
        die "Сборка Docker-образа CSQTT завершилась ошибкой" "$EXIT_PREFLIGHT_FAILED"
    fi
    probe_docker_runtime "$CSQTT_DOCKER_CANDIDATE_IMAGE"
    remove_managed_work_dir "$DOCKER_CONTEXT_DIR" || true
    DOCKER_CONTEXT_DIR=""
    log_info "Docker-образ прошёл проверку: $CSQTT_DOCKER_CANDIDATE_IMAGE"
}

setup_csqtt_docker() {
    prog 0.75 "Docker-образ..."
    [ -n "$CSQTT_DOCKER_CANDIDATE_IMAGE" ] || \
        die "Не найден проверенный Docker-кандидат" "$EXIT_PREFLIGHT_FAILED"
    # Кандидат не получает основной тег до health-check: старый образ остаётся
    # нетронутым, пока новый runtime не подтвердил работоспособность.
    CSQTT_DOCKER_RUN_IMAGE="$CSQTT_DOCKER_CANDIDATE_IMAGE"
    install_docker_boot_prerequisite
    log_info "Проверенный Docker-образ будет активирован после health-check: $CSQTT_DOCKER_CANDIDATE_IMAGE"
}

probe_docker_runtime() {
    local image="${1:-$CSQTT_DOCKER_IMAGE}"
    local probe_iface="cqtd$(( $$ % 100000 ))" probe_chain="CSQTT_D$(( $$ % 1000000 ))" output
    if ! output="$(docker run --rm \
        --network host \
        --cap-drop ALL \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        --device /dev/net/tun:/dev/net/tun \
        --security-opt seccomp=unconfined \
        --env "PROBE_IFACE=$probe_iface" \
        --env "PROBE_CHAIN=$probe_chain" \
        --entrypoint /bin/sh \
        "$image" -ec '
ip tuntap add dev "$PROBE_IFACE" mode tun
ip link del "$PROBE_IFACE"
for table in filter nat mangle; do
    iptables -w 2 -t "$table" -N "$PROBE_CHAIN"
    iptables -w 2 -t "$table" -X "$PROBE_CHAIN"
done
' 2>&1)"; then
        printf '%s\n' "$output" >>"$LOG_FILE"
        die "Docker не прошёл рабочую проверку TUN или netfilter"
    fi
    printf '%s\n' "$output" >>"$LOG_FILE"
    log_info "Docker runtime проверен: TUN/netfilter"
}

run_csqtt_docker_container() {
    build_docker_env_args
    docker run -d \
        --name "$CSQTT_DOCKER_CONTAINER" \
        --label com.csqtt.managed=true \
        --label com.csqtt.component=server \
        --restart unless-stopped \
        --network host \
        --cap-drop ALL \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        --cap-add NET_BIND_SERVICE \
        --device /dev/net/tun:/dev/net/tun \
        --security-opt seccomp=unconfined \
        --stop-timeout 5 \
        --ulimit nofile=65535:65535 \
        ${DOCKER_ENV_ARGS[@]+"${DOCKER_ENV_ARGS[@]}"} \
        --env CSQTT_SERVICE_MANAGER=docker \
        --volume "$CSQTT_CONFIG_DIR:$CSQTT_CONFIG_DIR" \
        --mount "type=bind,src=${CSQTT_RUNTIME_DIR},dst=${CSQTT_RUNTIME_DIR}" \
        --mount "type=bind,src=/run/xtables.lock,dst=/run/xtables.lock" \
        "${CSQTT_DOCKER_RUN_IMAGE:-$CSQTT_DOCKER_IMAGE}" \
        --listen "0.0.0.0:${PEER_PORT}" \
        --web-port "$WEB_PORT" \
        --config-dir "$CSQTT_CONFIG_DIR" >>"$LOG_FILE" 2>&1 || \
        die "Не удалось создать Docker-контейнер CSQTT"
}

print_docker_deploy_summary() {
    local main_pid="$1"
    echo ""
    echo "✓ Деплой успешно завершён"
    echo "CSQTT_DEPLOY_OK"
    echo "   Режим:      Docker"
    echo "   Бинарник:   ${CSQTT_BIN_DIR}/csqtt"
    echo "   Конфиг:     ${CSQTT_CONFIG_DIR}"
    echo "   Контейнер:  ${CSQTT_DOCKER_CONTAINER}"
    echo "   Образ:      ${CSQTT_DOCKER_IMAGE}"
    echo "   PEER:       порт ${PEER_PORT}"
    echo "   SSH:        порт ${SSH_PORT}"
    echo "   WEB:        $(panel_web_port_label)"
    echo "   PID:        ${main_pid}"
    echo "   Логи:       docker logs -f ${CSQTT_DOCKER_CONTAINER}"
    echo "   Статус:     docker ps --filter name=${CSQTT_DOCKER_CONTAINER}"
    echo ""
}

start_csqtt_docker() {
    prog 0.90 "Запуск Docker..."
    ensure_tun_device
    remove_all_csqtt_docker_containers
    assert_peer_port_is_available
    remove_csqtt_tun_interface || die "Не удалось освободить TUN-интерфейс $CSQTT_IFACE перед запуском Docker"

    run_csqtt_docker_container

    local state running main_pid restarts candidate_pid=0 candidate_restarts=0 found=0
    local attempts=0
    while [ "$attempts" -lt 48 ]; do
        attempts=$((attempts + 1))
        state="$(docker inspect --format '{{.State.Running}}|{{.State.Pid}}|{{.RestartCount}}' "$CSQTT_DOCKER_CONTAINER" 2>/dev/null || echo 'false|0|-1')"
        IFS='|' read -r running main_pid restarts <<< "$state"
        case "$main_pid" in ''|*[!0-9]*) main_pid=0 ;; esac
        case "$restarts" in ''|*[!0-9]*) restarts=-1 ;; esac
        if [ "$running" = "true" ] && [ "$main_pid" -gt 1 ] && ip link show "$CSQTT_IFACE" >/dev/null 2>&1; then
            candidate_pid="$main_pid"
            candidate_restarts="$restarts"
            found=1
            break
        fi
        sleep 0.25
    done

    if [ "$found" -ne 1 ]; then
        docker logs --tail 50 "$CSQTT_DOCKER_CONTAINER" 2>&1 | sed 's/^/   >> /' || true
        die "Docker CSQTT не запустился или TUN $CSQTT_IFACE не создан"
    fi

    sleep "$START_STABILITY_SECONDS"
    state="$(docker inspect --format '{{.State.Running}}|{{.State.Pid}}|{{.RestartCount}}' "$CSQTT_DOCKER_CONTAINER" 2>/dev/null || echo 'false|0|-1')"
    IFS='|' read -r running main_pid restarts <<< "$state"
    if [ "$running" != "true" ] || [ "$main_pid" != "$candidate_pid" ] || [ "$restarts" != "$candidate_restarts" ] || \
       ! ip link show "$CSQTT_IFACE" >/dev/null 2>&1; then
        docker logs --tail 50 "$CSQTT_DOCKER_CONTAINER" 2>&1 | sed 's/^/   >> /' || true
        die "Docker CSQTT вошёл в crash-loop во время стабильной проверки"
    fi

    verify_configured_network
    verify_web_panel
    finish_deployment
    prog 1.0 "Готово!"
    print_docker_deploy_summary "$candidate_pid"
}

setup_csqtt_service() {
    prog 0.75 "Сервис..."
    echo "🔧 Создание systemd-сервиса CSQTT..."

    local unit_tmp
    unit_tmp="$(mktemp)"
    cat > "$unit_tmp" << CSQTTSVC
[Unit]
Description=CSQTT VPN Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
EnvironmentFile=-${CSQTT_ENV_FILE}
Environment=CSQTT_SERVICE_MANAGER=systemd
ExecStartPre=${CSQTT_LIB_DIR}/network-up.sh
ExecStartPre=${CSQTT_LIB_DIR}/tun-recover.sh
ExecStart=${CSQTT_BIN_DIR}/csqtt --listen 0.0.0.0:${PEER_PORT} --web-port ${WEB_PORT} --config-dir ${CSQTT_CONFIG_DIR}
Restart=on-failure
RestartSec=3
KillMode=control-group
TimeoutStartSec=30
TimeoutStopSec=5
Nice=-20

[Install]
WantedBy=multi-user.target
CSQTTSVC

    if [ ! -f "${CSQTT_SYSTEMD_DIR}/csqtt.service" ] || ! cmp -s "$unit_tmp" "${CSQTT_SYSTEMD_DIR}/csqtt.service"; then
        install -m 0644 "$unit_tmp" "${CSQTT_SYSTEMD_DIR}/csqtt.service"
        SYSTEMD_NEEDS_RELOAD=1
    fi
    rm -f "$unit_tmp"

    if [ "$SYSTEMD_NEEDS_RELOAD" -eq 1 ]; then
        systemctl daemon-reload || die "systemctl daemon-reload завершился ошибкой"
        SYSTEMD_NEEDS_RELOAD=0
    fi

    mkdir -p "${CSQTT_SYSTEMD_DIR}/multi-user.target.wants"
    ln -sfn "${CSQTT_SYSTEMD_DIR}/csqtt.service" "${CSQTT_SYSTEMD_DIR}/multi-user.target.wants/csqtt.service"
    echo "✓ Сервис csqtt.service создан и включён"
}

diagnose_systemd_failure() {
    local props result="unknown" exec_code="unknown" exec_status="unknown" restarts="unknown" active="unknown" sub="unknown" pid="0"
    props="$(systemctl show csqtt -p Result -p ExecMainCode -p ExecMainStatus -p NRestarts -p ActiveState -p SubState -p MainPID 2>/dev/null || true)"
    while IFS='=' read -r key value; do
        case "$key" in
            Result) result="$value" ;; ExecMainCode) exec_code="$value" ;; ExecMainStatus) exec_status="$value" ;;
            NRestarts) restarts="$value" ;; ActiveState) active="$value" ;; SubState) sub="$value" ;; MainPID) pid="$value" ;;
        esac
    done <<< "$props"
    log_error "systemd: active=$active/$sub result=$result code=$exec_code status=$exec_status restarts=$restarts pid=$pid"
    journalctl -u csqtt -b -n 50 --no-pager 2>/dev/null | sed 's/^/   >> /' | tee -a "$LOG_FILE" || true
}

print_systemd_deploy_summary() {
    local main_pid="$1"
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "✓ Деплой успешно завершён"
    echo "CSQTT_DEPLOY_OK"
    echo "   Режим: systemd"
    echo "   Бинарник: ${CSQTT_BIN_DIR}/csqtt"
    echo "   Unit: ${CSQTT_SYSTEMD_DIR}/csqtt.service"
    echo "   Конфиг: ${CSQTT_CONFIG_DIR}"
    echo "   NAT:  MASQUERADE (восстанавливается после reboot)"
    echo "   PEER: порт ${PEER_PORT}"
    echo "   SSH:  порт ${SSH_PORT}"
    echo "   WEB:  $(panel_web_port_label)"
    echo "   PID:  ${main_pid}"
    echo "   Логи:   journalctl -u csqtt -f"
    echo "   Статус: systemctl status csqtt"
    echo "══════════════════════════════════════════════════════════════"
    echo ""
}

start_csqtt() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        start_csqtt_docker
        return
    fi
    prog 0.90 "Запуск..."
    echo "🚀 Запуск CSQTT VPN Server..."

    [ -x "${CSQTT_BIN_DIR}/csqtt" ] || die "Исполняемый файл ${CSQTT_BIN_DIR}/csqtt не установлен"

    if ! systemctl start csqtt; then
        systemctl reset-failed csqtt >/dev/null 2>&1 || true
        if ! systemctl start csqtt; then
            diagnose_systemd_failure
            die "systemctl start csqtt завершился ошибкой"
        fi
    fi

    local props key value active sub main_pid restarts
    local candidate_pid=0 candidate_restarts=0 attempts=0 found=0
    while [ "$attempts" -lt 48 ]; do
        attempts=$((attempts + 1))
        active=""; sub=""; main_pid=0; restarts=0
        props="$(systemctl show csqtt -p ActiveState -p SubState -p MainPID -p NRestarts 2>/dev/null || true)"
        while IFS='=' read -r key value; do
            case "$key" in
                ActiveState) active="$value" ;; SubState) sub="$value" ;; MainPID) main_pid="$value" ;; NRestarts) restarts="$value" ;;
            esac
        done <<< "$props"
        case "$main_pid" in ''|*[!0-9]*) main_pid=0 ;; esac
        case "$restarts" in ''|*[!0-9]*) restarts=0 ;; esac

        if [ "$active" = "active" ] && [ "$sub" = "running" ] && [ "$main_pid" -gt 1 ] && \
           kill -0 "$main_pid" 2>/dev/null && ip link show "$CSQTT_IFACE" >/dev/null 2>&1; then
            candidate_pid="$main_pid"
            candidate_restarts="$restarts"
            found=1
            break
        fi
        sleep 0.25
    done

    if [ "$found" -ne 1 ]; then
        diagnose_systemd_failure
        die "CSQTT не запустился: сервис не running или TUN $CSQTT_IFACE не создан"
    fi

    sleep "$START_STABILITY_SECONDS"
    active=""; sub=""; main_pid=0; restarts=0
    props="$(systemctl show csqtt -p ActiveState -p SubState -p MainPID -p NRestarts 2>/dev/null || true)"
    while IFS='=' read -r key value; do
        case "$key" in
            ActiveState) active="$value" ;; SubState) sub="$value" ;; MainPID) main_pid="$value" ;; NRestarts) restarts="$value" ;;
        esac
    done <<< "$props"
    case "$main_pid" in ''|*[!0-9]*) main_pid=0 ;; esac
    case "$restarts" in ''|*[!0-9]*) restarts=0 ;; esac

    if [ "$active" != "active" ] || [ "$sub" != "running" ] || [ "$main_pid" != "$candidate_pid" ] || \
       [ "$restarts" != "$candidate_restarts" ] || ! kill -0 "$candidate_pid" 2>/dev/null || \
       ! ip link show "$CSQTT_IFACE" >/dev/null 2>&1; then
        diagnose_systemd_failure
        die "CSQTT вошёл в crash-loop или потерял TUN во время стабильной проверки"
    fi

    verify_configured_network
    verify_web_panel
    [ "$restarts" -eq 0 ] || log_warn "Во время старта csqtt перезапустился $restarts раз(а), затем стабилизировался"
    log_info "CSQTT сервер подтверждён: PID $candidate_pid, интерфейс $CSQTT_IFACE активен"
    finish_deployment

    prog 1.0 "Готово!"
    print_systemd_deploy_summary "$candidate_pid"
}

# ---------------------------------------------------------------------------
# csqttctl: status / credentials / logs / panel
# Эти команды не пишут в журнал установки: credentials печатает пароль панели,
# и он не должен оседать в /var/log/csqtt-install.log.
# ---------------------------------------------------------------------------

# Публичный адрес панели: https, host, порт (кроме 443) и secret path.
# Пустой stdout + exit 1 — адрес неизвестен (нет ни install.json, ни csqtt.env).
panel_url() {
    local host="${PANEL_HOST:-}" mode="${PANEL_MODE:-}" port secret
    [ -n "$host" ] || host="$(load_install_state panel_host 2>/dev/null || true)"
    [ -n "$host" ] || host="$(env_file_value CSQTT_PUBLIC_IP "$CSQTT_ENV_FILE" 2>/dev/null || true)"
    host="$(normalize_panel_host_value "$host")"
    [ -n "$host" ] || return 1
    [ -n "$mode" ] || mode="$(load_install_state panel_mode 2>/dev/null || true)"
    port="$(load_install_state web_port 2>/dev/null || true)"
    [ -n "$port" ] || port="${WEB_PORT:-443}"
    secret="${SECRET_PATH:-}"
    [ -n "$secret" ] || secret="$(env_file_value CSQTT_WEB_SECRET_PATH "$CSQTT_ENV_FILE" 2>/dev/null || true)"
    secret="${secret#/}"
    secret="${secret%/}"
    if [ "$port" = "443" ] || [ "$mode" = "domain" ]; then
        printf 'https://%s' "$host"
    else
        printf 'https://%s:%s' "$host" "$port"
    fi
    [ -z "$secret" ] || printf '/%s' "$secret"
    printf '\n'
}

# Параметр установки: state install.json, затем глобал из parse_cli/окружения.
status_state_value() {
    local key="$1" fallback="${2:-}" value
    value="$(load_install_state "$key" 2>/dev/null || true)"
    printf '%s\n' "${value:-$fallback}"
}

status_certificate_summary() {
    local cert="${CSQTT_CONFIG_DIR}/web_cert.pem" subject issuer enddate
    if [ ! -f "$cert" ]; then
        printf 'сертификат не найден (%s)\n' "$cert"
        return 0
    fi
    printf '%s' "$cert"
    command -v openssl >/dev/null 2>&1 || return 0
    subject="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=//' || true)"
    issuer="$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || true)"
    enddate="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
    [ -n "$subject" ] && printf '; subject: %s' "$subject"
    [ -n "$issuer" ] && printf '; issuer: %s' "$issuer"
    [ -n "$enddate" ] && printf '; до %s' "$enddate"
    printf '\n'
}

# Read-only: ни журнала, ни state, ни runtime не меняет.
do_status() {
    local mode version panel_mode service container tun
    mode="$(status_state_value mode)"
    [ -n "$mode" ] || mode="$(detect_existing_install 2>/dev/null || printf 'fresh')"
    version="$(status_state_value version)"
    panel_mode="$(status_state_value panel_mode)"
    printf 'Статус CSQTT:\n'
    printf '  Режим:      %s\n' "$mode"
    printf '  Установщик: %s\n' "$SCRIPT_VERSION"
    printf '  Установка:  %s\n' "${version:-неизвестна}"
    printf '  Порты:      туннель %s, панель %s, SSH %s\n' \
        "$(status_state_value peer_port "$PEER_PORT")" \
        "$(status_state_value web_port "$WEB_PORT")" \
        "$(status_state_value ssh_port "$SSH_PORT")"
    if [ -n "$panel_mode" ]; then
        case "$panel_mode" in
            domain) printf '  Панель:     домен\n' ;;
            ip) printf '  Панель:     IP\n' ;;
            *) printf '  Панель:     %s\n' "$panel_mode" ;;
        esac
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet csqtt 2>/dev/null; then
            service="активен"
        else
            service="не активен"
        fi
        printf '  Сервис:     %s\n' "$service"
    else
        printf '  Сервис:     systemd недоступен\n'
    fi
    if command -v docker >/dev/null 2>&1 && docker inspect "$CSQTT_DOCKER_CONTAINER" >/dev/null 2>&1; then
        if [ "$(docker inspect --format '{{.State.Running}}' "$CSQTT_DOCKER_CONTAINER" 2>/dev/null)" = "true" ]; then
            container="активен"
        else
            container="не активен"
        fi
    else
        container="не найден"
    fi
    printf '  Контейнер:  %s\n' "$container"
    if ip link show "$CSQTT_IFACE" >/dev/null 2>&1; then
        tun="активен"
    else
        tun="не активен"
    fi
    printf '  TUN:        %s (%s)\n' "$tun" "$CSQTT_IFACE"
    printf '  Сертификат: %s\n' "$(status_certificate_summary)"
}

# Креды и URL панели печатаются ровно один раз и только в stdout: не через
# log_* (tee) и не в install-журнал, иначе пароль осядет в /var/log.
print_panel_credentials_once() {
    local user pass url
    [ -f "$CSQTT_ENV_FILE" ] && [ -r "$CSQTT_ENV_FILE" ] || return 0
    user="$(env_file_value CSQTT_WEB_USER "$CSQTT_ENV_FILE" 2>/dev/null || true)"
    pass="$(env_file_value CSQTT_WEB_PASS "$CSQTT_ENV_FILE" 2>/dev/null || true)"
    [ -n "$user" ] && [ -n "$pass" ] || return 0
    url="$(panel_url 2>/dev/null || true)"
    printf '\n──────────────────────────────────────────────────────────────\n'
    printf 'Доступ к панели (пароль показан один раз):\n'
    [ -z "$url" ] || printf '  URL:     %s\n' "$url"
    printf '  Логин:   %s\n' "$user"
    printf '  Пароль:  %s\n' "$pass"
    printf '  Повтор:  csqttctl credentials\n'
    printf '──────────────────────────────────────────────────────────────\n'
}

# Только панельные доступы из csqtt.env + install.json. csqtt.db не читается:
# клиенты и их туннельные пароли — зона панели.
do_credentials() {
    local url user pass
    [ -f "$CSQTT_ENV_FILE" ] || \
        cli_error "Файл доступов не найден: $CSQTT_ENV_FILE"
    [ -r "$CSQTT_ENV_FILE" ] || \
        cli_error "Нет доступа к $CSQTT_ENV_FILE; запустите от root"
    if ! url="$(panel_url)"; then
        cli_error "Не удалось определить адрес панели: проверьте $CSQTT_INSTALL_STATE_FILE"
    fi
    user="$(env_file_value CSQTT_WEB_USER "$CSQTT_ENV_FILE" 2>/dev/null || true)"
    [ -n "$user" ] || cli_error "В $CSQTT_ENV_FILE нет CSQTT_WEB_USER"
    pass="$(env_file_value CSQTT_WEB_PASS "$CSQTT_ENV_FILE" 2>/dev/null || true)"
    [ -n "$pass" ] || cli_error "В $CSQTT_ENV_FILE нет CSQTT_WEB_PASS"
    printf 'Панель: %s\n' "$url"
    printf 'Логин:  %s\n' "$user"
    printf 'Пароль: %s\n' "$pass"
    printf '\nКлиенты, ссылки и QR создаются и меняются только в панели.\n'
    printf 'Туннельные пароли установщик не хранит и не печатает.\n'
    printf 'Если пароль панели меняли в панели, значение в %s устарело.\n' "$CSQTT_ENV_FILE"
}

# Журнал установки и лог сервера. -f/--follow — слежение за логом сервера.
do_logs() {
    local follow="${LOG_FOLLOW:-0}" mode
    mode="$(status_state_value mode)"
    [ -n "$mode" ] || mode="$(detect_existing_install 2>/dev/null || printf 'fresh')"
    if [ "$follow" = "1" ]; then
        if [ "$mode" = "docker" ] && command -v docker >/dev/null 2>&1 && \
           docker inspect "$CSQTT_DOCKER_CONTAINER" >/dev/null 2>&1; then
            printf 'Слежение за контейнером %s (Ctrl+C — выход)\n' "$CSQTT_DOCKER_CONTAINER"
            docker logs -f --tail 100 "$CSQTT_DOCKER_CONTAINER" 2>&1 || true
            return 0
        fi
        if command -v journalctl >/dev/null 2>&1; then
            printf 'Слежение за службой csqtt (Ctrl+C — выход)\n'
            journalctl -u csqtt -f -n 100 --no-pager 2>&1 || true
            return 0
        fi
        printf 'Слежение за %s (Ctrl+C — выход)\n' "$INSTALL_LOG_FILE"
        tail -n 100 -F -- "$INSTALL_LOG_FILE" 2>&1 || true
        return 0
    fi
    printf 'Журнал установки: %s\n' "$INSTALL_LOG_FILE"
    if [ -f "$INSTALL_LOG_FILE" ]; then
        tail -n 100 -- "$INSTALL_LOG_FILE" 2>/dev/null || true
    else
        printf '(журнал установки отсутствует)\n'
    fi
    if [ "$mode" = "docker" ] && command -v docker >/dev/null 2>&1 && \
       docker inspect "$CSQTT_DOCKER_CONTAINER" >/dev/null 2>&1; then
        printf '\nЛог контейнера %s:\n' "$CSQTT_DOCKER_CONTAINER"
        docker logs --tail 100 "$CSQTT_DOCKER_CONTAINER" 2>&1 || true
    elif command -v journalctl >/dev/null 2>&1; then
        printf '\nЛог службы csqtt:\n'
        journalctl -u csqtt -n 100 --no-pager 2>&1 || true
    fi
}

do_panel() {
    local url
    if ! url="$(panel_url)"; then
        cli_error "Не удалось определить адрес панели: проверьте $CSQTT_INSTALL_STATE_FILE"
    fi
    printf 'Панель: %s\n' "$url"
}

do_uninstall() {
    log_step "Удаление CSQTT..."

    remove_all_csqtt_docker_containers
    if command -v docker >/dev/null 2>&1; then
        timeout 5 docker image rm "$CSQTT_DOCKER_IMAGE" >/dev/null 2>&1 || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$CSQTT_LE_TIMER" >/dev/null 2>&1 || true
        systemctl stop "$CSQTT_LE_SERVICE" --no-block >/dev/null 2>&1 || true
        stop_csqtt_docker_prereq
        stop_all_running_csqtt_systemd_units
    fi
    force_stop_csqtt_processes || log_warn "Не все процессы CSQTT завершились до удаления runtime"
    remove_all_csqtt_systemd_units
    rm -f "${CSQTT_SYSTEMD_DIR}/${CSQTT_DOCKER_PREREQ_SERVICE}"
    rm -f "${CSQTT_SYSTEMD_DIR}/docker.service.requires/${CSQTT_DOCKER_PREREQ_SERVICE}"
    rm -f "${CSQTT_SYSTEMD_DIR}/docker.service.wants/${CSQTT_DOCKER_PREREQ_SERVICE}"
    rm -f "${CSQTT_SYSTEMD_DIR}/${CSQTT_LE_SERVICE}" "${CSQTT_SYSTEMD_DIR}/${CSQTT_LE_TIMER}" "${CSQTT_CRON_DIR}/csqtt-letsencrypt"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true

    remove_csqtt_tun_interface || log_warn "Не удалось удалить TUN-интерфейс $CSQTT_IFACE во время uninstall"
    cleanup_csqtt_netfilter_rules || true

    rm -f "${CSQTT_BIN_DIR}/csqtt" "$CSQTT_LE_RENEW_HELPER"
    rm -f -- "${CSQTT_BIN_DIR}/csqtt.previous"
    rm -rf "$CSQTT_RUN_DIR" "$CSQTT_LIB_DIR" "$CSQTT_VAR_DIR" "$CSQTT_OPT_DIR"
    rm -f "$CSQTT_SYSCTL_FILE" "$CSQTT_UDP_SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true

    # CLI — не runtime, поэтому снимается в обоих вариантах. State и БД трогает
    # только явный --purge, и /etc/letsencrypt (CSQTT_LE_ROOT) не трогает никогда.
    remove_cli_installation
    if [ "${PURGE:-0}" = "1" ]; then
        rm -rf -- "$CSQTT_CONFIG_DIR"
        log_info "CSQTT удалён вместе с конфигурацией ${CSQTT_CONFIG_DIR}; ${CSQTT_LE_ROOT} не тронут"
    else
        secure_persistent_state
        log_info "CSQTT удалён. SQLite state и конфигурация сохранены в ${CSQTT_CONFIG_DIR}"
    fi
}

handle_unexpected_error() {
    local line="$1" status="$2"
    trap - ERR
    log_error "Неперехваченная ошибка CSQTT install.sh (строка $line, exit=$status)"
    printf 'CSQTT_DEPLOY_ERROR|%s|Неперехваченная ошибка CSQTT install.sh (строка %s, exit=%s)\n' "$DEPLOY_PHASE" "$line" "$status"
    if [ "${ROLLBACK_ARMED:-0}" = "1" ]; then
        rollback_runtime "unexpected error at line ${line}"
    fi
    if [ "${RUNTIME_STOPPED:-0}" = "1" ]; then
        if ! restart_stopped_runtime; then
            log_error "Не удалось перезапустить прежний runtime после ошибки"
            printf 'CSQTT_DEPLOY_ROLLBACK_FAILED|%s|restart after stop failed\n' "$DEPLOY_PHASE"
            cleanup_deploy_artifacts
            exit 31
        fi
    fi
    cleanup_deploy_artifacts
    case "$DEPLOY_PHASE" in
        validation) exit "$EXIT_INVALID_ARGUMENT" ;;
        preflight) exit "$EXIT_PREFLIGHT_FAILED" ;;
        *) exit "$status" ;;
    esac
}

# INT/TERM — такой же триггер отката, как ошибка. До arming runtime уже может
# быть остановлен snapshot'ом, поэтому его возвращают; после arming — полный
# rollback с причиной «interrupted». Исходный код ошибки не маскируется: 130.
handle_deploy_signal() {
    local signal="$1"
    trap - ERR INT TERM
    log_warn "Получен $signal: установка прерывается"
    if [ "${ROLLBACK_ARMED:-0}" = "1" ]; then
        rollback_runtime "interrupted"
        return
    fi
    if [ "${RUNTIME_STOPPED:-0}" = "1" ]; then
        if ! restart_stopped_runtime; then
            log_error "Не удалось перезапустить прежний runtime после $signal"
            printf 'CSQTT_DEPLOY_ROLLBACK_FAILED|%s|restart after stop failed\n' "$DEPLOY_PHASE"
            cleanup_deploy_artifacts
            exit 31
        fi
    fi
    cleanup_deploy_artifacts
    printf 'CSQTT_DEPLOY_ERROR|%s|interrupted (%s)\n' "$DEPLOY_PHASE" "$signal"
    exit 130
}

trap 'handle_unexpected_error "$LINENO" "$?"' ERR
trap 'handle_deploy_signal INT' INT
trap 'handle_deploy_signal TERM' TERM

usage() {
    cat <<'USAGE'
CSQTT installer

Использование: install.sh [команда] [флаги]

Команды:
  install (по умолчанию)  установить или обновить, сохранив конфигурацию
  update                  скачать последний install.sh и обновить сервер
  status                  режим, версия, порты, служба/контейнер, TUN, сертификат
  credentials             повторно напечатать доступы панели (нужен root)
  logs [-f]               журнал установки и лог службы/контейнера
  panel                   напечатать URL панели
  uninstall [--purge]     остановить и удалить runtime; --purge удаляет /etc/csqtt
  version                 версия установщика
  help                    эта справка

Флаги:
  --host <ip|domain>      адрес панели; без флага — существующий или определённый IP
  --peer-port <n>         порт туннеля (46000)
  --web-port <n>          порт панели в IP-режиме (46002; в доменном всегда 443)
  --ssh-port <n>          SSH-порт для firewall (иначе из $SSH_CONNECTION или 22)
  --mode <systemd|docker> режим runtime; --docker — алиас --mode docker
  --web-user <login>      логин панели (fresh: случайные 10 символов)
  --web-pass-stdin        прочитать пароль панели из TTY (не из piped-скрипта)
  --secret-path <path>    секретный путь (fresh: случайные 16 символов)
  --version <vX.Y.Z>      версия релиза (по умолчанию SCRIPT_VERSION);
                          без команды и без значения печатает версию установщика
  --binary <path>         локальный бинарник (офлайн/тест); требует checksum
  --binary-sha256 <hex>   ожидаемый SHA-256 для --binary
  --allow-unverified-binary  явное исключение для --binary без checksum
  --reconfigure           разрешить смену host/портов/режима у существующей установки
  --force                 переустановить ту же версию
  --check                 только preflight, без изменений
  --purge                 с uninstall: удалить конфигурацию и БД (/etc/letsencrypt не трогается)
  --yes, --non-interactive  не задавать вопросы
USAGE
}

cli_error() {
    printf 'install.sh: %s\n' "$*" >&2
    exit "$EXIT_INVALID_ARGUMENT"
}

# parse_cli "$@" — единственный разбор argv. Выставляет глобалы, которые
# используют install_main и будущие задачи (state, download, subcommands).
# Режим tri-state: DEPLOY_MODE_EXPLICIT=1 только если --mode/--docker задан явно;
# без флага DEPLOY_MODE сохраняет значение окружения/дефолт (существующий режим
# подставит Task 3/6).
parse_cli() {
    ACTION="install"
    ACTION_SET=0
    HOST_OVERRIDE="${CSQTT_HOST:-}"
    HOST_EXPLICIT=0
    PEER_PORT="${CSQTT_PEER_PORT:-46000}"
    PEER_PORT_EXPLICIT=0
    SSH_PORT="${CSQTT_SSH_PORT:-22}"
    SSH_PORT_EXPLICIT=0
    WEB_PORT="${CSQTT_WEB_PORT:-46002}"
    WEB_PORT_EXPLICIT=0
    DEPLOY_MODE="${CSQTT_DEPLOY_MODE:-systemd}"
    DEPLOY_MODE_EXPLICIT=0
    # Пустые дефолты: fresh-значения генерируются позже, а env имеет приоритет.
    WEB_USER="${CSQTT_WEB_USER:-}"
    WEB_USER_EXPLICIT=0
    [ -z "$WEB_USER" ] || WEB_USER_EXPLICIT=1
    WEB_PASS="${CSQTT_WEB_PASS:-}"
    WEB_PASS_EXPLICIT=0
    [ -z "$WEB_PASS" ] || WEB_PASS_EXPLICIT=1
    SECRET_PATH="${CSQTT_WEB_SECRET_PATH:-}"
    SECRET_PATH_EXPLICIT=0
    [ -z "$SECRET_PATH" ] || SECRET_PATH_EXPLICIT=1
    PANEL_IDENTITY_PRESERVE=0
    VERSION_OVERRIDE=""
    BINARY_PATH=""
    BINARY_SHA256=""
    ALLOW_UNVERIFIED_BINARY=0
    RECONFIGURE=0
    FORCE=0
    CHECK_ONLY=0
    YES="${YES:-0}"
    WEB_PASS_STDIN=0
    PURGE=0
    LOG_FOLLOW=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            install|update|status|credentials|logs|panel|uninstall|version|help)
                [ "$ACTION_SET" -eq 0 ] || cli_error "лишняя команда: $1"
                ACTION="$1"
                ACTION_SET=1
                shift
                ;;
            --install|-i)
                [ "$ACTION_SET" -eq 0 ] || cli_error "лишняя команда: $1"
                ACTION="install"; ACTION_SET=1; shift
                ;;
            --update)
                [ "$ACTION_SET" -eq 0 ] || cli_error "лишняя команда: $1"
                ACTION="update"; ACTION_SET=1; shift
                ;;
            --status|-s)
                [ "$ACTION_SET" -eq 0 ] || cli_error "лишняя команда: $1"
                ACTION="status"; ACTION_SET=1; shift
                ;;
            --uninstall|-u)
                [ "$ACTION_SET" -eq 0 ] || cli_error "лишняя команда: $1"
                ACTION="uninstall"; ACTION_SET=1; shift
                ;;
            --help|-h)
                ACTION="help"; ACTION_SET=1; shift
                ;;
            --host)
                [ "$#" -ge 2 ] || cli_error "флаг --host требует значение"
                [ -n "$2" ] || cli_error "флаг --host требует непустое значение"
                HOST_OVERRIDE="$2"; HOST_EXPLICIT=1; shift 2
                ;;
            --peer-port)
                [ "$#" -ge 2 ] || cli_error "флаг --peer-port требует значение"
                PEER_PORT="$2"; PEER_PORT_EXPLICIT=1; shift 2
                ;;
            --ssh-port)
                [ "$#" -ge 2 ] || cli_error "флаг --ssh-port требует значение"
                SSH_PORT="$2"; SSH_PORT_EXPLICIT=1; shift 2
                ;;
            --web-port)
                [ "$#" -ge 2 ] || cli_error "флаг --web-port требует значение"
                WEB_PORT="$2"; WEB_PORT_EXPLICIT=1; shift 2
                ;;
            --mode)
                [ "$#" -ge 2 ] || cli_error "флаг --mode требует значение"
                case "$2" in
                    systemd|docker) ;;
                    *) cli_error "флаг --mode ожидает systemd или docker, получено: $2" ;;
                esac
                DEPLOY_MODE="$2"; DEPLOY_MODE_EXPLICIT=1; shift 2
                ;;
            --docker)
                DEPLOY_MODE="docker"; DEPLOY_MODE_EXPLICIT=1; shift
                ;;
            --web-user)
                [ "$#" -ge 2 ] || cli_error "флаг --web-user требует значение"
                WEB_USER="$2"; WEB_USER_EXPLICIT=1; shift 2
                ;;
            --web-pass-stdin)
                WEB_PASS_STDIN=1; WEB_PASS_EXPLICIT=1; shift
                ;;
            --secret-path)
                [ "$#" -ge 2 ] || cli_error "флаг --secret-path требует значение"
                SECRET_PATH="$2"; SECRET_PATH_EXPLICIT=1; shift 2
                ;;
            --version)
                if [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ]; then
                    VERSION_OVERRIDE="$2"; shift 2
                elif [ "$ACTION_SET" -eq 0 ]; then
                    ACTION="version"; ACTION_SET=1; shift
                else
                    cli_error "флаг --version требует значение"
                fi
                ;;
            --binary)
                [ "$#" -ge 2 ] || cli_error "флаг --binary требует значение"
                BINARY_PATH="$2"; shift 2
                ;;
            --binary-sha256)
                [ "$#" -ge 2 ] || cli_error "флаг --binary-sha256 требует значение"
                BINARY_SHA256="$2"; shift 2
                ;;
            --allow-unverified-binary)
                ALLOW_UNVERIFIED_BINARY=1; shift
                ;;
            --reconfigure)
                RECONFIGURE=1; shift
                ;;
            --force)
                FORCE=1; shift
                ;;
            --check)
                CHECK_ONLY=1; shift
                ;;
            --purge)
                PURGE=1; shift
                ;;
            -f|--follow)
                LOG_FOLLOW=1; shift
                ;;
            --yes|--non-interactive)
                YES=1; shift
                ;;
            -*)
                cli_error "unknown flag: $1"
                ;;
            *)
                cli_error "unknown command: $1"
                ;;
        esac
    done
    if [ "$PURGE" -eq 1 ] && [ "$ACTION" != "uninstall" ]; then
        cli_error "--purge допустим только с uninstall"
    fi
    if [ "$LOG_FOLLOW" -eq 1 ] && [ "$ACTION" != "logs" ]; then
        cli_error "-f/--follow допустим только с logs"
    fi
    if [ "$CHECK_ONLY" -eq 1 ] && [ "$ACTION" != "install" ] && [ "$ACTION" != "update" ]; then
        cli_error "--check допустим только с install/update"
    fi
}

# --check: только чтение. Никогда не создаёт каталог журнала, не пишет
# install.json и не трогает runtime; печатает разрешённую конфигурацию.
check_only_main() {
    # Все log_* и прямые >>"$LOG_FILE" должны попасть в /dev/null до первой
    # записи: иначе tee -a создаст каталог журнала (или упадёт).
    LOG_FILE=/dev/null
    DEPLOY_PHASE="preflight"
    validate_runtime_paths
    validate_binary_options
    case "$DEPLOY_MODE" in
        systemd|docker) ;;
        *) die "CSQTT_DEPLOY_MODE должен быть systemd или docker" "$EXIT_INVALID_ARGUMENT" ;;
    esac
    validate_port "CSQTT_PEER_PORT" "$PEER_PORT"
    validate_port "CSQTT_SSH_PORT" "$SSH_PORT"
    resolve_install_configuration
    # resolve_install_configuration работает в фазе validation; для --check
    # дальше снова preflight, иначе отказ preflight-проверки получит exit 2.
    DEPLOY_PHASE="preflight"
    # Неоднозначный state: --check печатает найденное и выходит 0, ничего не
    # домысливая (spec §4).
    if [ "${ADOPTION_AMBIGUOUS:-0}" -eq 1 ] && \
       { [ -z "${PANEL_MODE:-}" ] || [ -z "${PANEL_HOST:-}" ]; }; then
        print_installer_header
        printf 'Режим runtime: %s\n' "$DEPLOY_MODE"
        printf 'Панель: <не определена>\n'
        printf 'CSQTT_INSTALL_CHECK_OK|preflight завершён, изменения не вносились\n'
        return 0
    fi
    resolve_panel_mode
    validate_port "CSQTT_WEB_PORT" "$WEB_PORT"
    validate_positive_seconds "CSQTT_DOCKER_BUILD_TIMEOUT_SECONDS" "$DOCKER_BUILD_TIMEOUT_SECONDS"
    validate_distinct_network_ports
    check_runtime_requirements
    [ "${PANEL_MODE:-}" = "domain" ] && assert_domain_points_to_this_server

    print_installer_header
    printf 'Режим runtime: %s\n' "$DEPLOY_MODE"
    printf 'Панель: %s (%s), порт %s\n' "${PANEL_HOST:-}" "$(panel_web_mode_label)" "$WEB_PORT"
    printf 'Порт туннеля: %s\n' "$PEER_PORT"
    printf 'SSH-порт: %s\n' "$SSH_PORT"
    printf 'Версия: %s\n' "$SCRIPT_VERSION"
    # --check ничего не генерирует: сообщаем, что значения появятся при установке.
    if [ "${PANEL_IDENTITY_PRESERVE:-0}" -eq 0 ]; then
        if [ "${WEB_USER_EXPLICIT:-0}" -eq 1 ]; then
            printf 'Логин панели: %s\n' "$WEB_USER"
        else
            printf 'Логин панели: будет сгенерирован\n'
        fi
        if [ "${WEB_PASS_STDIN:-0}" -eq 1 ]; then
            printf 'Пароль панели: будет прочитан из TTY\n'
        elif [ "${WEB_PASS_EXPLICIT:-0}" -eq 1 ]; then
            printf 'Пароль панели: задан явно\n'
        else
            printf 'Пароль панели: будет сгенерирован\n'
        fi
        if [ "${SECRET_PATH_EXPLICIT:-0}" -eq 1 ]; then
            printf 'Secret path: %s\n' "$SECRET_PATH"
        else
            printf 'Secret path: будет сгенерирован\n'
        fi
    fi
    printf 'CSQTT_INSTALL_CHECK_OK|preflight завершён, изменения не вносились\n'
    return 0
}

# Установленный runtime уже на SCRIPT_VERSION. install.json — единственный
# источник версии установки; явно запрошенная другая версия делает no-op
# неприменимым и должна идти обычным путём (re-exec/загрузка).
install_is_already_current() {
    local version
    [ -z "${VERSION_OVERRIDE:-}" ] || return 1
    # Явная reconfiguration (флаг --reconfigure или интерактивная смена адреса)
    # не должна глушиться ранним выходом «версия уже последняя»: иначе смена
    # домена/S режима выглядит как успех, но ничего не делает.
    [ "${RECONFIGURE:-0}" -eq 1 ] && return 1
    version="$(load_install_state version 2>/dev/null || true)"
    [ -n "$version" ] && [ "$version" = "$SCRIPT_VERSION" ]
}

# Порядок шагов — spec §8. Проверки кандидата, TUN и NAT идут до csqtt_cleanup:
# сбой на них не должен стоить удаления работающего runtime.
install_main() {
    check_root
    require_tty_guard
    acquire_install_lock
    prepare_install_log
    echo "=== CSQTT Installer v${SCRIPT_VERSION} — $(date) ===" >> "$LOG_FILE"

    DEPLOY_PHASE="validation"
    read_web_password_if_requested
    validate_binary_options
    validate_runtime_paths
    case "$DEPLOY_MODE" in
        systemd|docker) ;;
        *) die "CSQTT_DEPLOY_MODE должен быть systemd или docker" ;;
    esac
    validate_port "CSQTT_PEER_PORT" "$PEER_PORT"
    validate_port "CSQTT_SSH_PORT" "$SSH_PORT"
    # Конфигурация разрешается до любых разрушительных шагов: state и csqtt.env
    # только читаются. install.json обновляет только финальный
    # write_install_state после успешной активации.
    resolve_install_configuration
    resolve_panel_mode
    # Повторная установка той же версии без --force ничего не меняет. Выход
    # обязан случиться до detect_os/пакетов/snapshot/csqtt_cleanup, иначе
    # «no-op» стоил бы простоя панели.
    if [ "${FORCE:-0}" -ne 1 ] && install_is_already_current; then
        print_installer_header
        log_info "CSQTT: уже последняя версия ${SCRIPT_VERSION}; переустановка не требуется (используйте --force)"
        printf 'CSQTT_INSTALL_ALREADY_CURRENT|%s\n' "$SCRIPT_VERSION"
        return 0
    fi
    # Баннер печатается после разбора режима: до него WEB_PORT ещё
    # равен значению телефона и в доменном режиме показывал бы 46002.
    print_installer_header
    validate_port "CSQTT_WEB_PORT" "$WEB_PORT"
    validate_positive_seconds "CSQTT_DOCKER_BUILD_TIMEOUT_SECONDS" "$DOCKER_BUILD_TIMEOUT_SECONDS"
    validate_distinct_network_ports

    local total_started=$SECONDS
    detect_os
    run_timed "зависимости" install_prerequisites
    require_runtime_tools
    if [ "$DEPLOY_MODE" = "docker" ]; then
        prog 0.12 "Docker..."
        run_timed "Docker" ensure_docker
    fi
    run_timed "sysctl" setup_sysctl
    run_timed "CPU mitigations" tune_cpu_mitigations

    # Кандидат скачивается и проверяется (checksum + --version) до любых
    # изменений runtime.
    run_timed "кандидат" prepare_candidate_release
    if [ -z "${BINARY_PATH:-}" ]; then
        run_timed "источник установщика" prepare_installer_source "$RELEASE_TAG"
        maybe_reexec_version "$RELEASE_TAG"
    fi
    if [ "$DEPLOY_MODE" = "docker" ]; then
        run_timed "Docker preflight" prepare_docker_candidate "$CANDIDATE_BINARY"
    fi
    run_domain_mode_preflight
    preserve_existing_csqtt_env

    # TUN и NAT проверяются рабочими пробами до cutover.
    run_timed "preflight" run_platform_preflight
    probe_nat_and_firewall

    # Снимок runtime — до csqtt_cleanup, и только после успешного снимка
    # взводится ROLLBACK_ARMED: до этого откатывать нечего, а сервер уже
    # остановлен snapshot'ом (RUNTIME_STOPPED=1), поэтому ошибка/сигнал в окне
    # возвращают прежний runtime.
    DEPLOY_PHASE="cutover"
    snapshot_runtime >/dev/null
    ROLLBACK_ARMED=1
    log_info "Снимок runtime готов; откат при ошибке взведён"

    run_timed "переключение runtime" csqtt_cleanup
    run_timed "NAT/firewall" setup_nat_and_firewall
    install_network_helper
    setup_csqtt_environment
    run_timed "Let’s Encrypt" setup_web_panel_tls
    DEPLOY_PHASE="activation"
    run_timed "бинарник" setup_csqtt_binary
    run_timed "принудительная остановка" force_stop_csqtt_processes
    # Порт панели проверяется после остановки старого runtime и до попытки
    # его занять. В docker-режиме контейнер стартует в setup_csqtt_docker,
    # и без этой проверки занятый 443 дал бы невнятный crash-loop вместо
    # прямого сообщения о занятом порте.
    assert_web_port_is_available
    if [ "$DEPLOY_MODE" = "docker" ]; then
        run_timed "Docker activation" setup_csqtt_docker
    else
        run_timed "systemd unit" setup_csqtt_service
    fi
    run_timed "запуск" start_csqtt
    install_cli
    write_install_state
    print_panel_credentials_once
    log_info "Общее время install.sh: $((SECONDS - total_started))с"
}

uninstall_main() {
    check_root
    # Тот же lock, что у install/update: uninstall не должен пересекаться с
    # идущим обновлением (иначе он снесёт runtime под работающим cutover).
    acquire_install_lock
    prepare_install_log
    echo "=== CSQTT Installer v${SCRIPT_VERSION} — $(date) ===" >> "$LOG_FILE"
    print_installer_header
    DEPLOY_PHASE="validation"
    validate_runtime_paths
    validate_port "CSQTT_PEER_PORT" "$PEER_PORT"
    do_uninstall
}

# status — только чтение: журнал установки не создаётся и не дописывается.
status_main() {
    LOG_FILE=/dev/null
    DEPLOY_PHASE="validation"
    do_status
}

main() {
    trap 'cleanup_installer_work_dir' EXIT
    # argv сохраняется до parse_cli: re-exec обязан пережить разбор флагов.
    INSTALLER_ARGV=("$@")
    parse_cli "$@"

    case "$ACTION" in
        install|update)
            if [ "$CHECK_ONLY" -eq 1 ]; then
                check_only_main
                return 0
            fi
            install_main
            ;;
        status)
            status_main
            ;;
        uninstall)
            uninstall_main
            ;;
        version)
            printf '%s\n' "$SCRIPT_VERSION"
            ;;
        help)
            usage
            ;;
        credentials)
            LOG_FILE=/dev/null
            do_credentials
            ;;
        logs)
            LOG_FILE=/dev/null
            do_logs
            ;;
        panel)
            LOG_FILE=/dev/null
            do_panel
            ;;
        *)
            cli_error "unknown command: $ACTION"
            ;;
    esac
}

if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
