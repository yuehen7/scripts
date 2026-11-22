#!/usr/bin/env bash
# =========================================================
# sing-box 一键安装、服务管理、BBR 调优、配置生成与节点查看脚本
# 入站: 可选 Shadowsocks(默认32443) / VLESS-Reality(默认443) / VMess-WS-TLS(默认2053) / Hysteria2(默认8443 UDP) / Argo 隧道
# 支持 systemd (Debian/Ubuntu/CentOS 等) 与 OpenRC (Alpine 等)
# =========================================================

# 允许通过 sh 调用：自动切换到 bash（此处必须使用 POSIX 语法）
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "错误：本脚本需要 bash，请先执行 apk add --no-cache bash（Alpine）或安装 bash 后重试。" >&2
    exit 1
fi

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sing-box"
CERT_DIR="${CONFIG_DIR}/cert"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SYSTEMD_FILE="/etc/systemd/system/sing-box.service"
INITD_FILE="/etc/init.d/sing-box"
SERVICE_NAME="sing-box"
SERVICE_LOG="/var/log/sing-box.log"
CLI_TARGET="/usr/local/bin/sb"
SYSCTL_BBR_FILE="/etc/sysctl.d/99-network-bbr.conf"
LIMITS_FILE="/etc/security/limits.d/99-nofile.conf"
LOCAL_D_FILE="/etc/local.d/99-network-bbr.start"

# 入站协议候选参数
SS_PORT=32443
SS_METHOD="2022-blake3-aes-128-gcm"
REALITY_PORT=443
VMESS_WS_PORT=2053
HY2_PORT=8443
VMESS_WS_PATH="/175443"
# 默认端口（用户可在生成配置时自定义）
DEFAULT_SS_PORT="$SS_PORT"
DEFAULT_REALITY_PORT="$REALITY_PORT"
DEFAULT_VMESS_WS_PORT="$VMESS_WS_PORT"
DEFAULT_HY2_PORT="$HY2_PORT"
# VLESS-Reality 与 VMess-WS-TLS 共用固定 UUID
FIXED_UUID="8326d9fd-3246-4ca0-aa48-894f0e7d96d6"

# Argo 隧道：quick 使用外部 cloudflared，named 使用 sing-box 内置 cloudflared 入站
ARGO_WS_PORT=2083
DEFAULT_ARGO_WS_PORT="$ARGO_WS_PORT"
ARGO_WS_PATH="/argo-${FIXED_UUID:0:8}"
ARGO_DIR="${CONFIG_DIR}/argo"
ARGO_MODE_FILE="${ARGO_DIR}/mode"
ARGO_DOMAIN_FILE="${ARGO_DIR}/domain"
ARGO_EDGE_IP_FILE="${ARGO_DIR}/edge_ip"
# 外部 cloudflared（仅 quick 模式使用）
ARGO_BIN="/usr/local/bin/cloudflared-singbox-argo"
ARGO_SERVICE_NAME="cloudflared-singbox-argo"
ARGO_SYSTEMD_FILE="/etc/systemd/system/${ARGO_SERVICE_NAME}.service"
ARGO_INITD_FILE="/etc/init.d/${ARGO_SERVICE_NAME}"
ARGO_LOG="/var/log/${ARGO_SERVICE_NAME}.log"

set -o pipefail

# 检测服务管理器：systemd / OpenRC
detect_init_system() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="unknown"
    fi
}
detect_init_system

# 服务控制封装，兼容 systemd 与 OpenRC
service_start() {
    case "$INIT_SYSTEM" in
        systemd) systemctl start "$SERVICE_NAME" ;;
        openrc) rc-service "$SERVICE_NAME" start ;;
        *) echo -e "${RED}未检测到 systemd 或 OpenRC，无法管理服务。${PLAIN}"; return 1 ;;
    esac
}

service_stop() {
    case "$INIT_SYSTEM" in
        systemd) systemctl stop "$SERVICE_NAME" ;;
        openrc) rc-service "$SERVICE_NAME" stop ;;
        *) return 1 ;;
    esac
}

service_restart() {
    case "$INIT_SYSTEM" in
        systemd) systemctl restart "$SERVICE_NAME" ;;
        openrc) rc-service "$SERVICE_NAME" restart ;;
        *) return 1 ;;
    esac
}

service_is_active() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet "$SERVICE_NAME" ;;
        openrc) rc-service "$SERVICE_NAME" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

service_logs_follow() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        journalctl -u "$SERVICE_NAME" -f -o cat
    else
        touch "$SERVICE_LOG" 2>/dev/null || true
        tail -f "$SERVICE_LOG"
    fi
}

service_logs_recent() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        journalctl -u "$SERVICE_NAME" --no-pager -n 40 -o cat 2>/dev/null || true
    elif [[ -f "$SERVICE_LOG" ]]; then
        tail -n 40 "$SERVICE_LOG"
    fi
}

service_remove() {
    case "$INIT_SYSTEM" in
        systemd)
            systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
            systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
            rm -f "$SYSTEMD_FILE"
            systemctl daemon-reload >/dev/null 2>&1 || true
            ;;
        openrc)
            rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
            rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
            rm -f "$INITD_FILE"
            ;;
    esac
}

# 重新加载 sysctl 配置，兼容 systemd 与 busybox/procps
reload_sysctl() {
    if sysctl --system >/dev/null 2>&1; then
        return 0
    fi
    [[ -f "$SYSCTL_BBR_FILE" ]] && sysctl -p "$SYSCTL_BBR_FILE" >/dev/null 2>&1
    return 0
}

# =========================================================
# Argo 隧道管理
# quick: 外部 cloudflared + 本地明文 VMess-WS
# named: sing-box 内置 cloudflared 入站 + 本地明文 VMess-WS
# =========================================================

argo_is_configured() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    jq -e 'any(.inbounds[]?; .tag == "vmess-ws-argo-in")' "$CONFIG_FILE" >/dev/null 2>&1
}

argo_is_quick() {
    [[ "$(argo_mode)" == "quick" ]]
}

argo_is_named() {
    [[ "$(argo_mode)" == "named" ]]
}

argo_mode() {
    [[ -s "$ARGO_MODE_FILE" ]] && tr -d '[:space:]' < "$ARGO_MODE_FILE"
}

argo_domain() {
    [[ -s "$ARGO_DOMAIN_FILE" ]] && tr -d '[:space:]' < "$ARGO_DOMAIN_FILE"
}

argo_edge_ip() {
    local ip=""
    [[ -s "$ARGO_EDGE_IP_FILE" ]] && ip=$(tr -d '[:space:]' < "$ARGO_EDGE_IP_FILE")
    if [[ "$ip" != "4" && "$ip" != "6" ]]; then
        ip="4"
    fi
    printf '%s\n' "$ip"
}

argo_ws_port() {
    jq -r '.inbounds[] | select(.tag=="vmess-ws-argo-in") | .listen_port' "$CONFIG_FILE" 2>/dev/null
}

argo_ws_path() {
    jq -r '.inbounds[] | select(.tag=="vmess-ws-argo-in") | .transport.path' "$CONFIG_FILE" 2>/dev/null
}

argo_uuid() {
    jq -r '.inbounds[] | select(.tag=="vmess-ws-argo-in") | .users[0].uuid' "$CONFIG_FILE" 2>/dev/null
}

argo_has_builtin_inbound() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    jq -e 'any(.inbounds[]?; .tag == "cloudflared-in")' "$CONFIG_FILE" >/dev/null 2>&1
}

save_argo_state() {
    local mode="$1" domain="$2" edge_ip="$3"
    mkdir -p "$ARGO_DIR" || return 1
    chmod 700 "$ARGO_DIR" 2>/dev/null || true
    : > "$ARGO_LOG" 2>/dev/null || true
    printf '%s\n' "$mode" > "$ARGO_MODE_FILE" || return 1
    printf '%s\n' "$edge_ip" > "$ARGO_EDGE_IP_FILE" || return 1
    if [[ "$mode" == "named" ]]; then
        printf '%s\n' "$domain" > "$ARGO_DOMAIN_FILE" || return 1
    else
        : > "$ARGO_DOMAIN_FILE" || return 1
    fi
}

clear_argo_state() {
    rm -rf "$ARGO_DIR"
}

# 外部 cloudflared 服务（仅 quick 模式）
argo_service_start() {
    case "$INIT_SYSTEM" in
        systemd) systemctl start "$ARGO_SERVICE_NAME" ;;
        openrc) rc-service "$ARGO_SERVICE_NAME" start ;;
        *) return 1 ;;
    esac
}

argo_service_stop() {
    case "$INIT_SYSTEM" in
        systemd) systemctl stop "$ARGO_SERVICE_NAME" >/dev/null 2>&1 || true ;;
        openrc) rc-service "$ARGO_SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
        *) return 1 ;;
    esac
}

argo_service_is_active() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet "$ARGO_SERVICE_NAME" ;;
        openrc) rc-service "$ARGO_SERVICE_NAME" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

argo_service_remove() {
    case "$INIT_SYSTEM" in
        systemd)
            systemctl stop "$ARGO_SERVICE_NAME" >/dev/null 2>&1 || true
            systemctl disable "$ARGO_SERVICE_NAME" >/dev/null 2>&1 || true
            rm -f "$ARGO_SYSTEMD_FILE"
            systemctl daemon-reload >/dev/null 2>&1 || true
            ;;
        openrc)
            rc-service "$ARGO_SERVICE_NAME" stop >/dev/null 2>&1 || true
            rc-update del "$ARGO_SERVICE_NAME" default >/dev/null 2>&1 || true
            rm -f "$ARGO_INITD_FILE"
            ;;
    esac
    rm -f "$ARGO_LOG"
}

detect_argo_arch() {
    case "$(uname -m)" in
        x86_64|amd64) ARGO_ASSET="cloudflared-linux-amd64" ;;
        aarch64|arm64) ARGO_ASSET="cloudflared-linux-arm64" ;;
        armv7l|armv7) ARGO_ASSET="cloudflared-linux-arm" ;;
        i386|i686) ARGO_ASSET="cloudflared-linux-386" ;;
        *) return 1 ;;
    esac
}

download_cloudflared() {
    local force="${1:-0}"
    if [[ -x "$ARGO_BIN" && "$force" -ne 1 ]]; then
        echo -e "${GREEN}cloudflared 已存在: ${ARGO_BIN}${PLAIN}"
        return 0
    fi

    detect_argo_arch || {
        echo -e "${RED}当前架构 $(uname -m) 不支持 cloudflared（仅支持 x86_64 / arm64 / armv7 / i386）。${PLAIN}"
        return 1
    }

    echo -e "${YELLOW}正在下载 cloudflared (${ARGO_ASSET})...${PLAIN}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! curl -L -f -o "${tmp_dir}/cloudflared" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/${ARGO_ASSET}"; then
        echo -e "${RED}cloudflared 下载失败，请检查网络。${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi
    chmod +x "${tmp_dir}/cloudflared"
    if ! "${tmp_dir}/cloudflared" --version >/dev/null 2>&1; then
        echo -e "${RED}cloudflared 二进制无法运行，已放弃安装。${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi
    mv "${tmp_dir}/cloudflared" "$ARGO_BIN"
    chmod 0755 "$ARGO_BIN"
    rm -rf "$tmp_dir"
    echo -e "${GREEN}cloudflared 已安装: $("$ARGO_BIN" --version 2>/dev/null | head -n 1)${PLAIN}"
}

