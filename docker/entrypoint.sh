#!/bin/sh
# Self-provisioning entrypoint for the reCSQTT Docker image.
#
# The installer is not required: on the first start this script creates
# /etc/csqtt (identity, install.json, TLS pair), and the named volume keeps it
# across restarts. The server itself creates the SQLite database on first run.
# Later starts reuse the volume and only rebuild netfilter state, then exec the
# server. Ports come from install.json, so one image serves every installation.
set -eu

CONFIG_DIR=/etc/csqtt
ENV_FILE="$CONFIG_DIR/csqtt.env"
INSTALL_STATE="$CONFIG_DIR/install.json"
CSQTT_BIN=/usr/local/bin/csqtt
CSQTT_IFACE=csqtt1
CSQTT_SUBNET=10.66.67.0/24
IPT_COMMENT=CSQTT_MANAGED
LE_HTTP_PORT=80
XT_WAIT=2
DEFAULT_PEER_PORT=46000
IP_WEB_PORT=46002
DOMAIN_WEB_PORT=443
NETWORK_READY_FILE=/run/csqtt/docker-network.ready

log() { printf '[recsqtt] %s\n' "$*" >&2; }
warn() { printf '[recsqtt] warning: %s\n' "$*" >&2; }
die() {
    printf '[recsqtt] error: %s\n' "$*" >&2
    exit 1
}

json_get() {
    key=$1
    file=$2
    [ -n "$key" ] || return 1
    case "$key" in
        *[!A-Za-z0-9_]*) return 1 ;;
    esac
    [ -f "$file" ] || return 1
    grep -Eq "\"${key}\"[[:space:]]*:" "$file" || return 1
    sed -n -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/p" "$file" | head -n 1
}

# csqtt.env is written in systemd EnvironmentFile form: KEY="value".
env_file_value() {
    key=$1
    file=$2
    [ -n "$key" ] && [ -f "$file" ] || return 1
    line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | head -n 1 || true)
    [ -n "$line" ] || return 1
    value=${line#*=}
    case "$value" in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    value=$(printf '%s' "$value" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g')
    printf '%s\n' "$value"
}

# Same systemd-quoting as scripts/install.sh environment_value().
env_quote() {
    printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

is_ipv4() {
    case "$1" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    _oldifs=$IFS
    IFS=.
    # shellcheck disable=SC2086  # word splitting is the point here
    set -- $1
    IFS=$_oldifs
    [ "$#" -eq 4 ] || return 1
    for octet in "$@"; do
        case "$octet" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$octet" -le 255 ] || return 1
    done
    return 0
}

is_private_ipv4() {
    case "$1" in
        10.*|127.*|0.*|169.254.*|192.168.*)
            return 0
            ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
            return 0
            ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)
            return 0
            ;;
    esac
    return 1
}

