#!/usr/bin/env bash

ARTX_DECOY_DEFAULT_LISTEN="127.0.0.1:60443"
ARTX_DECOY_ROOT="${ARTX_DECOY_ROOT:-}"
ARTX_DECOY_SKIP_SERVICE_ACTIONS="${ARTX_DECOY_SKIP_SERVICE_ACTIONS:-0}"

artx_decoy_path() {
    printf '%s%s' "$ARTX_DECOY_ROOT" "$1"
}

artx_decoy_env_path() {
    artx_decoy_path "/etc/N2X/artx-decoy.env"
}

artx_decoy_ensure_env() {
    local env_path
    env_path="$(artx_decoy_env_path)"
    mkdir -p "$(dirname "$env_path")" || return 1
    if [[ ! -f "$env_path" ]]; then
        printf 'N2X_ARTX_DECOY_LISTEN=%s\n' "$ARTX_DECOY_DEFAULT_LISTEN" > "$env_path" || return 1
    fi
    chmod 600 "$env_path" >/dev/null 2>&1 || true
}

artx_decoy_listen_address() {
    local env_path line
    env_path="$(artx_decoy_env_path)"
    line="$(grep -m1 -E '^N2X_ARTX_DECOY_LISTEN=' "$env_path" 2>/dev/null || true)"
    if [[ -n "$line" ]]; then
        printf '%s' "${line#*=}"
        return
    fi
    printf '%s' "$ARTX_DECOY_DEFAULT_LISTEN"
}

artx_decoy_write_systemd_unit() {
    local unit_path
    unit_path="$(artx_decoy_path "/etc/systemd/system/N2X-artx-decoy.service")"
    mkdir -p "$(dirname "$unit_path")" || return 1
    cat > "$unit_path" <<'EOF'
[Unit]
Description=Service Status Endpoint
After=network.target
Before=N2X.service

[Service]
Type=simple
EnvironmentFile=-/etc/N2X/artx-decoy.env
ExecStart=/usr/local/N2X/N2X decoy serve
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
}

artx_decoy_write_openrc_service() {
    local service_path
    service_path="$(artx_decoy_path "/etc/init.d/N2X-artx-decoy")"
    mkdir -p "$(dirname "$service_path")" || return 1
    cat > "$service_path" <<'EOF'
#!/sbin/openrc-run

name="Service Status Endpoint"
description="Local service status endpoint"
command="/usr/local/N2X/N2X"
command_args="decoy serve"
command_user="root"
pidfile="/run/N2X-artx-decoy.pid"
command_background="yes"

start_pre() {
    local env_path="${1:-/etc/N2X/artx-decoy.env}"
    local listen

    [ -e "$env_path" ] || return 0
    listen="$(awk '
        /^N2X_ARTX_DECOY_LISTEN=/ {
            count++
            value = substr($0, index($0, "=") + 1)
        }
        END {
            if (count != 1 || value == "" || value ~ /[[:space:]]/) exit 1
            print value
        }
    ' "$env_path" 2>/dev/null)" || {
        eerror "Invalid N2X_ARTX_DECOY_LISTEN in ${env_path}"
        return 1
    }
    export N2X_ARTX_DECOY_LISTEN="$listen"
}

depend() {
    need net
    before N2X
}
EOF
    chmod +x "$service_path" || return 1
}

artx_decoy_install_service() {
    local release="${1:-systemd}"
    artx_decoy_ensure_env || return 1
    if [[ "$release" == "alpine" ]]; then
        artx_decoy_write_openrc_service || return 1
        if [[ "$ARTX_DECOY_SKIP_SERVICE_ACTIONS" != "1" ]]; then
            rc-update add N2X-artx-decoy default >/dev/null 2>&1 || true
            service N2X-artx-decoy restart >/dev/null 2>&1 || return 1
        fi
        return 0
    fi

    artx_decoy_write_systemd_unit || return 1
    if [[ "$ARTX_DECOY_SKIP_SERVICE_ACTIONS" != "1" ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        systemctl enable N2X-artx-decoy >/dev/null 2>&1 || return 1
        systemctl restart N2X-artx-decoy >/dev/null 2>&1 || return 1
    fi
}

artx_decoy_restart() {
    local release="${1:-systemd}"
    if [[ "$release" == "alpine" ]]; then
        service N2X-artx-decoy restart || return 1
        artx_decoy_health || return 1
        service N2X restart
    else
        systemctl restart N2X-artx-decoy || return 1
        artx_decoy_health || return 1
        systemctl restart N2X
    fi
}

artx_decoy_status() {
    local release="${1:-systemd}"
    if [[ "$release" == "alpine" ]]; then
        service N2X-artx-decoy status
    else
        systemctl status N2X-artx-decoy --no-pager -l
    fi
}

artx_decoy_log() {
    local release="${1:-systemd}"
    if [[ "$release" == "alpine" ]]; then
        tail -f /var/log/messages
    else
        journalctl -u N2X-artx-decoy.service -e --no-pager -f
    fi
}

artx_decoy_health() {
    local listen attempt
    listen="$(artx_decoy_listen_address)"
    for ((attempt = 1; attempt <= 20; attempt++)); do
        if curl --fail --silent --head --max-time 1 "http://${listen}/" >/dev/null 2>&1; then
            return 0
        fi
        if ((attempt < 20)); then
            sleep 0.1
        fi
    done
    echo "诱饵 Web 服务在 http://${listen}/ 未通过健康检查" >&2
    return 1
}

artx_decoy_uninstall() {
    local release="${1:-systemd}"
    if [[ "$release" == "alpine" ]]; then
        if [[ "$ARTX_DECOY_SKIP_SERVICE_ACTIONS" != "1" ]]; then
            service N2X-artx-decoy stop >/dev/null 2>&1 || true
            rc-update del N2X-artx-decoy default >/dev/null 2>&1 || true
        fi
        rm -f "$(artx_decoy_path "/etc/init.d/N2X-artx-decoy")"
        return 0
    fi

    if [[ "$ARTX_DECOY_SKIP_SERVICE_ACTIONS" != "1" ]]; then
        systemctl stop N2X-artx-decoy >/dev/null 2>&1 || true
        systemctl disable N2X-artx-decoy >/dev/null 2>&1 || true
    fi
    rm -f "$(artx_decoy_path "/etc/systemd/system/N2X-artx-decoy.service")"
    if [[ "$ARTX_DECOY_SKIP_SERVICE_ACTIONS" != "1" ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed >/dev/null 2>&1 || true
    fi
}