argo_recent_logs() {
    if [[ -f "$ARGO_LOG" ]]; then
        tail -n 200 "$ARGO_LOG" 2>/dev/null || true
    elif [[ "$INIT_SYSTEM" == "systemd" ]]; then
        journalctl -u "$ARGO_SERVICE_NAME" --no-pager -n 200 -o cat 2>/dev/null || true
    fi
}

refresh_argo_domain_from_log() {
    local domain
    domain=$(argo_recent_logs | grep -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' | tail -n 1 | sed 's#^https://##')
    if [[ -n "$domain" ]]; then
        printf '%s\n' "$domain" > "$ARGO_DOMAIN_FILE"
        printf '%s\n' "$domain"
        return 0
    fi
    return 1
}

wait_for_argo_domain() {
    local waited=0 domain=""
    while [[ $waited -lt 30 ]]; do
        if domain=$(refresh_argo_domain_from_log); then
            echo -e "${GREEN}Argo Quick Tunnel 域名: ${domain}${PLAIN}"
            return 0
        fi
        if ! argo_service_is_active; then
            echo -e "${RED}cloudflared 未保持运行，请执行 'sb argo log' 查看日志。${PLAIN}"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo -e "${YELLOW}等待 Argo 域名超时，请稍后执行 'sb argo info' 或 'sb argo log' 查看。${PLAIN}"
    return 1
}

setup_argo_service() {
    argo_is_configured || return 1
    argo_is_quick || return 1

    local port edge_ip command_args
    port=$(argo_ws_port)
    edge_ip=$(argo_edge_ip)

    if [[ -z "$port" || "$port" == "null" ]]; then
        echo -e "${RED}未找到 Argo 本地 WS 端口，请执行 'sb gen' 重新生成。${PLAIN}"
        return 1
    fi

    mkdir -p "$ARGO_DIR"
    touch "$ARGO_LOG" 2>/dev/null || true

    command_args="tunnel --no-autoupdate --edge-ip-version ${edge_ip} --protocol http2 --logfile ${ARGO_LOG} --url http://127.0.0.1:${port}"

    case "$INIT_SYSTEM" in
        systemd)
            cat << EOF > "$ARGO_SYSTEMD_FILE"
[Unit]
Description=Cloudflare Argo Tunnel for sing-box
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
User=root
ExecStart=${ARGO_BIN} ${command_args}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload || return 1
            systemctl enable "$ARGO_SERVICE_NAME" >/dev/null 2>&1 || return 1
            echo -e "${GREEN}Argo quick 外部 cloudflared 服务已注册。${PLAIN}"
            ;;
        openrc)
            cat << EOF > "$ARGO_INITD_FILE"
#!/sbin/openrc-run

name="${ARGO_SERVICE_NAME}"
description="Cloudflare Argo Tunnel for sing-box"

supervisor="supervise-daemon"
command="${ARGO_BIN}"
command_args="${command_args}"
pidfile="/run/${ARGO_SERVICE_NAME}.pid"
respawn_delay=5
respawn_max=0
output_log="/dev/null"
error_log="/dev/null"
rc_ulimit="-n 1048576"

depend() {
    need net
    after firewall sing-box
}
EOF
            chmod 0755 "$ARGO_INITD_FILE"
            rc-update add "$ARGO_SERVICE_NAME" default >/dev/null 2>&1 || return 1
            echo -e "${GREEN}Argo quick 外部 cloudflared 服务已注册。${PLAIN}"
            ;;
        *)
            echo -e "${RED}未检测到 systemd 或 OpenRC，无法注册 Argo 服务。${PLAIN}"
            return 1
            ;;
    esac
}

apply_argo_configuration() {
    if [[ "${ENABLE_ARGO:-0}" -eq 1 ]]; then
        if argo_is_quick; then
            download_cloudflared || return 1
            setup_argo_service || return 1
        else
            # named 模式使用 sing-box 内置 cloudflared，不需要外部服务
            argo_service_remove
        fi
    else
        argo_service_remove
        clear_argo_state
    fi
}

argo_external_start() {
    argo_is_quick || return 0
    argo_is_configured || return 0

    if argo_service_is_active; then
        if [[ -z "$(argo_domain)" ]]; then
            refresh_argo_domain_from_log >/dev/null 2>&1 || true
        fi
        return 0
    fi

    : > "$ARGO_LOG" 2>/dev/null || true
    argo_service_start || return 1
    wait_for_argo_domain
}

argo_external_stop() {
    argo_is_quick || return 0
    argo_service_stop
    rm -f "$ARGO_DOMAIN_FILE"
}

argo_external_restart() {
    argo_is_quick || return 0
    argo_service_stop
    rm -f "$ARGO_DOMAIN_FILE"
    argo_external_start
}

argo_status() {
    echo -e "=== ${GREEN}Argo 隧道状态${PLAIN} ==="
    if ! argo_is_configured; then
        echo -e "未配置 Argo 隧道。可在 'sb gen' 中选择第 5 项。"
        return 0
    fi

    local mode domain port path
    mode=$(argo_mode)
    port=$(argo_ws_port)
    path=$(argo_ws_path)
    domain=$(argo_domain)

    echo -e "模式:       ${CYAN}${mode:-未配置}${PLAIN}"
    if [[ "$mode" == "quick" ]]; then
        echo -e "运行方式:   ${CYAN}外部 cloudflared${PLAIN}"
        if argo_service_is_active; then
            echo -e "服务状态:   ${GREEN}运行中${PLAIN}"
        else
            echo -e "服务状态:   ${RED}未运行${PLAIN}"
        fi
        if [[ -z "$domain" ]] && argo_service_is_active; then
            domain=$(refresh_argo_domain_from_log 2>/dev/null || true)
        fi
        echo -e "公网域名:   ${CYAN}${domain:-尚未生成}${PLAIN}"
        echo -e "日志文件:   ${CYAN}${ARGO_LOG}${PLAIN}"
        echo -e "${YELLOW}提示: Quick Tunnel 域名在 cloudflared 重启后会变化，请重新执行 'sb info'。${PLAIN}"
    elif [[ "$mode" == "named" ]]; then
        echo -e "运行方式:   ${CYAN}sing-box 内置 cloudflared${PLAIN}"
        if service_is_active; then
            echo -e "服务状态:   ${GREEN}运行中 (sing-box)${PLAIN}"
        else
            echo -e "服务状态:   ${RED}未运行 (sing-box)${PLAIN}"
        fi
        echo -e "公网域名:   ${CYAN}${domain:-未配置}${PLAIN}"
        if ! argo_has_builtin_inbound; then
            echo -e "${YELLOW}提示: 配置中缺少 cloudflared-in 入站，请执行 'sb gen' 重新生成。${PLAIN}"
        fi
    else
        echo -e "${YELLOW}Argo 模式配置缺失，请执行 'sb gen' 重新生成。${PLAIN}"
    fi

    echo -e "本地 WS:    ${CYAN}127.0.0.1:${port}${path}${PLAIN}"
}

view_argo_info() {
    argo_is_configured || return 1

    local mode domain port path uuid
    mode=$(argo_mode)
    port=$(argo_ws_port)
    path=$(argo_ws_path)
    uuid=$(argo_uuid)
    domain=$(argo_domain)

    if [[ "$mode" == "quick" && -z "$domain" ]] && argo_service_is_active; then
        domain=$(refresh_argo_domain_from_log 2>/dev/null || true)
    fi
    if [[ -z "$domain" ]]; then
        echo -e "${YELLOW}Argo 域名尚未生成（隧道未运行或正在启动），请稍后执行 'sb argo info'。${PLAIN}"
        return 1
    fi

    echo -e "${GREEN}【协议: VMess + WS (Cloudflare Argo)】${PLAIN}"
    if [[ "$mode" == "quick" ]]; then
        echo -e "  模式 (Mode):        ${CYAN}quick（外部 cloudflared）${PLAIN}"
        echo -e "  ${YELLOW}Quick Tunnel 域名在 cloudflared 重启后会变化。${PLAIN}"
    else
        echo -e "  模式 (Mode):        ${CYAN}named（sing-box 内置 cloudflared）${PLAIN}"
        if ! argo_has_builtin_inbound; then
            echo -e "  ${YELLOW}警告: 配置中缺少 cloudflared-in 入站，请执行 'sb gen' 重新生成。${PLAIN}"
        fi
    fi
    echo -e "  公网域名 (Host):    ${CYAN}${domain}${PLAIN}"
    echo -e "  本地监听 (Local):   ${CYAN}127.0.0.1:${port}${path}${PLAIN}"
    echo -e "  用户 ID (UUID):     ${CYAN}${uuid}${PLAIN}"

    local argo_vmess_json argo_link
    argo_vmess_json=$(jq -cn \
        --arg ps "sing-box-VMess-Argo" \
        --arg add "$domain" \
        --argjson port 443 \
        --arg id "$uuid" \
        --arg host "$domain" \
        --arg path "$path" \
        --arg sni "$domain" \
        --arg alpn "http/1.1" \
        '{v: "2", ps: $ps, add: $add, port: ($port | tostring), id: $id, aid: "0",
          scy: "auto", net: "ws", type: "none", host: $host, path: $path,
          tls: "tls", sni: $sni, alpn: $alpn, fp: "chrome"}')
    argo_link="vmess://$(printf '%s' "$argo_vmess_json" | base64 | tr -d '\n')"
    echo -e "  分享链接 (Link):"
    echo -e "  ${YELLOW}${argo_link}${PLAIN}"
    echo -e "  Mihomo 节点 JSON (添加到 proxies 数组):"
    jq -n \
        --arg name "sing-box-VMess-Argo" \
        --arg server "$domain" \
        --argjson port 443 \
        --arg uuid "$uuid" \
        --arg host "$domain" \
        --arg path "$path" \
        '{
          name: $name,
          type: "vmess",
          server: $server,
          port: $port,
          uuid: $uuid,
          alterId: 0,
          cipher: "auto",
          udp: true,
          tls: true,
          servername: $host,
          alpn: ["http/1.1"],
          "client-fingerprint": "chrome",
          network: "ws",
          "ws-opts": {
            path: $path,
            headers: { Host: $host }
          }
        }'
    echo -e "----------------------------------------------------------------"
}

argo_logs() {
    if ! argo_is_configured; then
        echo -e "${RED}未配置 Argo 隧道。${PLAIN}"
        return 1
    fi
    if argo_is_quick; then
        touch "$ARGO_LOG" 2>/dev/null || true
        tail -f "$ARGO_LOG"
    elif argo_is_named; then
        echo -e "${YELLOW}named 模式使用 sing-box 内置 cloudflared，显示 sing-box 日志：${PLAIN}"
        service_logs_follow
    else
        echo -e "${RED}Argo 模式配置缺失，请执行 'sb gen' 重新生成。${PLAIN}"
        return 1
    fi
}