detect_public_ipv4() {
    ip -4 route get 8.8.8.8 2>/dev/null | \
        awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

normalize_host() {
    host=$(printf '%s' "$1" | tr -d '[:space:]')
    case "$host" in
        http://*) host=${host#http://} ;;
        https://*) host=${host#https://} ;;
    esac
    host=${host%%/*}
    printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

valid_host() {
    [ -n "$1" ] && [ "${#1}" -le 253 ] || return 1
    case "$1" in
        *[!A-Za-z0-9.-]*) return 1 ;;
        .*|*.|*-.*|*.-*) return 1 ;;
        0.0.0.0|255.255.255.255) return 1 ;;
    esac
    return 0
}

random_alnum() {
    random_length=$1
    random_value=""
    random_attempt=1
    while [ "${#random_value}" -lt "$random_length" ] && [ "$random_attempt" -le 20 ]; do
        random_chunk=$(openssl rand -base64 96 2>/dev/null | tr -dc 'A-Za-z0-9' || true)
        if [ -z "$random_chunk" ] && [ -r /dev/urandom ]; then
            random_chunk=$(head -c 96 /dev/urandom | base64 2>/dev/null | tr -dc 'A-Za-z0-9' || true)
        fi
        random_value=$random_value$random_chunk
        random_attempt=$((random_attempt + 1))
    done
    [ "${#random_value}" -ge "$random_length" ] || return 1
    printf '%s' "$random_value" | cut -c1-"$random_length"
}

server_version() {
    version=$("$CSQTT_BIN" --version 2>/dev/null | head -n 1 | awk '{print $2}' || true)
    [ -n "$version" ] || version=unknown
    printf '%s' "$version"
}

write_env_file() {
    env_tmp=$(mktemp "$CONFIG_DIR/.csqtt.env.XXXXXX") || die "cannot create temporary csqtt.env"
    chmod 0600 "$env_tmp" || die "cannot protect temporary csqtt.env"
    if ! {
        printf 'CSQTT_WEB_USER=%s\n' "$(env_quote "$1")"
        printf 'CSQTT_WEB_PASS=%s\n' "$(env_quote "$2")"
        printf 'CSQTT_PUBLIC_IP=%s\n' "$(env_quote "$3")"
        printf 'CSQTT_WEB_SECRET_PATH=%s\n' "$(env_quote "$4")"
    } >"$env_tmp"; then
        rm -f "$env_tmp"
        die "cannot write csqtt.env"
    fi
    mv -f "$env_tmp" "$ENV_FILE" || die "cannot activate csqtt.env"
    chmod 0600 "$ENV_FILE" 2>/dev/null || true
}

write_install_state() {
    state_tmp=$(mktemp "$CONFIG_DIR/.install.json.XXXXXX") || die "cannot create temporary install.json"
    chmod 0600 "$state_tmp" || die "cannot protect temporary install.json"
    if ! printf '{"version":"%s","mode":"docker","panel_mode":"%s","panel_host":"%s","peer_port":"%s","web_port":"%s","ssh_port":"22","tls":"selfsigned","installed_at":"%s","updated_at":"%s"}\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$(date +%s)" >"$state_tmp"; then
        rm -f "$state_tmp"
        die "cannot write install.json"
    fi
    mv -f "$state_tmp" "$INSTALL_STATE" || die "cannot activate install.json"
    chmod 0600 "$INSTALL_STATE" 2>/dev/null || true
}

# Self-signed pair with an explicit SAN. Both modes are generated here so the
# certificate never depends on what the server can probe at runtime: a domain
# install gets DNS:<host>, an IP install gets IP:<host>. An existing pair
# (including user-supplied Let's Encrypt files) is never touched.
ensure_certificate() {
    cert_host=$1
    cert_mode=$2
    cert_file="$CONFIG_DIR/web_cert.pem"
    key_file="$CONFIG_DIR/web_key.pem"
    if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        return 0
    fi
    if [ -f "$cert_file" ] || [ -f "$key_file" ]; then
        # Fail closed, как сервер: догадываться, какая половина пары — мусор,
        # нельзя. Пользовательский сертификат/ключ не удаляем.
        die "incomplete TLS pair in $CONFIG_DIR (need both web_cert.pem and web_key.pem); fix or remove the pair"
    fi
    case "$cert_mode" in
        domain) cert_san="DNS:$cert_host" ;;
        *) cert_san="IP:$cert_host" ;;
    esac
    cert_tmp=$(mktemp "$CONFIG_DIR/.web_cert.pem.XXXXXX") || return 1
    key_tmp=$(mktemp "$CONFIG_DIR/.web_key.pem.XXXXXX") || {
        rm -f "$cert_tmp"
        return 1
    }
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=$cert_host" -addext "subjectAltName=$cert_san" \
        -keyout "$key_tmp" -out "$cert_tmp" >/dev/null 2>&1; then
        rm -f "$cert_tmp" "$key_tmp"
        warn "openssl could not create a self-signed certificate; the server will generate its own"
        return 1
    fi
    chmod 0644 "$cert_tmp" 2>/dev/null || true
    chmod 0600 "$key_tmp" 2>/dev/null || true
    if ! mv -f "$cert_tmp" "$cert_file" || ! mv -f "$key_tmp" "$key_file"; then
        rm -f "$cert_tmp" "$key_tmp"
        warn "cannot install the generated TLS pair"
        return 1
    fi
    log "self-signed TLS certificate for $cert_host ($cert_san)"
}

# Creates only what is missing: an existing identity in csqtt.env and an
# existing install.json keep their values, including a user-modified host.
bootstrap_configuration() {
    mkdir -p "$CONFIG_DIR" || die "cannot create $CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR" 2>/dev/null || true

    BOOTSTRAP_PRINT_CREDENTIALS=0
    env_existed=0
    [ -f "$ENV_FILE" ] && env_existed=1

    panel_host=$(env_file_value CSQTT_PUBLIC_IP "$ENV_FILE" 2>/dev/null || true)
    panel_host=$(normalize_host "$panel_host")
    if [ -z "$panel_host" ]; then
        panel_host=$(normalize_host "$(json_get panel_host "$INSTALL_STATE" 2>/dev/null || true)")
    fi

    state_peer_port=$(json_get peer_port "$INSTALL_STATE" 2>/dev/null || true)
    state_web_port=$(json_get web_port "$INSTALL_STATE" 2>/dev/null || true)
    state_panel_mode=$(json_get panel_mode "$INSTALL_STATE" 2>/dev/null || true)
    state_installed_at=$(json_get installed_at "$INSTALL_STATE" 2>/dev/null || true)

    if [ -z "$panel_host" ] && [ -n "${CSQTT_HOST:-}" ]; then
        panel_host=$(normalize_host "$CSQTT_HOST")
    fi
    if [ -z "$panel_host" ]; then
        panel_host=$(detect_public_ipv4 || true)
        if [ -z "$panel_host" ] || is_private_ipv4 "$panel_host"; then
            panel_host=$(hostname 2>/dev/null || true)
            warn "public IPv4 is unavailable or private; using hostname '$panel_host' as the panel host"
        fi
    fi
    [ -n "$panel_host" ] || die "cannot determine the panel host; set CSQTT_HOST to a domain or a public IPv4"
    valid_host "$panel_host" || die "invalid panel host '$panel_host'; set CSQTT_HOST to a domain or a public IPv4"

    case "$panel_host" in
        *[!0-9.]*) panel_mode=domain ;;
        *)
            is_ipv4 "$panel_host" || die "invalid IPv4 address '$panel_host'"
            panel_mode=ip
            ;;
    esac
    if [ "$panel_mode" = "domain" ]; then
        default_web_port=$DOMAIN_WEB_PORT
    else
        default_web_port=$IP_WEB_PORT
    fi

    web_user=$(env_file_value CSQTT_WEB_USER "$ENV_FILE" 2>/dev/null || true)
    web_pass=$(env_file_value CSQTT_WEB_PASS "$ENV_FILE" 2>/dev/null || true)
    web_secret=$(env_file_value CSQTT_WEB_SECRET_PATH "$ENV_FILE" 2>/dev/null || true)

    identity_changed=0
    if [ -z "$web_user" ]; then
        web_user=$(random_alnum 10) || die "cannot generate the panel user"
        identity_changed=1
    fi
    if [ -z "$web_pass" ]; then
        web_pass=$(random_alnum 24) || die "cannot generate the panel password"
        identity_changed=1
        BOOTSTRAP_PRINT_CREDENTIALS=1
        log "generated a new panel password"
    fi
    if [ -z "$web_secret" ]; then
        web_secret=$(random_alnum 16) || die "cannot generate the panel secret path"
        identity_changed=1
    fi
    [ "$env_existed" = 1 ] || BOOTSTRAP_PRINT_CREDENTIALS=1

    if [ "$identity_changed" = 1 ] || [ ! -f "$ENV_FILE" ]; then
        write_env_file "$web_user" "$web_pass" "$panel_host" "$web_secret"
    fi

    peer_port=$state_peer_port
    case "$peer_port" in
        ''|*[!0-9]*) peer_port=$DEFAULT_PEER_PORT ;;
    esac
    web_port=$state_web_port
    case "$web_port" in
        ''|*[!0-9]*) web_port=$default_web_port ;;
    esac

    state_complete=0
    if [ -n "$panel_host" ]; then
        state_complete=1
    fi
    case "$state_panel_mode" in
        ip|domain) ;;
        *) state_complete=0 ;;
    esac
    case "$state_peer_port" in
        ''|*[!0-9]*) state_complete=0 ;;
    esac
    case "$state_web_port" in
        ''|*[!0-9]*) state_complete=0 ;;
    esac
    if [ "$state_complete" = 0 ]; then
        case "$state_installed_at" in
            ''|*[!0-9]*) state_installed_at=$(date +%s) ;;
        esac
        write_install_state "$(server_version)" "$panel_mode" "$panel_host" \
            "$peer_port" "$web_port" "$state_installed_at"
        log "wrote $INSTALL_STATE (mode $panel_mode, host $panel_host, peer/udp $peer_port, web/tcp $web_port)"
    fi

    CERT_HOST=$panel_host
    CERT_MODE=$panel_mode
}

# Numeric port from install.json, or the supplied default.
port_value() {
    key=$1
    default=$2
    value=$(json_get "$key" "$INSTALL_STATE" 2>/dev/null || true)
    case "$value" in
        ''|*[!0-9]*) printf '%s\n' "$default" ;;
        *) printf '%s\n' "$value" ;;
    esac
}

bootstrap_configuration

PANEL_MODE=$(json_get panel_mode "$INSTALL_STATE" 2>/dev/null || true)
case "$PANEL_MODE" in
    ip) WEB_DEFAULT=$IP_WEB_PORT ;;
    *) WEB_DEFAULT=$DOMAIN_WEB_PORT ;;
esac

PEER_PORT=$(port_value peer_port "$DEFAULT_PEER_PORT")
WEB_PORT=$(port_value web_port "$WEB_DEFAULT")

# The panel moves between 443 (domain) and 46002 (IP). A stale ACCEPT from the
# previous mode is still there because rules are only ever added.
case "$WEB_PORT" in
    443) STALE_WEB_PORT=46002 ;;
    46002) STALE_WEB_PORT=443 ;;
    *) STALE_WEB_PORT="" ;;
esac

# csqtt.env is shell- and systemd-compatible; sourcing with -a is what strips
# the quoting. Compose env_file must not be used instead: it keeps the quotes
# and the panel then rejects its own secret path.
if [ -r "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
else
    die "$ENV_FILE is missing after bootstrap"
fi

PANEL_HOST=${CSQTT_PUBLIC_IP:-}
ensure_certificate "$CERT_HOST" "$CERT_MODE" || true

panel_url() {
    url_secret=${CSQTT_WEB_SECRET_PATH:-}
    url_secret=${url_secret#/}
    url_secret=${url_secret%/}
    if [ "$WEB_PORT" = "443" ] || [ "$PANEL_MODE" = "domain" ]; then
        printf 'https://%s' "$PANEL_HOST"
    else
        printf 'https://%s:%s' "$PANEL_HOST" "$WEB_PORT"
    fi
    [ -z "$url_secret" ] || printf '/%s' "$url_secret"
    printf '\n'
}

# Secrets go to stdout (docker logs) exactly once: when the identity was
# created, or when a missing password had to be regenerated.
if [ "$BOOTSTRAP_PRINT_CREDENTIALS" = 1 ]; then
    printf '\n──────────────────────────────────────────────────────────────\n'
    printf 'Панель reCSQTT готова (пароль показан один раз):\n'
    printf '  URL:     %s\n' "$(panel_url)"
    printf '  Логин:   %s\n' "$CSQTT_WEB_USER"
    printf '  Пароль:  %s\n' "$CSQTT_WEB_PASS"
    printf '  Повтор:  docker exec csqtt cat /etc/csqtt/csqtt.env\n'
    printf '──────────────────────────────────────────────────────────────\n'
fi

[ -c /dev/net/tun ] || die "/dev/net/tun is missing; run 'modprobe tun' on the host before starting the container"

is_ignored_wan_interface() {
    ignored_iface=${1%%@*}
    case "$ignored_iface" in
        ""|lo|"$CSQTT_IFACE"|csqtp*|tun*|tap*|wg*|warp*|Warp*|WARP*|CloudflareWARP*|tailscale*|zt*|docker*|br-*|veth*|cni*|flannel*|virbr*|podman*|kube*|dummy*|ifb*)
            return 0
            ;;
    esac
    return 1
}

detect_wan_interface() {
    fallback=""
    for iface in $(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); break}}'); do
        iface=${iface%%@*}
        [ -n "$iface" ] || continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            printf '%s\n' "$iface"
            return 0
        fi
    done
    for iface in $(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/@.*/, "", $2); print $2}'); do
        iface=${iface%%@*}
        [ -n "$iface" ] || continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            printf '%s\n' "$iface"
            return 0
        fi
    done
    for iface in $(ls /sys/class/net/ 2>/dev/null || true); do
        iface=${iface%%@*}
        [ "$iface" = "lo" ] && continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            printf '%s\n' "$iface"
            return 0
        fi
    done
    [ -n "$fallback" ] && printf '%s\n' "$fallback"
}

