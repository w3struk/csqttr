#!/bin/sh
# Compose healthcheck: TUN interface plus the panel's TCP listener.
# Exit 0 = healthy, 1 = unhealthy. Never prints identity or TLS material.
set -u

CONFIG_DIR=/etc/csqtt
INSTALL_STATE="$CONFIG_DIR/install.json"
CSQTT_IFACE=csqtt1

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

WEB_PORT=$(json_get web_port "$INSTALL_STATE" 2>/dev/null || true)
case "$WEB_PORT" in
    ''|*[!0-9]*)
        case "$(json_get panel_mode "$INSTALL_STATE" 2>/dev/null || true)" in
            ip) WEB_PORT=46002 ;;
            *) WEB_PORT=443 ;;
        esac
        ;;
esac

healthy=1

if ip link show "$CSQTT_IFACE" >/dev/null 2>&1; then
    :
else
    printf 'unhealthy: TUN %s is missing\n' "$CSQTT_IFACE" >&2
    healthy=0
fi

if ss -Hltn "sport = :$WEB_PORT" 2>/dev/null | grep -q .; then
    :
else
    printf 'unhealthy: no TCP listener on :%s\n' "$WEB_PORT" >&2
    healthy=0
fi

[ "$healthy" -eq 1 ]