argo_update() {
    if ! argo_is_configured; then
        echo -e "${RED}未配置 Argo 隧道。${PLAIN}"
        return 1
    fi
    if argo_is_quick; then
        download_cloudflared 1 || return 1
        setup_argo_service || return 1
        argo_external_restart
    else
        echo -e "${YELLOW}named 模式使用 sing-box 内置 cloudflared，请执行 'sb update' 更新 sing-box。${PLAIN}"
    fi
}

argo_uninstall() {
    argo_service_remove
    clear_argo_state
    rm -f "$ARGO_BIN"
    echo -e "${GREEN}Argo 隧道外部服务、状态和 cloudflared 已删除。${PLAIN}"
    echo -e "${YELLOW}如需同时移除本地 WS 和内置 cloudflared 入站，请执行 'sb gen' 并取消选择 Argo。${PLAIN}"
}

argo_menu() {
    echo -e "
${GREEN}Argo 隧道管理${PLAIN}
------------------------
 1. 查看状态 (status)
 2. 查看节点信息 (info)
 3. 启动 (start)
 4. 停止 (stop)
 5. 重启 (restart)
 6. 查看日志 (log)
 7. 更新 cloudflared (update)
 8. 卸载 Argo (uninstall)
 0. 退出
------------------------"
    read -rp "请输入选项 [0-8]: " argo_choice </dev/tty
    case "$argo_choice" in
        1) argo_status ;;
        2) view_argo_info ;;
        3) start_service ;;
        4) stop_service ;;
        5) restart_service ;;
        6) argo_logs ;;
        7) argo_update ;;
        8) argo_uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac
}

argo_command() {
    case "${1:-}" in
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) argo_status ;;
        info) view_argo_info ;;
        log) argo_logs ;;
        update) argo_update ;;
        uninstall) argo_uninstall ;;
        ""|menu) argo_menu ;;
        *)
            echo -e "${RED}未知 Argo 子命令: $1${PLAIN}"
            argo_menu
            ;;
    esac
}

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请以 root 权限运行此脚本！${PLAIN}" && exit 1

# 检测包管理器并安装必要依赖
install_deps() {
    echo -e "${YELLOW}正在检查并安装基础依赖...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y curl wget tar jq openssl systemd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget tar jq openssl systemd
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar jq openssl systemd
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl wget tar jq openssl systemd
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y curl wget tar jq openssl systemd
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash curl wget tar jq openssl iproute2 ca-certificates openrc
    else
        echo -e "${YELLOW}未识别的包管理器，请确保已安装 bash, curl, wget, tar, jq, openssl${PLAIN}"
    fi

    # 依赖安装完成后重新检测服务管理器（例如最小化 Alpine 环境）
    detect_init_system
}

# 检测系统架构
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) ARCH="linux-amd64" ;;
        aarch64|arm64) ARCH="linux-arm64" ;;
        armv7l|armv7) ARCH="linux-armv7" ;;
        s390x) ARCH="linux-s390x" ;;
        riscv64) ARCH="linux-riscv64" ;;
        *)
            echo -e "${RED}不支持的 CPU 架构: ${arch}${PLAIN}"
            exit 1
            ;;
    esac
}

# 校验域名格式
validate_domain() {
    local domain="$1"
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# 证书占位处理：缺失时生成自签临时证书，避免 WS-TLS 入站无法启动
ensure_dummy_cert() {
    mkdir -p "$CERT_DIR"
    if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
        return 0
    fi
    if [[ -f "${CERT_DIR}/fullchain.pem" || -f "${CERT_DIR}/privkey.pem" ]]; then
        echo -e "${RED}证书目录中只存在证书或私钥其中之一，请补齐后再继续：${CERT_DIR}${PLAIN}"
        return 1
    fi

    echo -e "${YELLOW}未检测到证书，正在生成初始临时自签名证书...${PLAIN}"
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
        -keyout "${CERT_DIR}/privkey.pem" \
        -out "${CERT_DIR}/fullchain.pem" \
        -subj "/CN=temporary.cert" >/dev/null 2>&1 || {
            echo -e "${RED}无法生成临时证书，请确认 openssl 可用。${PLAIN}"
            return 1
        }
}

# 校验证书与私钥是否为有效 PEM
check_certificate_files() {
    local cert_file="${CERT_DIR}/fullchain.pem"
    local key_file="${CERT_DIR}/privkey.pem"

    if [[ ! -s "$cert_file" || ! -s "$key_file" ]]; then
        echo -e "${RED}找不到证书文件。请将证书链保存为 ${cert_file}，私钥保存为 ${key_file}。${PLAIN}"
        return 1
    fi
    if ! openssl x509 -in "$cert_file" -noout >/dev/null 2>&1; then
        echo -e "${RED}证书文件不是有效的 PEM 证书：${cert_file}${PLAIN}"
        return 1
    fi
    if ! openssl pkey -in "$key_file" -noout >/dev/null 2>&1; then
        echo -e "${RED}私钥文件不是有效的 PEM 私钥：${key_file}${PLAIN}"
        return 1
    fi
}

# 从证书中提取可用于 Hysteria2 SNI 的域名（优先 SAN，其次 CN）
get_cert_sni() {
    local cert_file="${CERT_DIR}/fullchain.pem"
    [[ -s "$cert_file" ]] || return 0

    local san cn
    # 跳过通配符 SAN，优先返回可直接作为 SNI 的具体域名
    san=$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' | sed -n 's/.*DNS:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
        | grep -v '^\*\.' | head -n 1)
    if [[ -n "$san" ]]; then
        printf '%s\n' "$san"
        return 0
    fi

    cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null \
        | sed -n 's/.*CN[[:space:]]*=[[:space:]]*//p' | tr -d '\r')
    if [[ -n "$cn" && "$cn" != "temporary.cert" && "$cn" != \*.* ]]; then
        printf '%s\n' "$cn"
    fi
}

# 判断当前证书是否为自签证书（自签时客户端需要跳过证书校验）
is_self_signed_cert() {
    local cert_file="${CERT_DIR}/fullchain.pem"
    [[ -s "$cert_file" ]] || return 1

    local subject issuer
    subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/^subject=//')
    issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    [[ -n "$subject" && "$subject" == "$issuer" ]]
}

# 检查端口是否已被其他进程监听（支持 tcp / udp）
check_port_available() {
    local port="$1"
    local proto="${2:-tcp}"
    command -v ss >/dev/null 2>&1 || return 0

    local listeners
    if [[ "$proto" == "udp" ]]; then
        listeners=$(ss -H -lun 2>/dev/null | awk -v port="$port" '$4 ~ (":" port "$") { print }')
    else
        listeners=$(ss -H -ltn 2>/dev/null | awk -v port="$port" '$4 ~ (":" port "$") { print }')
    fi
    if [[ -n "$listeners" ]]; then
        echo -e "${RED}端口 ${port}/${proto} 已被其他进程监听，sing-box 无法启动：${PLAIN}"
        echo "$listeners"
        return 1
    fi
}