# best-effort: /proc/sys is read-only in many container setups and that is fine.
# The write goes through a subshell, otherwise the shell itself prints
# "can't create /proc/sys/...: Read-only file system" on every start: the
# diagnostic comes from the redirection, not from printf, so a per-command
# `2>/dev/null` would not suppress it.
write_sysctl() {
    ( printf '%s\n' "$2" >"/proc/sys/$1" ) 2>/dev/null || true
}

write_sysctl net/ipv4/ip_forward 1
write_sysctl net/ipv6/conf/all/forwarding 1
write_sysctl net/ipv4/conf/all/rp_filter 2
write_sysctl net/ipv4/conf/default/rp_filter 2
write_sysctl net/ipv4/tcp_notsent_lowat 131072

WAN_IFACE=""
network_waited=0
while [ "$network_waited" -lt 90 ]; do
    candidate_iface=$(detect_wan_interface || true)
    if [ -n "$candidate_iface" ] && ip link show "$candidate_iface" >/dev/null 2>&1 && \
       ip -o -4 route show default 2>/dev/null | grep -q .; then
        WAN_IFACE=$candidate_iface
        break
    fi
    network_waited=$((network_waited + 1))
    sleep 1
done
if [ -z "$WAN_IFACE" ]; then
    warn "no WAN interface after 90s; NAT rules for the outbound path will be skipped"