# 用本机到候选站点的 TLS 1.3 建连耗时挑选 Reality 伪装目标
select_reality_target() {
    local -a candidates=(
        "www.icloud.com"
        "xp.apple.com" "vs.aws.amazon.com" "www.xbox.com"
        "www.oracle.com" "images.nvidia.com" "www.amazon.com" "aws.amazon.com"
        "www.amd.com" "www.sony.com" "www.tesla.com" "www.intel.com"
        "www.nvidia.com" "www.apple.com"
    )
    local domain elapsed best_domain="" best_elapsed="" milliseconds

    echo -e "${YELLOW}正在检测 Reality 伪装目标的 TLS 1.3 建连延迟...${PLAIN}" >&2
    for domain in "${candidates[@]}"; do
        if elapsed=$(curl -4 --noproxy '*' --tlsv1.3 -s -o /dev/null \
            --connect-timeout 1.5 --max-time 1.5 -w '%{time_appconnect}' "https://${domain}"); then
            if [[ "$elapsed" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v value="$elapsed" 'BEGIN { exit !(value > 0) }'; then
                milliseconds=$(awk -v value="$elapsed" 'BEGIN { printf "%.0f", value * 1000 }')
                echo -e "  ${GREEN}${domain}: ${milliseconds} ms${PLAIN}" >&2
                if [[ -z "$best_elapsed" ]] || awk -v value="$elapsed" -v best="$best_elapsed" 'BEGIN { exit !(value < best) }'; then
                    best_domain="$domain"
                    best_elapsed="$elapsed"
                fi
                continue
            fi
        fi
        echo -e "  ${RED}${domain}: timeout${PLAIN}" >&2
    done

    if [[ -z "$best_domain" ]]; then
        echo -e "${RED}所有 Reality 候选目标均无法完成 TLS 1.3 握手。${PLAIN}" >&2
        return 1
    fi

    milliseconds=$(awk -v value="$best_elapsed" 'BEGIN { printf "%.0f", value * 1000 }')
    echo -e "${GREEN}已选择 Reality 目标: ${best_domain}:443 (${milliseconds} ms)${PLAIN}" >&2
    if [[ "$best_domain" == *apple.com || "$best_domain" == "www.icloud.com" ]]; then
        echo -e "${YELLOW}提示: 使用 Apple/iCloud 作为伪装目标可能带来 IP 封锁风险。${PLAIN}" >&2
    fi
    printf '%s\n' "$best_domain"
}

# BBR 与网络栈调优
apply_bbr_and_optimization() {
    echo -e "${YELLOW}正在配置 BBR 拥塞控制及 Linux 网络栈优化...${PLAIN}"
    modprobe tcp_bbr >/dev/null 2>&1 || true

    cat << 'EOF' > "$SYSCTL_BBR_FILE"
# 拥塞控制与排队算法 (BBR)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 缓冲区与滑动窗口
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1

# 队列与高并发
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

# 连接复用与超时清理
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 50000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 1024 65535
EOF

    mkdir -p /etc/security/limits.d
    cat << 'EOF' > "$LIMITS_FILE"
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    # OpenRC 默认不读取 sysctl.d，通过 local.d 在开机时应用
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        mkdir -p /etc/local.d
        cat << 'EOF' > "$LOCAL_D_FILE"
#!/bin/sh
sysctl -p /etc/sysctl.d/99-network-bbr.conf >/dev/null 2>&1
EOF
        chmod 0755 "$LOCAL_D_FILE"
    fi

    reload_sysctl
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    echo -e "${GREEN}网络栈调优完成，当前拥塞控制算法: ${cc}${PLAIN}"
}

# 获取并下载最新版本 sing-box
download_singbox() {
    detect_arch
    echo -e "${YELLOW}获取最新 sing-box 版本信息...${PLAIN}"
    local tag
    tag=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        echo -e "${RED}获取最新版本失败，请检查网络或 GitHub API 频率限制！${PLAIN}"
        exit 1
    fi

    local version="${tag#v}"
    local filename="sing-box-${version}-${ARCH}.tar.gz"
    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${filename}"

    echo -e "${GREEN}检测到架构: ${ARCH}，最新版本: ${tag}${PLAIN}"
    echo -e "${YELLOW}正在下载: ${url}${PLAIN}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! curl -L -f -o "${tmp_dir}/${filename}" "$url"; then
        echo -e "${RED}下载 sing-box 失败，请检查网络！${PLAIN}"
        rm -rf "$tmp_dir"
        exit 1
    fi

    if ! tar -xzf "${tmp_dir}/${filename}" -C "$tmp_dir" \
        || [[ ! -f "${tmp_dir}/sing-box-${version}-${ARCH}/sing-box" ]]; then
        echo -e "${RED}安装包无效或不包含 sing-box 可执行文件。${PLAIN}"
        rm -rf "$tmp_dir"
        exit 1
    fi

    mv "${tmp_dir}/sing-box-${version}-${ARCH}/sing-box" "${INSTALL_DIR}/sing-box"
    chmod +x "${INSTALL_DIR}/sing-box"
    rm -rf "$tmp_dir"

    echo -e "${GREEN}sing-box 二进制已就绪：${INSTALL_DIR}/sing-box${PLAIN}"
}

# 查看当前入站配置与分享链接
view_inbound_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}未找到配置文件: ${CONFIG_FILE}，请先执行安装或生成配置！${PLAIN}"
        return 1
    fi

    echo -e "\n${YELLOW}正在解析配置文件与服务器公网 IP...${PLAIN}"
    local server_ip
    server_ip=$(curl -s4m 6 https://api.ipify.org || curl -s4m 6 https://ip.sb || echo "YOUR_SERVER_IP")

    # 解析 Reality 入站
    local r_tag
    r_tag=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .tag' "$CONFIG_FILE" 2>/dev/null)
    
    # 解析 WS-TLS 入站
    local ws_tag
    ws_tag=$(jq -r '.inbounds[] | select(.tag=="vmess-ws-tls-in") | .tag' "$CONFIG_FILE" 2>/dev/null)

    # 解析 Shadowsocks 入站
    local ss_tag
    ss_tag=$(jq -r '.inbounds[] | select(.tag=="shadowsocks-in") | .tag' "$CONFIG_FILE" 2>/dev/null)

    # 解析 Hysteria2 入站
    local hy2_tag
    hy2_tag=$(jq -r '.inbounds[] | select(.tag=="hysteria2-in") | .tag' "$CONFIG_FILE" 2>/dev/null)

    # 解析 Argo 本地 WS 入站
    local argo_tag
    argo_tag=$(jq -r '.inbounds[] | select(.tag=="vmess-ws-argo-in") | .tag' "$CONFIG_FILE" 2>/dev/null)

    if jq -e 'any(.inbounds[]?; .tag == "vless-ws-tls-in")' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}提示: 检测到旧版 VLESS-WS-TLS 入站，当前版本已改为 VMess-WS-TLS。${PLAIN}"
        echo -e "${YELLOW}      执行 'sb gen' 可重新选择并生成入站配置。${PLAIN}"
    fi

    if [[ -z "$ss_tag" && -z "$r_tag" && -z "$ws_tag" && -z "$hy2_tag" && -z "$argo_tag" ]]; then
        echo -e "${RED}未找到可识别的入站配置，请执行 'sb gen' 重新生成。${PLAIN}"
        return 1
    fi

    echo -e "\n${CYAN}================================================================${PLAIN}"
    echo -e "${CYAN}                     当前入站节点配置详情                       ${PLAIN}"
    echo -e "${CYAN}================================================================${PLAIN}"

    if [[ -n "$ss_tag" ]]; then
        local ss_port ss_method ss_password
        ss_port=$(jq -r --arg t "$ss_tag" '.inbounds[] | select(.tag==$t) | .listen_port' "$CONFIG_FILE")
        ss_method=$(jq -r --arg t "$ss_tag" '.inbounds[] | select(.tag==$t) | .method' "$CONFIG_FILE")
        ss_password=$(jq -r --arg t "$ss_tag" '.inbounds[] | select(.tag==$t) | .password' "$CONFIG_FILE")

        echo -e "${GREEN}【协议: Shadowsocks (SS2022)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${server_ip}${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${ss_port}${PLAIN}"
        echo -e "  加密方式 (Method):  ${CYAN}${ss_method}${PLAIN}"
        echo -e "  密码 (Password):    ${CYAN}${ss_password}${PLAIN}"

        # SIP002: ss://base64url(method:password)@host:port#tag
        local ss_userinfo ss_link
        ss_userinfo=$(printf '%s' "${ss_method}:${ss_password}" | base64 | tr '+/' '-_' | tr -d '=\n')
        ss_link="ss://${ss_userinfo}@${server_ip}:${ss_port}#sing-box-Shadowsocks"
        echo -e "  分享链接 (Link):"
        echo -e "  ${YELLOW}${ss_link}${PLAIN}"
        echo -e "  Mihomo 节点 JSON (添加到 proxies 数组):"
        jq -n \
            --arg name "sing-box-Shadowsocks" \
            --arg server "$server_ip" \
            --argjson port "$ss_port" \
            --arg cipher "$ss_method" \
            --arg password "$ss_password" \
            '{
              name: $name,
              type: "ss",
              server: $server,
              port: $port,
              udp: true,
              cipher: $cipher,
              password: $password
            }'
        echo -e "----------------------------------------------------------------"
    fi

    if [[ -n "$r_tag" ]]; then
        local r_port r_uuid r_flow r_sni r_pri r_sid r_pub
        r_port=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .listen_port' "$CONFIG_FILE")
        r_uuid=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .users[0].uuid' "$CONFIG_FILE")
        r_flow=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .users[0].flow' "$CONFIG_FILE")
        r_sni=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .tls.server_name' "$CONFIG_FILE")
        r_pri=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .tls.reality.private_key' "$CONFIG_FILE")
        r_sid=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .tls.reality.short_id[0]' "$CONFIG_FILE")
        
        # sing-box 没有“由私钥推导公钥”的命令，只能依赖生成配置时留存的公钥文件
        r_pub=""
        if [[ -s "${CONFIG_DIR}/reality_pub.key" ]]; then
            r_pub=$(tr -d '[:space:]' < "${CONFIG_DIR}/reality_pub.key")
        fi

        echo -e "${GREEN}【协议: VLESS + Reality (直连推荐)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${server_ip}${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${r_port}${PLAIN}"
        echo -e "  用户 ID (UUID):     ${CYAN}${r_uuid}${PLAIN}"
        echo -e "  流控 (Flow):        ${CYAN}${r_flow}${PLAIN}"
        echo -e "  加密 (Encryption):  ${CYAN}none${PLAIN}"
        echo -e "  传输安全 (Security):${CYAN}reality${PLAIN}"
        echo -e "  伪装域名 (SNI):     ${CYAN}${r_sni}${PLAIN}"
        echo -e "  公钥 (PublicKey):   ${CYAN}${r_pub:-未找到记录}${PLAIN}"
        echo -e "  Short ID:           ${CYAN}${r_sid}${PLAIN}"
        
        if [[ -n "$r_pub" ]]; then
            local r_link="vless://${r_uuid}@${server_ip}:${r_port}?security=reality&encryption=none&pbk=${r_pub}&headerType=none&type=tcp&flow=${r_flow}&sni=${r_sni}&sid=${r_sid}#VLESS-Reality"
            echo -e "  分享链接 (Link):"
            echo -e "  ${YELLOW}${r_link}${PLAIN}"
        else
            echo -e "  ${YELLOW}未找到公钥记录 (${CONFIG_DIR}/reality_pub.key)，无法生成分享链接；"
            echo -e "  可执行 'sb gen' 重新生成配置，或手动补写该文件后重试。${PLAIN}"
        fi
        echo -e "----------------------------------------------------------------"
    fi

    if [[ -n "$ws_tag" ]]; then
        local ws_port ws_uuid ws_sni ws_path
        ws_port=$(jq -r --arg t "$ws_tag" '.inbounds[] | select(.tag==$t) | .listen_port' "$CONFIG_FILE")
        ws_uuid=$(jq -r --arg t "$ws_tag" '.inbounds[] | select(.tag==$t) | .users[0].uuid' "$CONFIG_FILE")
        ws_sni=$(jq -r --arg t "$ws_tag" '.inbounds[] | select(.tag==$t) | .tls.server_name' "$CONFIG_FILE")
        ws_path=$(jq -r --arg t "$ws_tag" '.inbounds[] | select(.tag==$t) | .transport.path' "$CONFIG_FILE")

        echo -e "${GREEN}【协议: VMess + WS + TLS (支持 CDN 回源)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${ws_sni} (或填服务器 IP / CDN 优选 IP)${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${ws_port}${PLAIN}"
        echo -e "  用户 ID (UUID):     ${CYAN}${ws_uuid}${PLAIN}"
        echo -e "  加密方式 (Cipher):  ${CYAN}auto${PLAIN}"
        echo -e "  传输协议 (Network): ${CYAN}ws${PLAIN}"
        echo -e "  传输安全 (Security):${CYAN}tls${PLAIN}"
        echo -e "  伪装域名 (SNI/Host):${CYAN}${ws_sni}${PLAIN}"
        echo -e "  路径 (Path):        ${CYAN}${ws_path}${PLAIN}"

        # vmess:// 分享链接 = base64(标准 vmess 节点 JSON)
        local ws_vmess_json ws_link
        ws_vmess_json=$(jq -cn \
            --arg ps "sing-box-VMess-WS-TLS" \
            --arg add "$ws_sni" \
            --argjson port "$ws_port" \
            --arg id "$ws_uuid" \
            --arg host "$ws_sni" \
            --arg path "$ws_path" \
            --arg alpn "http/1.1" \
            '{v: "2", ps: $ps, add: $add, port: ($port | tostring), id: $id, aid: "0",
              scy: "auto", net: "ws", type: "none", host: $host, path: $path,
              tls: "tls", sni: $host, alpn: $alpn, fp: "chrome"}')
        ws_link="vmess://$(printf '%s' "$ws_vmess_json" | base64 | tr -d '\n')"
        echo -e "  分享链接 (Link):"
        echo -e "  ${YELLOW}${ws_link}${PLAIN}"
        echo -e "  Mihomo 节点 JSON (添加到 proxies 数组):"
        jq -n \
            --arg name "sing-box-VMess-WS-TLS" \
            --arg server "$ws_sni" \
            --argjson port "$ws_port" \
            --arg id "$ws_uuid" \
            --arg host "$ws_sni" \
            --arg path "$ws_path" \
            '{
              name: $name,
              type: "vmess",
              server: $server,
              port: $port,
              uuid: $id,
              alterId: 0,
              cipher: "auto",
              udp: true,
              tls: true,
              servername: $host,
              "client-fingerprint": "chrome",
              network: "ws",
              "ws-opts": {
                path: $path,
                headers: { Host: $host }
              }
            }'
        echo -e "----------------------------------------------------------------"
    fi

    if [[ -n "$hy2_tag" ]]; then
        local hy2_port hy2_password hy2_sni hy2_insecure=0
        hy2_port=$(jq -r '.inbounds[] | select(.tag=="hysteria2-in") | .listen_port' "$CONFIG_FILE")
        hy2_password=$(jq -r '.inbounds[] | select(.tag=="hysteria2-in") | .users[0].password' "$CONFIG_FILE")

        hy2_sni=$(jq -r '.inbounds[] | select(.tag=="hysteria2-in") | (.tls.server_name // "")' "$CONFIG_FILE")
        if [[ -z "$hy2_sni" ]]; then
            # 兼容旧配置：未写入 server_name 时从证书中推断
            hy2_sni=$(get_cert_sni)
            if [[ -z "$hy2_sni" ]]; then
                hy2_sni="www.bing.com"
                hy2_insecure=1
            fi
        fi
        if [[ ! -s "${CERT_DIR}/fullchain.pem" ]] || is_self_signed_cert; then
            hy2_insecure=1
        fi

        echo -e "${GREEN}【协议: Hysteria2 (QUIC / UDP)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${server_ip}${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${hy2_port}${PLAIN} (UDP)"
        echo -e "  密码 (Password):    ${CYAN}${hy2_password}${PLAIN}"
        echo -e "  SNI:                ${CYAN}${hy2_sni}${PLAIN}"
        if [[ $hy2_insecure -eq 1 ]]; then
            echo -e "  证书校验:           ${YELLOW}跳过（自签证书，客户端需 insecure / skip-cert-verify）${PLAIN}"
        fi
        echo -e "  提示:               请确认本机防火墙与云安全组已放行 ${hy2_port}/udp"

        local hy2_link="hysteria2://${hy2_password}@${server_ip}:${hy2_port}/?sni=${hy2_sni}"
        [[ $hy2_insecure -eq 1 ]] && hy2_link+="&insecure=1"
        hy2_link+="#sing-box-Hysteria2"
        echo -e "  分享链接 (Link):"
        echo -e "  ${YELLOW}${hy2_link}${PLAIN}"
        echo -e "  Mihomo 节点 JSON (添加到 proxies 数组):"
        jq -n \
            --arg name "sing-box-Hysteria2" \
            --arg server "$server_ip" \
            --argjson port "$hy2_port" \
            --arg password "$hy2_password" \
            --arg sni "$hy2_sni" \
            --argjson insecure "$hy2_insecure" \
            '{
              name: $name,
              type: "hysteria2",
              server: $server,
              port: $port,
              password: $password,
              sni: $sni,
              alpn: ["h3"]
            } + (if $insecure == 1 then {"skip-cert-verify": true} else {} end)'
        echo -e "----------------------------------------------------------------"
    fi

    if [[ -n "$argo_tag" ]]; then
        view_argo_info
    fi

    # 住宅 IP 出站
    if jq -e 'any(.outbounds[]?; .tag == "residential-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
        local proxy_type proxy_server proxy_port proxy_user proxy_pass proxy_type_display
        proxy_type=$(jq -r '.outbounds[] | select(.tag=="residential-out") | .type' "$CONFIG_FILE")
        proxy_server=$(jq -r '.outbounds[] | select(.tag=="residential-out") | .server' "$CONFIG_FILE")
        proxy_port=$(jq -r '.outbounds[] | select(.tag=="residential-out") | .server_port' "$CONFIG_FILE")
        proxy_user=$(jq -r '.outbounds[] | select(.tag=="residential-out") | (.username // "")' "$CONFIG_FILE")
        proxy_pass=$(jq -r '.outbounds[] | select(.tag=="residential-out") | (.password // "")' "$CONFIG_FILE")
        if [[ "$proxy_type" == "http" ]]; then
            proxy_type_display="HTTP"
        else
            proxy_type_display="SOCKS5"
        fi

        echo -e "${GREEN}【出站: 住宅 IP 代理（默认出站）】${PLAIN}"
        echo -e "  类型:   ${CYAN}${proxy_type_display}${PLAIN}"
        echo -e "  地址:   ${CYAN}${proxy_server}:${proxy_port}${PLAIN}"
        if [[ -n "$proxy_user" ]]; then
            echo -e "  用户名: ${CYAN}${proxy_user}${PLAIN}"
            echo -e "  密码:   ${CYAN}${proxy_pass:-<空>}${PLAIN}"
        else
            echo -e "  认证:   ${CYAN}无${PLAIN}"
        fi
        echo -e "----------------------------------------------------------------"
    fi

    if [[ -n "$ws_tag" || -n "$hy2_tag" ]]; then
        echo -e "${RED}证书目录检查:${PLAIN}"
        echo -e "  公钥证书: ${CERT_DIR}/fullchain.pem $([[ -f "${CERT_DIR}/fullchain.pem" ]] && echo -e "${GREEN}[已存在]${PLAIN}" || echo -e "${RED}[缺失]${PLAIN}")"
        echo -e "  私钥证书: ${CERT_DIR}/privkey.pem   $([[ -f "${CERT_DIR}/privkey.pem" ]] && echo -e "${GREEN}[已存在]${PLAIN}" || echo -e "${RED}[缺失]${PLAIN}")"
    else
        echo -e "${CYAN}当前未启用 TLS 入站，无需配置证书。${PLAIN}"
    fi
    echo -e "${CYAN}================================================================${PLAIN}\n"
}


# 交互选择需要启用的入站协议（至少一个）
select_inbound_protocols() {
    ENABLE_SS=0
    ENABLE_REALITY=0
    ENABLE_VMESS=0
    ENABLE_HY2=0
    ENABLE_ARGO=0
    SELECTED_PORTS=()

    local input token
    while true; do
        echo -e "\n${CYAN}请选择要启用的入站协议（可多选，至少选择一个）：${PLAIN}"
        echo -e "  ${GREEN}1)${PLAIN} Shadowsocks      ${YELLOW}默认端口 ${DEFAULT_SS_PORT}，加密 ${SS_METHOD}${PLAIN}"
        echo -e "  ${GREEN}2)${PLAIN} VLESS + Reality  ${YELLOW}默认端口 ${DEFAULT_REALITY_PORT}${PLAIN}"
        echo -e "  ${GREEN}3)${PLAIN} VMess + WS + TLS ${YELLOW}默认端口 ${DEFAULT_VMESS_WS_PORT}${PLAIN}"
        echo -e "  ${GREEN}4)${PLAIN} Hysteria2        ${YELLOW}默认端口 ${DEFAULT_HY2_PORT} (UDP)，QUIC${PLAIN}"
        echo -e "  ${GREEN}5)${PLAIN} Argo 隧道        ${YELLOW}本地明文 VMess-WS(默认 ${DEFAULT_ARGO_WS_PORT}) + quick/named${PLAIN}"
        read -rp "请输入编号（多个用空格或逗号分隔，输入 all 全选）: " input </dev/tty || return 1
        input=$(printf '%s' "$input" | tr ',' ' ')

        local ss=0 reality=0 vmess=0 hy2=0 argo=0 invalid=0
        for token in $input; do
            case "$token" in
                1) ss=1 ;;
                2) reality=1 ;;
                3) vmess=1 ;;
                4) hy2=1 ;;
                5) argo=1 ;;
                all|ALL|All) ss=1; reality=1; vmess=1; hy2=1; argo=1 ;;
                *) invalid=1 ;;
            esac
        done

        if [[ $invalid -eq 1 || $((ss + reality + vmess + hy2 + argo)) -eq 0 ]]; then
            echo -e "${RED}输入无效，请输入 1、2、3、4、5 的组合（如 1,3），或输入 all。${PLAIN}"
            continue
        fi

        ENABLE_SS=$ss
        ENABLE_REALITY=$reality
        ENABLE_VMESS=$vmess
        ENABLE_HY2=$hy2
        ENABLE_ARGO=$argo
        break
    done

    echo -e "${GREEN}已选择入站协议：${PLAIN}"
    [[ $ENABLE_SS -eq 1 ]] && echo -e "  - Shadowsocks"
    [[ $ENABLE_REALITY -eq 1 ]] && echo -e "  - VLESS + Reality"
    [[ $ENABLE_VMESS -eq 1 ]] && echo -e "  - VMess + WS + TLS"
    [[ $ENABLE_HY2 -eq 1 ]] && echo -e "  - Hysteria2"
    [[ $ENABLE_ARGO -eq 1 ]] && echo -e "  - Argo 隧道 (VMess-WS 明文)"
    return 0
}

# 端口是否已被本次选择使用
port_in_selected() {
    local p
    for p in "${SELECTED_PORTS[@]}"; do
        [[ "$p" == "$1" ]] && return 0
    done
    return 1
}