else
    log "WAN interface: $WAN_IFACE"
    write_sysctl "net/ipv4/conf/$WAN_IFACE/rp_filter" 2
    write_sysctl "net/ipv4/conf/$CSQTT_IFACE/rp_filter" 2
fi

ipt() { iptables -w "$XT_WAIT" "$@"; }

# Docker creates a missing bind source as a directory, and iptables cannot use a
# directory as its lock file. The fix is on the host; just say it clearly.
if [ -d /run/xtables.lock ]; then
    warn "/run/xtables.lock is a directory (Docker created it); on the host run: docker compose down && sudo rmdir /run/xtables.lock && sudo touch /run/xtables.lock"
fi

# Check-then-add, same semantics as the installer's ipt_add_or_ensure.
# Missing rule is normal; a rule that cannot be installed is reported once and
# never fatal, so a degraded firewall does not hide the panel behind a crash.
ensure_rule() {
    table=$1
    chain=$2
    shift 2
    if [ "$table" = "filter" ]; then
        ipt -C "$chain" "$@" >/dev/null 2>&1 && return 0
        ipt -I "$chain" 1 "$@" >/dev/null 2>&1 && return 0
    else
        ipt -t "$table" -C "$chain" "$@" >/dev/null 2>&1 && return 0
        ipt -t "$table" -A "$chain" "$@" >/dev/null 2>&1 && return 0
    fi
    warn "iptables: cannot install rule (-t $table $chain $*)"
    return 1
}