# 提示输入端口，直接回车返回默认值
prompt_inbound_port() {
    local name="$1" default_port="$2" input
    while true; do
        read -rp "${name} 端口 [默认 ${default_port}]（直接回车使用默认值）: " input </dev/tty || input=""
        input=$(printf '%s' "$input" | tr -d '[:space:]')
        if [[ -z "$input" ]]; then
            if port_in_selected "$default_port"; then
                echo -e "${RED}默认端口 ${default_port} 已被其他协议使用，请输入自定义端口。${PLAIN}" >&2
                continue
            fi
            printf '%s\n' "$default_port"
            return 0
        fi
        if [[ "$input" =~ ^[0-9]{1,5}$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
            input=$((10#$input))
            if port_in_selected "$input"; then
                echo -e "${RED}端口 ${input} 与已配置的协议重复，请更换。${PLAIN}" >&2
                continue
            fi
            printf '%s\n' "$input"
            return 0
        fi
        echo -e "${RED}端口无效，请输入 1-65535 之间的数字，或直接回车使用默认值。${PLAIN}" >&2
    done
}

# 逐个配置已选协议的入站端口
configure_inbound_ports() {
    SS_PORT="$DEFAULT_SS_PORT"
    REALITY_PORT="$DEFAULT_REALITY_PORT"
    VMESS_WS_PORT="$DEFAULT_VMESS_WS_PORT"
    HY2_PORT="$DEFAULT_HY2_PORT"
    ARGO_WS_PORT="$DEFAULT_ARGO_WS_PORT"
    SELECTED_PORTS=()

    if [[ $ENABLE_SS -eq 1 ]]; then
        SS_PORT=$(prompt_inbound_port "Shadowsocks" "$SS_PORT")
        SELECTED_PORTS+=("$SS_PORT")
    fi
    if [[ $ENABLE_REALITY -eq 1 ]]; then
        REALITY_PORT=$(prompt_inbound_port "VLESS + Reality" "$REALITY_PORT")
        SELECTED_PORTS+=("$REALITY_PORT")
    fi
    if [[ $ENABLE_VMESS -eq 1 ]]; then
        VMESS_WS_PORT=$(prompt_inbound_port "VMess + WS + TLS" "$VMESS_WS_PORT")
        SELECTED_PORTS+=("$VMESS_WS_PORT")
    fi
    if [[ $ENABLE_HY2 -eq 1 ]]; then
        HY2_PORT=$(prompt_inbound_port "Hysteria2 (UDP)" "$HY2_PORT")
        SELECTED_PORTS+=("$HY2_PORT")
    fi
    if [[ $ENABLE_ARGO -eq 1 ]]; then
        ARGO_WS_PORT=$(prompt_inbound_port "Argo 本地 WS (仅 127.0.0.1)" "$ARGO_WS_PORT")
        SELECTED_PORTS+=("$ARGO_WS_PORT")
    fi

    echo -e "${GREEN}入站端口：${PLAIN}"
    [[ $ENABLE_SS -eq 1 ]] && echo -e "  - Shadowsocks: ${SS_PORT}"
    [[ $ENABLE_REALITY -eq 1 ]] && echo -e "  - VLESS + Reality: ${REALITY_PORT}"
    [[ $ENABLE_VMESS -eq 1 ]] && echo -e "  - VMess + WS + TLS: ${VMESS_WS_PORT}"
    [[ $ENABLE_HY2 -eq 1 ]] && echo -e "  - Hysteria2: ${HY2_PORT} (UDP)"
    [[ $ENABLE_ARGO -eq 1 ]] && echo -e "  - Argo 本地 WS: ${ARGO_WS_PORT} (仅 127.0.0.1)"
    return 0
}

# 解析 host:port 形式的代理地址，兼容 scheme 前缀与 IPv6 方括号
parse_proxy_address() {
    local input="$1"
    input="${input#http://}"
    input="${input#https://}"
    input="${input#socks5h://}"
    input="${input#socks5://}"
    input="${input#socks://}"
    input="${input%%/*}"

    if [[ "$input" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
        PROXY_HOST="${BASH_REMATCH[1]}"
        PROXY_PORT="${BASH_REMATCH[2]}"
    elif [[ "$input" =~ ^([^:]+):([0-9]+)$ ]]; then
        PROXY_HOST="${BASH_REMATCH[1]}"
        PROXY_PORT="${BASH_REMATCH[2]}"
    else
        return 1
    fi

    [[ -n "$PROXY_HOST" ]] || return 1
    [[ "$PROXY_HOST" != *[[:space:]]* ]] || return 1
    (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || return 1
    return 0
}

# 配置住宅 IP 出站（可选）
configure_residential_outbound() {
    RESIDENTIAL_ENABLED=0
    RESIDENTIAL_TYPE=""
    RESIDENTIAL_HOST=""
    RESIDENTIAL_PORT=""
    RESIDENTIAL_USER=""
    RESIDENTIAL_PASS=""

    local use_proxy
    read -rp "是否启用住宅 IP 出站（启用后默认流量从代理出站）？[y/N]: " use_proxy </dev/tty || return 0
    if [[ ! "$use_proxy" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo -e "${YELLOW}未启用住宅 IP 出站，流量将直接出站。${PLAIN}"
        return 0
    fi

    local type_choice
    while true; do
        echo -e "${CYAN}请选择住宅 IP 代理类型：${PLAIN}"
        echo -e "  ${GREEN}1)${PLAIN} HTTP"
        echo -e "  ${GREEN}2)${PLAIN} SOCKS5"
        read -rp "请输入编号 [1-2]: " type_choice </dev/tty || return 0
        type_choice=$(printf '%s' "$type_choice" | tr '[:upper:]' '[:lower:]')
        case "$type_choice" in
            1|http) RESIDENTIAL_TYPE="http"; break ;;
            2|socks|socks5) RESIDENTIAL_TYPE="socks"; break ;;
            *) echo -e "${RED}输入无效，请输入 1 或 2。${PLAIN}" ;;
        esac
    done

    local address
    while true; do
        read -rp "请输入代理地址（host:port，例如 1.2.3.4:8080）: " address </dev/tty || return 0
        if parse_proxy_address "$address"; then
            RESIDENTIAL_HOST="$PROXY_HOST"
            RESIDENTIAL_PORT="$PROXY_PORT"
            break
        fi
        echo -e "${RED}地址格式无效，请使用 host:port 形式。${PLAIN}"
    done

    read -rp "代理用户名（可留空）: " RESIDENTIAL_USER </dev/tty || RESIDENTIAL_USER=""
    if [[ -n "$RESIDENTIAL_USER" ]]; then
        read -rsp "代理密码（可留空，输入不回显）: " RESIDENTIAL_PASS </dev/tty || RESIDENTIAL_PASS=""
        echo
    else
        RESIDENTIAL_PASS=""
    fi

    RESIDENTIAL_ENABLED=1
    local type_display="SOCKS5"
    [[ "$RESIDENTIAL_TYPE" == "http" ]] && type_display="HTTP"
    echo -e "${GREEN}已启用住宅 IP 出站：${type_display} ${RESIDENTIAL_HOST}:${RESIDENTIAL_PORT}${PLAIN}"
}

# 按用户选择的协议生成入站、嗅探与基础拦截规则的配置
generate_production_config() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CERT_DIR"

    echo -e "\n${CYAN}=================================================${PLAIN}"
    echo -e "${CYAN}      sing-box 节点配置生成器 (可选多入站)        ${PLAIN}"
    echo -e "${CYAN}=================================================${PLAIN}"

    select_inbound_protocols || return 1
    configure_inbound_ports
    configure_residential_outbound

    local ws_domain=""
    if [[ $ENABLE_VMESS -eq 1 || $ENABLE_HY2 -eq 1 ]]; then
        ensure_dummy_cert || return 1
    fi

    if [[ $ENABLE_VMESS -eq 1 ]]; then
        while [[ -z "$ws_domain" ]]; do
            read -rp "请输入 VMess-WS-TLS 入站绑定的域名 (例如: node.yourdomain.com): " ws_domain </dev/tty
            ws_domain=$(echo "$ws_domain" | tr -d '[:space:]')
            ws_domain=${ws_domain%.}
            ws_domain=${ws_domain,,}
            if ! validate_domain "$ws_domain"; then
                echo -e "${RED}域名格式无效，请输入完整的域名，例如 node.example.com。${PLAIN}"
                ws_domain=""
            fi
        done
    fi

    local hy2_sni=""
    if [[ $ENABLE_HY2 -eq 1 ]]; then
        if [[ $ENABLE_VMESS -eq 1 && -n "$ws_domain" ]]; then
            # 与 VMess-WS-TLS 共用证书时，沿用用户输入的域名作为 SNI
            hy2_sni="$ws_domain"
        else
            hy2_sni=$(get_cert_sni)
            if [[ -z "$hy2_sni" ]]; then
                if is_self_signed_cert; then
                    hy2_sni="www.bing.com"
                else
                    while true; do
                        read -rp "请输入 Hysteria2 客户端使用的 SNI/证书域名: " hy2_sni </dev/tty || return 1
                        hy2_sni=$(printf '%s' "$hy2_sni" | tr -d '[:space:]')
                        hy2_sni=${hy2_sni%.}
                        hy2_sni=${hy2_sni,,}
                        if validate_domain "$hy2_sni"; then
                            break
                        fi
                        echo -e "${RED}域名格式无效，请输入完整域名，例如 node.example.com。${PLAIN}"
                    done
                fi
            fi
        fi
        echo -e "${GREEN}Hysteria2 SNI: ${hy2_sni}${PLAIN}"
        if is_self_signed_cert; then
            echo -e "${YELLOW}提示: 当前使用自签证书，Hysteria2 客户端需要开启跳过证书校验 (insecure / skip-cert-verify)。${PLAIN}"
        fi
    fi

    local argo_mode="" argo_public_domain="" argo_token="" argo_edge_ip="4" argo_named=0
    if [[ $ENABLE_ARGO -eq 1 ]]; then
        echo -e "\n${CYAN}Argo 隧道配置${PLAIN}"
        echo -e "  ${GREEN}1)${PLAIN} quick  随机域名，使用外部 cloudflared + 本地明文 WS"
        echo -e "  ${GREEN}2)${PLAIN} named  固定域名，使用 sing-box 内置 cloudflared（需要 Tunnel Token）"
        local argo_mode_choice
        read -rp "请选择 Argo 模式 [1/2，默认 1]: " argo_mode_choice </dev/tty || argo_mode_choice=""
        case "$argo_mode_choice" in
            2|named|NAMED) argo_mode="named"; argo_named=1 ;;
            *) argo_mode="quick" ;;
        esac

        local argo_ip_choice
        read -rp "Argo 连接 Cloudflare 边缘使用 IPv4 还是 IPv6？[4/6，默认 4]: " argo_ip_choice </dev/tty || argo_ip_choice=""
        if [[ "$argo_ip_choice" == "6" ]]; then
            argo_edge_ip="6"
        else
            argo_edge_ip="4"
        fi

        if [[ $argo_named -eq 1 ]]; then
            while true; do
                read -rsp "请输入 Cloudflare Tunnel Token（输入不回显）: " argo_token </dev/tty || argo_token=""
                echo
                argo_token=$(printf '%s' "$argo_token" | tr -d '[:space:]')
                if [[ -n "$argo_token" ]]; then
                    break
                fi
                echo -e "${RED}Token 不能为空。${PLAIN}"
            done

            while true; do
                read -rp "请输入该 Tunnel 绑定的完整域名 (例如 argo.example.com): " argo_public_domain </dev/tty || argo_public_domain=""
                argo_public_domain=$(printf '%s' "$argo_public_domain" | tr -d '[:space:]')
                argo_public_domain=${argo_public_domain%.}
                argo_public_domain=${argo_public_domain,,}
                if validate_domain "$argo_public_domain"; then
                    break
                fi
                echo -e "${RED}域名格式无效，请输入完整域名，例如 argo.example.com。${PLAIN}"
            done

            echo -e "${YELLOW}请确保已在 Cloudflare Zero Trust 中将该域名指向 http://127.0.0.1:${ARGO_WS_PORT}${PLAIN}"
        fi
        echo -e "${GREEN}Argo 模式: ${argo_mode}${PLAIN}"
    fi

    # VLESS 与 VMess 共用固定 UUID
    local uuid="$FIXED_UUID"

    local reality_domain="" private_key="" public_key="" short_id=""
    if [[ $ENABLE_REALITY -eq 1 ]]; then
        echo -e "${YELLOW}正在生成 Reality 密钥对与 Short-ID...${PLAIN}"
        reality_domain=$(select_reality_target) || {
            echo -e "${RED}无法选择 Reality 伪装目标，未写入新配置。请检查服务器的 IPv4 出站网络后重试。${PLAIN}"
            return 1
        }

        local keypair
        keypair=$(${INSTALL_DIR}/sing-box generate reality-keypair) || {
            echo -e "${RED}无法生成 Reality 密钥对。${PLAIN}"
            return 1
        }
        private_key=$(echo "$keypair" | grep -iE 'Private[[:space:]]*key' | awk '{print $2}' | tr -d '[:space:]')
        public_key=$(echo "$keypair" | grep -iE 'Public[[:space:]]*key' | awk '{print $2}' | tr -d '[:space:]')

        if [[ -z "$private_key" || -z "$public_key" ]]; then
            echo -e "${RED}无法解析 Reality 密钥对，sing-box 版本可能不兼容。${PLAIN}"
            return 1
        fi

        # 将生成的公钥留存一份备查
        echo "$public_key" > "${CONFIG_DIR}/reality_pub.key"
        short_id=$(openssl rand -hex 8 2>/dev/null || ${INSTALL_DIR}/sing-box generate rand --hex 8)
    fi

    local ss_password=""
    if [[ $ENABLE_SS -eq 1 ]]; then
        # 2022-blake3-aes-128-gcm 需要 16 字节密钥（base64 编码）
        ss_password=$(openssl rand -base64 16 | tr -d '\n')
    fi

    local hy2_password=""
    if [[ $ENABLE_HY2 -eq 1 ]]; then
        # 使用十六进制，避免 URI 中出现需要转义的字符
        hy2_password=$(openssl rand -hex 16)
    fi

    local inbounds='[]'

    if [[ $ENABLE_SS -eq 1 ]]; then
        inbounds=$(jq -c \
            --argjson port "$SS_PORT" \
            --arg method "$SS_METHOD" \
            --arg password "$ss_password" \
            '. + [{
              "type": "shadowsocks",
              "tag": "shadowsocks-in",
              "listen": "::",
              "listen_port": $port,
              "method": $method,
              "password": $password
            }]' <<<"$inbounds") || return 1
    fi

    if [[ $ENABLE_REALITY -eq 1 ]]; then
        inbounds=$(jq -c \
            --argjson port "$REALITY_PORT" \
            --arg uuid "$uuid" \
            --arg domain "$reality_domain" \
            --arg private_key "$private_key" \
            --arg short_id "$short_id" \
            '. + [{
              "type": "vless",
              "tag": "vless-reality-in",
              "listen": "::",
              "listen_port": $port,
              "users": [
                {
                  "uuid": $uuid,
                  "flow": "xtls-rprx-vision"
                }
              ],
              "tls": {
                "enabled": true,
                "server_name": $domain,
                "reality": {
                  "enabled": true,
                  "handshake": {
                    "server": $domain,
                    "server_port": 443
                  },
                  "private_key": $private_key,
                  "short_id": [
                    $short_id
                  ]
                }
              }
            }]' <<<"$inbounds") || return 1
    fi

    if [[ $ENABLE_VMESS -eq 1 ]]; then
        inbounds=$(jq -c \
            --argjson port "$VMESS_WS_PORT" \
            --arg uuid "$uuid" \
            --arg domain "$ws_domain" \
            --arg path "$VMESS_WS_PATH" \
            --arg cert "${CERT_DIR}/fullchain.pem" \
            --arg key "${CERT_DIR}/privkey.pem" \
            '. + [{
              "type": "vmess",
              "tag": "vmess-ws-tls-in",
              "listen": "::",
              "listen_port": $port,
              "users": [
                {
                  "uuid": $uuid,
                  "alterId": 0
                }
              ],
              "tls": {
                "enabled": true,
                "server_name": $domain,
                "certificate_path": $cert,
                "key_path": $key
              },
              "transport": {
                "type": "ws",
                "path": $path,
                "max_early_data": 2048,
                "early_data_header_name": "Sec-WebSocket-Protocol"
              }
            }]' <<<"$inbounds") || return 1
    fi

    if [[ $ENABLE_HY2 -eq 1 ]]; then
        inbounds=$(jq -c \
            --argjson port "$HY2_PORT" \
            --arg password "$hy2_password" \
            --arg sni "$hy2_sni" \
            --arg cert "${CERT_DIR}/fullchain.pem" \
            --arg key "${CERT_DIR}/privkey.pem" \
            '. + [{
              "type": "hysteria2",
              "tag": "hysteria2-in",
              "listen": "::",
              "listen_port": $port,
              "users": [
                {
                  "password": $password
                }
              ],
              "tls": {
                "enabled": true,
                "server_name": $sni,
                "alpn": ["h3"],
                "certificate_path": $cert,
                "key_path": $key
              }
            }]' <<<"$inbounds") || return 1
    fi

    if [[ $ENABLE_ARGO -eq 1 ]]; then
        inbounds=$(jq -c \
            --argjson port "$ARGO_WS_PORT" \
            --arg uuid "$uuid" \
            --arg path "$ARGO_WS_PATH" \
            '. + [{
              "type": "vmess",
              "tag": "vmess-ws-argo-in",
              "listen": "127.0.0.1",
              "listen_port": $port,
              "users": [
                {
                  "uuid": $uuid,
                  "alterId": 0
                }
              ],
              "transport": {
                "type": "ws",
                "path": $path
              }
            }]' <<<"$inbounds") || return 1
    fi

    if [[ $ENABLE_ARGO -eq 1 && $argo_named -eq 1 ]]; then
        inbounds=$(jq -c \
            --arg token "$argo_token" \
            --argjson edge_ip "$argo_edge_ip" \
            '. + [{
              "type": "cloudflared",
              "tag": "cloudflared-in",
              "token": $token,
              "protocol": "http2",
              "edge_ip_version": $edge_ip
            }]' <<<"$inbounds") || return 1
    fi

    # 出站：启用住宅 IP 时作为默认出站
    local outbounds final_outbound="direct"
    if [[ $RESIDENTIAL_ENABLED -eq 1 ]]; then
        final_outbound="residential-out"
        local has_auth=0
        [[ -n "$RESIDENTIAL_USER" ]] && has_auth=1
        outbounds=$(jq -cn \
            --arg type "$RESIDENTIAL_TYPE" \
            --arg server "$RESIDENTIAL_HOST" \
            --argjson port "$RESIDENTIAL_PORT" \
            --argjson auth "$has_auth" \
            --arg username "$RESIDENTIAL_USER" \
            --arg password "$RESIDENTIAL_PASS" \
            '[({
              "type": $type,
              "tag": "residential-out",
              "server": $server,
              "server_port": $port
            }
            + (if $type == "socks" then {"version": "5"} else {} end)
            + (if $auth == 1 then {"username": $username, "password": $password} else {} end)),
            {"type": "direct", "tag": "direct"}]') || return 1
    else
        outbounds='[{"type":"direct","tag":"direct"}]'
    fi

    if ! jq -n --argjson inbounds "$inbounds" --argjson outbounds "$outbounds" --arg final "$final_outbound" --argjson argo_named "$argo_named" '{
      "log": {
        "disabled": false,
        "level": "info",
        "timestamp": true
      },
      "inbounds": $inbounds,
      "outbounds": $outbounds,
      "route": {
        "rules": ([
          (if $argo_named == 1 then {
            "inbound": ["cloudflared-in"],
            "action": "route",
            "outbound": "direct"
          } else empty end),
          {
            "action": "sniff",
            "sniffer": [
              "http",
              "tls",
              "quic"
            ]
          },
          {
            "rule_set": [
              "geosite-category-ads-all"
            ],
            "action": "reject"
          },
          {
            "ip_is_private": true,
            "action": "reject"
          }
        ]),
        "rule_set": [
          {
            "type": "remote",
            "tag": "geosite-category-ads-all",
            "format": "binary",
            "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs",
            "download_detour": "direct"
          }
        ],
        "final": $final,
        "auto_detect_interface": true
      }
    }' > "$CONFIG_FILE"; then
        echo -e "${RED}配置文件写入失败，请检查 jq 是否可用。${PLAIN}"
        return 1
    fi

    if [[ $ENABLE_ARGO -eq 1 ]]; then
        save_argo_state "$argo_mode" "$argo_public_domain" "$argo_edge_ip" || {
            echo -e "${RED}Argo 状态写入失败。${PLAIN}"
            return 1
        }
        if [[ $argo_named -eq 1 ]]; then
            # 内置 cloudflared 的 token 写在 config.json 中
            chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        fi
    fi

    echo -e "${GREEN}配置文件生成并写入成功！${PLAIN}"
    view_inbound_info
}

# 注册系统服务（systemd / OpenRC）
setup_service() {
    case "$INIT_SYSTEM" in
        systemd)
            cat << EOF > "$SYSTEMD_FILE"
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStartPre=${INSTALL_DIR}/sing-box check -c ${CONFIG_FILE}
ExecStart=${INSTALL_DIR}/sing-box run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=10s
LimitNPROC=10000
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

            systemctl daemon-reload || return 1
            if ! systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
                echo -e "${RED}设置开机自启失败，请手动执行 systemctl enable sing-box 排查。${PLAIN}"
                return 1
            fi
            echo -e "${GREEN}systemd 服务已注册并配置为开机自启。${PLAIN}"
            ;;
        openrc)
            cat << EOF > "$INITD_FILE"
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="sing-box service"

supervisor="supervise-daemon"
command="${INSTALL_DIR}/sing-box"
command_args="run -c ${CONFIG_FILE}"
pidfile="/run/${SERVICE_NAME}.pid"
respawn_delay=5
respawn_max=0
output_log="${SERVICE_LOG}"
error_log="${SERVICE_LOG}"
rc_ulimit="-n 1048576"

depend() {
    need net
    after firewall
}

start_pre() {
    ${INSTALL_DIR}/sing-box check -c ${CONFIG_FILE}
}
EOF
            chmod 0755 "$INITD_FILE"
            if ! rc-update add "$SERVICE_NAME" default >/dev/null 2>&1; then
                echo -e "${RED}无法将 sing-box 加入 OpenRC 默认运行级别。${PLAIN}"
                return 1
            fi
            echo -e "${GREEN}OpenRC 服务已注册并配置为开机自启。${PLAIN}"
            ;;
        *)
            echo -e "${RED}未检测到 systemd 或 OpenRC，无法注册服务。${PLAIN}"
            return 1
            ;;
    esac
}

# 启动失败时输出最近日志与排查建议
show_start_failure() {
    echo -e "${RED}sing-box 启动失败。以下是最近的日志：${PLAIN}"
    service_logs_recent
    local port_regex
    port_regex=$(jq -r '[.inbounds[]? | (.port // .listen_port)] | map(tostring) | join("|")' "$CONFIG_FILE" 2>/dev/null)
    [[ -z "$port_regex" || "$port_regex" == "null" ]] && port_regex="${DEFAULT_SS_PORT}|${DEFAULT_REALITY_PORT}|${DEFAULT_VMESS_WS_PORT}|${DEFAULT_HY2_PORT}|${DEFAULT_ARGO_WS_PORT}"
    echo -e "${YELLOW}可依次执行：sb test、ss -lntup | grep -E ':(${port_regex})'、sb log 进行排查。${PLAIN}"
}

# 服务控制函数
start_service() {
    test_config || return 1
    if service_start; then
        echo -e "${GREEN}sing-box 服务已启动。${PLAIN}"
        if argo_is_quick; then
            argo_external_start || echo -e "${YELLOW}Argo 外部 cloudflared 启动异常，请执行 'sb argo log' 排查。${PLAIN}"
        fi
        check_status
    else
        show_start_failure
        return 1
    fi
}

stop_service() {
    if argo_is_quick; then
        argo_external_stop
    fi
    service_stop
    echo -e "${YELLOW}sing-box 已停止。${PLAIN}"
}

restart_service() {
    test_config || return 1
    if service_restart; then
        echo -e "${GREEN}sing-box 已重启。${PLAIN}"
        if argo_is_quick; then
            argo_external_restart || echo -e "${YELLOW}Argo 外部 cloudflared 重启异常，请执行 'sb argo log' 排查。${PLAIN}"
        fi
        check_status
    else
        show_start_failure
        return 1
    fi
}