remove_stale_panel_rule() {
    [ -n "$STALE_WEB_PORT" ] || return 0
    stale_attempt=1
    while [ "$stale_attempt" -le 8 ]; do
        stale_listing=$(ipt -S INPUT 2>/dev/null || true)
        printf '%s\n' "$stale_listing" | \
            grep -Eq -- "^-A INPUT .*--dport ${STALE_WEB_PORT}([[:space:]]|$).*${IPT_COMMENT}" || return 0
        ipt -D INPUT -p tcp --dport "$STALE_WEB_PORT" -m comment --comment "$IPT_COMMENT" -j ACCEPT >/dev/null 2>&1 && return 0
        stale_attempt=$((stale_attempt + 1))
    done
    warn "iptables: stale TCP/$STALE_WEB_PORT ACCEPT could not be removed"
}

if ! ipt -S INPUT >/dev/null 2>&1; then
    warn "netfilter is unavailable (NET_ADMIN missing?); starting without iptables rules"
else
    remove_stale_panel_rule

    ensure_rule filter INPUT -p udp --dport "$PEER_PORT" -m comment --comment "$IPT_COMMENT" -j ACCEPT || true
    ensure_rule filter INPUT -p tcp --dport "$WEB_PORT" -m comment --comment "$IPT_COMMENT" -j ACCEPT || true
    ensure_rule filter INPUT -p tcp --dport "$LE_HTTP_PORT" -m comment --comment "$IPT_COMMENT" -j ACCEPT || true
    ensure_rule filter INPUT -i "$CSQTT_IFACE" -s "$CSQTT_SUBNET" -m comment --comment "$IPT_COMMENT" -j ACCEPT || true
    ensure_rule filter FORWARD -i "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT || true
    ensure_rule filter FORWARD -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT || true

    if [ -n "$WAN_IFACE" ]; then
        ensure_rule nat POSTROUTING -s "$CSQTT_SUBNET" -o "$WAN_IFACE" \
            -m comment --comment "$IPT_COMMENT" -j MASQUERADE || true
    fi
    ensure_rule nat POSTROUTING -s "$CSQTT_SUBNET" ! -o "$CSQTT_IFACE" \
        -m comment --comment "$IPT_COMMENT" -j MASQUERADE || true

    ensure_rule mangle FORWARD -s "$CSQTT_SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN \
        -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu || true
    ensure_rule mangle FORWARD -d "$CSQTT_SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN \
        -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu || true
fi

(
    umask 077
    mkdir -p "$(dirname "$NETWORK_READY_FILE")" 2>/dev/null || true
    : >"$NETWORK_READY_FILE" 2>/dev/null || true
)

log "starting reCSQTT: peer/udp $PEER_PORT, web/tcp $WEB_PORT, mode ${PANEL_MODE:-unknown}"
exec "$CSQTT_BIN" --listen "0.0.0.0:$PEER_PORT" --web-port "$WEB_PORT" --config-dir "$CONFIG_DIR"