check_status() {
    if service_is_active; then
        echo -e "运行状态: ${GREEN}运行中 (Active)${PLAIN}"
    else
        echo -e "运行状态: ${RED}未运行 (Inactive)${PLAIN}"
        echo -e "${YELLOW}提示: 若启动失败，可运行 'sb test' 查看具体配置报错信息。${PLAIN}"
    fi

    if argo_is_configured; then
        local mode domain
        mode=$(argo_mode)
        domain=$(argo_domain)
        if [[ "$mode" == "quick" ]]; then
            if [[ -z "$domain" ]] && argo_service_is_active; then
                domain=$(refresh_argo_domain_from_log 2>/dev/null || true)
            fi
            if argo_service_is_active; then
                echo -e "Argo 隧道: ${GREEN}运行中${PLAIN} (quick, 外部 cloudflared) ${CYAN}${domain:-域名待生成}${PLAIN}"
            else
                echo -e "Argo 隧道: ${RED}未运行${PLAIN} (quick, 外部 cloudflared)"
            fi
        elif [[ "$mode" == "named" ]]; then
            if service_is_active; then
                echo -e "Argo 隧道: ${GREEN}运行中${PLAIN} (named, sing-box 内置) ${CYAN}${domain:-未配置域名}${PLAIN}"
            else
                echo -e "Argo 隧道: ${RED}未运行${PLAIN} (named, sing-box 内置)"
            fi
        else
            echo -e "Argo 隧道: ${YELLOW}模式配置缺失${PLAIN}"
        fi
    fi
}

view_logs() {
    service_logs_follow
}

test_config() {
    if [[ ! -x "${INSTALL_DIR}/sing-box" ]]; then
        echo -e "${RED}未找到 sing-box 可执行文件：${INSTALL_DIR}/sing-box${PLAIN}"
        return 1
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}未找到配置文件：${CONFIG_FILE}${PLAIN}"
        return 1
    fi
    # 仅在启用需要证书的入站（VMess-WS-TLS / Hysteria2）时才校验证书文件
    if jq -e 'any(.inbounds[]?; (.tag == "vmess-ws-tls-in") or (.tag == "hysteria2-in"))' "$CONFIG_FILE" >/dev/null 2>&1; then
        check_certificate_files || return 1
    fi
    echo -e "${YELLOW}正在检查 sing-box 配置...${PLAIN}"
    ${INSTALL_DIR}/sing-box check -c "$CONFIG_FILE"
}

edit_config() {
    local editor="nano"
    command -v nano >/dev/null 2>&1 || editor="vi"
    $editor "$CONFIG_FILE"
    echo -e "${YELLOW}正在检查配置文件语法...${PLAIN}"
    if ${INSTALL_DIR}/sing-box check -c "$CONFIG_FILE"; then
        read -rp "配置正确，是否重启 sing-box 使其生效？[y/N]: " reload_choice </dev/tty
        [[ "$reload_choice" =~ ^[Yy]$ ]] && restart_service
    else
        echo -e "${RED}配置文件存在语法错误，请手动修正！${PLAIN}"
    fi
}

update_core() {
    detect_arch
    echo -e "${YELLOW}正在检测最新版本...${PLAIN}"
    local tag
    tag=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        echo -e "${RED}获取最新版本失败，请检查网络或 GitHub API 频率限制！${PLAIN}"
        return 1
    fi
    local cur_ver
    cur_ver=$(${INSTALL_DIR}/sing-box version 2>/dev/null | awk 'NR==1{print $3}')
    
    if [[ "$cur_ver" == "${tag#v}" ]]; then
        echo -e "${GREEN}当前已是最新版本 (${cur_ver})，无需更新。${PLAIN}"
        return
    fi

    echo -e "${YELLOW}当前版本: ${cur_ver}，发现新版本: ${tag}，准备更新...${PLAIN}"
    local version="${tag#v}"
    local filename="sing-box-${version}-${ARCH}.tar.gz"
    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${filename}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! curl -L -f -o "${tmp_dir}/${filename}" "$url"; then
        echo -e "${RED}下载新版本失败，已保留当前版本 ${cur_ver}。${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! tar -xzf "${tmp_dir}/${filename}" -C "$tmp_dir" \
        || [[ ! -f "${tmp_dir}/sing-box-${version}-${ARCH}/sing-box" ]]; then
        echo -e "${RED}安装包无效，已保留当前版本 ${cur_ver}。${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! "${tmp_dir}/sing-box-${version}-${ARCH}/sing-box" version >/dev/null 2>&1; then
        echo -e "${RED}新版本二进制无法运行，已保留当前版本 ${cur_ver}。${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi

    service_stop
    mv "${tmp_dir}/sing-box-${version}-${ARCH}/sing-box" "${INSTALL_DIR}/sing-box"
    chmod +x "${INSTALL_DIR}/sing-box"
    rm -rf "$tmp_dir"
    if ! service_start; then
        show_start_failure
        return 1
    fi
    echo -e "${GREEN}更新成功，当前版本: $(${INSTALL_DIR}/sing-box version | awk 'NR==1{print $3}')${PLAIN}"
}

manage_bbr() {
    echo -e "=== ${GREEN}BBR 与网络参数状态${PLAIN} ==="
    echo -e "TCP 拥塞控制算法: ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${PLAIN}"
    echo -e "默认队列规则 (qdisc): ${GREEN}$(sysctl -n net.core.default_qdisc 2>/dev/null)${PLAIN}"
    echo -e "当前文件描述符限制: ${GREEN}$(ulimit -n)${PLAIN}"
    
    read -rp "是否重新应用/刷新 BBR 与高并发网络优化？[y/N]: " opt_choice </dev/tty
    if [[ "$opt_choice" =~ ^[Yy]$ ]]; then
        apply_bbr_and_optimization
    fi
}

uninstall_all() {
    read -rp "确定要完全卸载 sing-box 吗？[y/N]: " confirm </dev/tty
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0

    service_remove
    argo_service_remove

    rm -f "${INSTALL_DIR}/sing-box"
    rm -f "$CLI_TARGET"
    rm -f "$ARGO_BIN" "$ARGO_LOG"
    rm -rf "$ARGO_DIR"

    read -rp "是否删除配置文件与证书目录 (${CONFIG_DIR})？[y/N]: " del_cfg </dev/tty
    [[ "$del_cfg" =~ ^[Yy]$ ]] && rm -rf "$CONFIG_DIR"

    read -rp "是否还原/删除 BBR 与网络优化配置文件？[y/N]: " del_bbr </dev/tty
    if [[ "$del_bbr" =~ ^[Yy]$ ]]; then
        rm -f "$SYSCTL_BBR_FILE" "$LIMITS_FILE" "$LOCAL_D_FILE"
        reload_sysctl
        echo -e "${YELLOW}BBR 与网络配置文件已移除。${PLAIN}"
    fi

    echo -e "${GREEN}sing-box 已完全卸载。${PLAIN}"
    exit 0
}

# 部署全局 sb 命令
install_cli() {
    if [[ -f "$0" && -r "$0" ]]; then
        cp "$0" "$CLI_TARGET"
    else
        curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_singbox.sh -o "$CLI_TARGET" || {
            echo -e "${RED}无法安装 sb 快捷命令，请稍后重试。${PLAIN}"
            return 1
        }
    fi
    chmod 0755 "$CLI_TARGET"
    echo -e "${GREEN}快捷命令 'sb' 部署完成。${PLAIN}"
}

# 交互主菜单
show_menu() {
    echo -e "
${GREEN}sing-box 服务管理工具 (sb)${PLAIN}
------------------------
 1. 启动服务 (start)
 2. 停止服务 (stop)
 3. 重启服务 (restart)
 4. 查看状态 (status)
 5. 查看实时日志 (log)
 6. 查看入站节点配置 (info)
 7. 检查配置文件 (check)
 8. 编辑配置文件 (edit)
 9. 重新生成入站配置 (gen)
10. 更新 sing-box 内核 (update)
11. BBR 状态与网络调优 (bbr)
12. Argo 隧道管理 (argo)
13. 卸载 sing-box (uninstall)
 0. 退出
------------------------"
    read -rp "请输入选项 [0-13]: " choice </dev/tty
    case "$choice" in
        1) start_service ;;
        2) stop_service ;;
        3) restart_service ;;
        4) check_status ;;
        5) view_logs ;;
        6) view_inbound_info ;;
        7) test_config ;;
        8) edit_config ;;
        9) generate_production_config && apply_argo_configuration ;;
        10) update_core ;;
        11) manage_bbr ;;
        12) argo_menu ;;
        13) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac
}

# 主入口分发逻辑
main() {
    case "$1" in
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) check_status ;;
        log) view_logs ;;
        info) view_inbound_info ;;
        check|test) test_config ;;
        edit) edit_config ;;
        gen) generate_production_config && apply_argo_configuration ;;
        argo) shift; argo_command "$@" ;;
        update) update_core ;;
        bbr) manage_bbr ;;
        uninstall) uninstall_all ;;
        menu) show_menu ;;
        "")
            if [[ "$0" == *"/sb" || "$0" == "sb" ]]; then
                show_menu
            else
                install_deps
                apply_bbr_and_optimization
                download_singbox
                generate_production_config || exit 1

                # 仅检查用户实际选择的入站端口（Shadowsocks 同时使用 TCP/UDP，Hysteria2 使用 UDP）
                if [[ $ENABLE_SS -eq 1 ]]; then
                    check_port_available "$SS_PORT" tcp || exit 1
                    check_port_available "$SS_PORT" udp || exit 1
                fi
                if [[ $ENABLE_REALITY -eq 1 ]]; then
                    check_port_available "$REALITY_PORT" tcp || exit 1
                fi
                if [[ $ENABLE_VMESS -eq 1 ]]; then
                    check_port_available "$VMESS_WS_PORT" tcp || exit 1
                fi
                if [[ $ENABLE_HY2 -eq 1 ]]; then
                    check_port_available "$HY2_PORT" udp || exit 1
                fi
                if [[ $ENABLE_ARGO -eq 1 ]]; then
                    check_port_available "$ARGO_WS_PORT" tcp || exit 1
                fi

                apply_argo_configuration || exit 1
                setup_service
                install_cli

                if ! start_service; then
                    echo -e "${RED}安装完成，但 sing-box 未能启动；请按上方日志修复后执行 sb start。${PLAIN}"
                    exit 1
                fi

                echo -e "\n${GREEN}=================================================${PLAIN}"
                echo -e " 安装完成！"
                echo -e " 配置文件: ${CONFIG_FILE}"
                echo -e " 证书目录: ${CERT_DIR}/"
                echo -e " 查看节点信息: ${YELLOW}sb info${PLAIN}"
                echo -e " Argo 管理:    ${YELLOW}sb argo${PLAIN}"
                echo -e " 全局管理工具: ${YELLOW}sb${PLAIN}"
                if [[ $ENABLE_VMESS -eq 1 || $ENABLE_HY2 -eq 1 ]] && is_self_signed_cert; then
                    echo -e " 当前使用自签证书，请替换为正式证书后再对外提供服务。"
                fi
                echo -e "${GREEN}=================================================${PLAIN}"
            fi
            ;;
        *)
            echo -e "${RED}未知子命令: $1${PLAIN}"
            show_menu
            ;;
    esac
}

main "$@"
