#!/usr/bin/env bash
# =========================================================
# Xray (v26.6.27) 一键安装、服务管理、BBR 调优与配置生成脚本
# 入站: 可选 Shadowsocks(默认32443) / VLESS-Reality(默认443) / VMess-WS-TLS(默认2053) / Argo 隧道
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

XRAY_VERSION="v26.6.27"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/xray"
CERT_DIR="${CONFIG_DIR}/cert"
CONFIG_FILE="${CONFIG_DIR}/config.json"
LINKS_FILE="${CONFIG_DIR}/links.txt"
# 住宅 IP 出站规则集（sing-box source 格式，Xray / sing-box 共用同一份源文件）
RESIDENTIAL_RULE_URL="https://raw.githubusercontent.com/yuehen7/scripts/main/rules/residential.json"
RESIDENTIAL_RULE_CACHE="${CONFIG_DIR}/residential-rules.json"
SYSTEMD_FILE="/etc/systemd/system/xray.service"
INITD_FILE="/etc/init.d/xray"
SERVICE_NAME="xray"
SERVICE_LOG="/var/log/xray.log"
CLI_TARGET="/usr/local/bin/xr"
SYSCTL_BBR_FILE="/etc/sysctl.d/99-network-bbr.conf"
LIMITS_FILE="/etc/security/limits.d/99-nofile.conf"
LOCAL_D_FILE="/etc/local.d/99-network-bbr.start"

# 入站协议候选参数
SS_PORT=32443
SS_METHOD="2022-blake3-aes-128-gcm"
REALITY_PORT=443
VMESS_WS_PORT=2053
VMESS_WS_PATH="/175443"
# 默认端口（用户可在生成配置时自定义）
DEFAULT_SS_PORT="$SS_PORT"
DEFAULT_REALITY_PORT="$REALITY_PORT"
DEFAULT_VMESS_WS_PORT="$VMESS_WS_PORT"
# VLESS-Reality 与 VMess-WS-TLS 共用固定 UUID
FIXED_UUID="8326d9fd-3246-4ca0-aa48-894f0e7d96d6"

# Argo 隧道（外部 cloudflared + 本地明文 VMess-WS 入站）
ARGO_WS_PORT=2083
DEFAULT_ARGO_WS_PORT="$ARGO_WS_PORT"
ARGO_WS_PATH="/argo-${FIXED_UUID:0:8}"
ARGO_DIR="${CONFIG_DIR}/argo"
ARGO_MODE_FILE="${ARGO_DIR}/mode"
ARGO_DOMAIN_FILE="${ARGO_DIR}/domain"
ARGO_TOKEN_FILE="${ARGO_DIR}/token"
ARGO_EDGE_IP_FILE="${ARGO_DIR}/edge_ip"
# local 模式（cloudflared CLI 托管隧道）
ARGO_TUNNEL_NAME_FILE="${ARGO_DIR}/tunnel_name"
ARGO_TUNNEL_UUID_FILE="${ARGO_DIR}/tunnel_uuid"
ARGO_CRED_FILE_STATE="${ARGO_DIR}/credentials_file"
ARGO_ORIGIN_CERT_STATE="${ARGO_DIR}/origin_cert"
ARGO_CONFIG_YML="${ARGO_DIR}/config.yml"
ARGO_BIN="/usr/local/bin/cloudflared-argo"
ARGO_SERVICE_NAME="cloudflared-argo"
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
# Argo 隧道管理（外部 cloudflared + 本地明文 VMess-WS）
# =========================================================

argo_is_configured() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    jq -e 'any(.inbounds[]?; .tag == "vmess-ws-argo-in")' "$CONFIG_FILE" >/dev/null 2>&1
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
    jq -r '.inbounds[] | select(.tag=="vmess-ws-argo-in") | .port' "$CONFIG_FILE" 2>/dev/null
}

argo_ws_path() {
    jq -r '.inbounds[] | select(.tag=="vmess-ws-argo-in") | .streamSettings.wsSettings.path' "$CONFIG_FILE" 2>/dev/null
}

argo_uuid() {
    jq -r '.inbounds[] | select(.tag=="vmess-ws-argo-in") | .settings.clients[0].id' "$CONFIG_FILE" 2>/dev/null
}

argo_tunnel_name() {
    [[ -s "$ARGO_TUNNEL_NAME_FILE" ]] && tr -d '[:space:]' < "$ARGO_TUNNEL_NAME_FILE"
}

argo_tunnel_uuid() {
    [[ -s "$ARGO_TUNNEL_UUID_FILE" ]] && tr -d '[:space:]' < "$ARGO_TUNNEL_UUID_FILE"
}

argo_credentials_file() {
    [[ -s "$ARGO_CRED_FILE_STATE" ]] && tr -d '[:space:]' < "$ARGO_CRED_FILE_STATE"
}

argo_origin_cert() {
    [[ -s "$ARGO_ORIGIN_CERT_STATE" ]] && tr -d '[:space:]' < "$ARGO_ORIGIN_CERT_STATE"
}

save_argo_state() {
    local mode="$1" domain="$2" token="$3" edge_ip="$4"
    local tunnel_name="${5:-}" tunnel_uuid="${6:-}" cred_file="${7:-}" origin_cert="${8:-}"
    mkdir -p "$ARGO_DIR" || return 1
    chmod 700 "$ARGO_DIR" 2>/dev/null || true
    # 重新生成配置时清空旧日志；保留空文件，避免回退到 journald 读到旧域名
    : > "$ARGO_LOG" 2>/dev/null || true
    printf '%s\n' "$mode" > "$ARGO_MODE_FILE" || return 1
    printf '%s\n' "$edge_ip" > "$ARGO_EDGE_IP_FILE" || return 1

    case "$mode" in
        named)
            printf '%s\n' "$domain" > "$ARGO_DOMAIN_FILE" || return 1
            (umask 077; printf '%s' "$token" > "$ARGO_TOKEN_FILE") || return 1
            chmod 600 "$ARGO_TOKEN_FILE" 2>/dev/null || true
            rm -f "$ARGO_TUNNEL_NAME_FILE" "$ARGO_TUNNEL_UUID_FILE" \
                "$ARGO_CRED_FILE_STATE" "$ARGO_ORIGIN_CERT_STATE" "$ARGO_CONFIG_YML"
            ;;
        local)
            printf '%s\n' "$domain" > "$ARGO_DOMAIN_FILE" || return 1
            printf '%s\n' "$tunnel_name" > "$ARGO_TUNNEL_NAME_FILE" || return 1
            printf '%s\n' "$tunnel_uuid" > "$ARGO_TUNNEL_UUID_FILE" || return 1
            printf '%s\n' "$cred_file" > "$ARGO_CRED_FILE_STATE" || return 1
            printf '%s\n' "$origin_cert" > "$ARGO_ORIGIN_CERT_STATE" || return 1
            rm -f "$ARGO_TOKEN_FILE"
            ;;
        *)
            : > "$ARGO_DOMAIN_FILE" || return 1
            rm -f "$ARGO_TOKEN_FILE" "$ARGO_TUNNEL_NAME_FILE" "$ARGO_TUNNEL_UUID_FILE" \
                "$ARGO_CRED_FILE_STATE" "$ARGO_ORIGIN_CERT_STATE" "$ARGO_CONFIG_YML"
            ;;
    esac
}

clear_argo_state() {
    rm -rf "$ARGO_DIR"
}

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

argo_service_restart() {
    case "$INIT_SYSTEM" in
        systemd) systemctl restart "$ARGO_SERVICE_NAME" ;;
        openrc) rc-service "$ARGO_SERVICE_NAME" restart ;;
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

# =========================================================
# local 模式：cloudflared CLI 托管隧道 + 自动绑定 DNS
# =========================================================

argo_default_cert_path() {
    printf '%s\n' "${TUNNEL_ORIGIN_CERT:-$HOME/.cloudflared/cert.pem}"
}

# 确保账号已授权；成功后 BIND_ORIGIN_CERT 指向 cert.pem
ensure_argo_login() {
    local cert
    cert=$(argo_default_cert_path)
    if [[ -s "$cert" ]]; then
        chmod 600 "$cert" 2>/dev/null || true
        BIND_ORIGIN_CERT="$cert"
        return 0
    fi

    mkdir -p "$(dirname "$cert")" || return 1
    chmod 700 "$(dirname "$cert")" 2>/dev/null || true
    echo -e "${YELLOW}需要一次浏览器授权：请复制 cloudflared 输出的链接到本地浏览器打开。${PLAIN}" >&2
    echo -e "${YELLOW}授权完成后脚本会自动继续。${PLAIN}" >&2
    if ! "$ARGO_BIN" tunnel login; then
        echo -e "${RED}cloudflared tunnel login 失败或超时。${PLAIN}" >&2
        return 1
    fi
    if [[ ! -s "$cert" ]]; then
        echo -e "${RED}未找到授权文件 ${cert}。若使用自定义路径，请设置 TUNNEL_ORIGIN_CERT。${PLAIN}" >&2
        return 1
    fi
    chmod 600 "$cert" 2>/dev/null || true
    BIND_ORIGIN_CERT="$cert"
}

default_local_tunnel_name() {
    local domain="$1"
    printf 'xray-%s\n' "$(printf '%s' "$domain" | tr '.' '-' | tr -cd 'A-Za-z0-9-' | cut -c1-48)"
}

# 按名称查找云端隧道 UUID（优先 JSON，失败时解析表格输出）
find_local_tunnel() {
    local name="$1" json id=""
    if json=$("$ARGO_BIN" tunnel list --output json 2>/dev/null) && [[ -n "$json" ]]; then
        id=$(jq -r --arg n "$name" '
            (if type == "array" then . else (.tunnels // []) end)[]
            | select(.name == $n) | .id' <<<"$json" 2>/dev/null | head -n 1)
    fi
    if [[ -z "$id" || "$id" == "null" ]]; then
        id=$("$ARGO_BIN" tunnel list 2>/dev/null | awk -v n="$name" '$2 == n { print $1; exit }')
    fi
    if [[ -n "$id" && "$id" != "null" ]]; then
        printf '%s\n' "$id"
    fi
}

# 创建或复用隧道；成功后可读取 BIND_TUNNEL_UUID / BIND_CRED_FILE
ensure_local_tunnel() {
    local name="$1" uuid cred
    uuid=$(find_local_tunnel "$name")

    if [[ -z "$uuid" ]]; then
        echo -e "${YELLOW}创建 Cloudflare Tunnel: ${name}${PLAIN}" >&2
        if ! "$ARGO_BIN" tunnel create "$name" >/dev/null 2>&1; then
            echo -e "${RED}创建隧道失败，请执行 '${ARGO_BIN} tunnel create ${name}' 查看原因。${PLAIN}" >&2
            return 1
        fi
        uuid=$(find_local_tunnel "$name")
    else
        echo -e "${YELLOW}复用已有 Cloudflare Tunnel: ${name} (${uuid})${PLAIN}" >&2
    fi

    if [[ -z "$uuid" ]]; then
        echo -e "${RED}创建后仍无法获取隧道 UUID，请执行 '${ARGO_BIN} tunnel list' 检查。${PLAIN}" >&2
        return 1
    fi

    cred="$HOME/.cloudflared/${uuid}.json"
    if [[ ! -s "$cred" ]]; then
        echo -e "${RED}本机缺少凭证文件 ${cred}。${PLAIN}" >&2
        echo -e "${YELLOW}为避免误删云端隧道，脚本不会自动删除/重建。请在 Cloudflare 面板删除该隧道，或换一个隧道名称。${PLAIN}" >&2
        return 1
    fi

    BIND_TUNNEL_UUID="$uuid"
    BIND_CRED_FILE="$cred"
}

# 写 DNS 记录；已存在时要求显式确认后才覆盖
bind_local_dns() {
    local name="$1" domain="$2" output confirm
    echo -e "${YELLOW}绑定 DNS: ${domain} -> ${name}${PLAIN}" >&2

    if output=$("$ARGO_BIN" tunnel route dns "$name" "$domain" 2>&1); then
        [[ -n "$output" ]] && echo "$output" >&2
        return 0
    fi
    [[ -n "$output" ]] && echo "$output" >&2

    if [[ "$output" == *"already exists"* || "$output" == *"record with that host"* ]]; then
        read -rp "${domain} 已存在 DNS 记录，是否覆盖为 Argo 隧道？[y/N]: " confirm </dev/tty || confirm=""
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            if "$ARGO_BIN" tunnel route dns --overwrite-dns "$name" "$domain"; then
                return 0
            fi
        fi
        echo -e "${RED}未覆盖现有 DNS 记录，已取消绑定。${PLAIN}" >&2
    else
        echo -e "${RED}DNS 绑定失败，请确认域名已托管在当前 Cloudflare 账号下。${PLAIN}" >&2
    fi
    return 1
}

write_local_argo_config() {
    local uuid="$1" cred="$2" domain="$3" port="$4"
    mkdir -p "$ARGO_DIR" || return 1
    chmod 700 "$ARGO_DIR" 2>/dev/null || true
    cat > "$ARGO_CONFIG_YML" <<EOF
tunnel: ${uuid}
credentials-file: ${cred}

ingress:
  - hostname: ${domain}
    service: http://127.0.0.1:${port}
  - service: http_status:404
EOF
    chmod 600 "$ARGO_CONFIG_YML" 2>/dev/null || true
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
    local max_rotations="${1:-2}" rotation=1 waited=0 domain=""
    while [[ $rotation -le $max_rotations ]]; do
        waited=0
        while [[ $waited -lt 20 ]]; do
            if domain=$(refresh_argo_domain_from_log); then
                echo -e "${GREEN}Argo Quick Tunnel 域名: ${domain}${PLAIN}"
                return 0
            fi
            if ! argo_service_is_active; then
                echo -e "${YELLOW}cloudflared 未保持运行，准备重启...${PLAIN}"
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
        if [[ $rotation -lt $max_rotations ]]; then
            echo -e "${YELLOW}Argo 域名获取超时，正在重启 cloudflared 重试 (${rotation}/${max_rotations})...${PLAIN}"
            : > "$ARGO_LOG" 2>/dev/null || true
            argo_service_restart >/dev/null 2>&1 || true
            sleep 2
        fi
        rotation=$((rotation + 1))
    done
    echo -e "${RED}多次重试仍未获取 Argo 域名，请执行 'xr argo log' 查看日志。${PLAIN}"
    return 1
}

# 轮询 named 隧道是否已向 Cloudflare 注册连接
wait_for_named_ready() {
    local waited=0
    while [[ $waited -lt 20 ]]; do
        if argo_recent_logs | grep -qE 'Registered tunnel connection|Connection [0-9a-fA-F-]+ registered'; then
            return 0
        fi
        argo_service_is_active || return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

setup_argo_service() {
    argo_is_configured || return 1

    local mode port edge_ip command_args tunnel_name tunnel_uuid cred_file
    mode=$(argo_mode)
    port=$(argo_ws_port)
    edge_ip=$(argo_edge_ip)

    if [[ -z "$mode" ]]; then
        echo -e "${RED}缺少 Argo 模式配置，请执行 'xr gen' 重新生成。${PLAIN}"
        return 1
    fi
    if [[ -z "$port" || "$port" == "null" ]]; then
        echo -e "${RED}未找到 Argo 本地 WS 端口，请执行 'xr gen' 重新生成。${PLAIN}"
        return 1
    fi

    mkdir -p "$ARGO_DIR"
    touch "$ARGO_LOG" 2>/dev/null || true

    case "$mode" in
        named)
            if [[ ! -s "$ARGO_TOKEN_FILE" ]]; then
                echo -e "${RED}缺少 Argo Tunnel Token，请执行 'xr gen' 重新配置。${PLAIN}"
                return 1
            fi
            command_args="tunnel --no-autoupdate --edge-ip-version ${edge_ip} --protocol http2 --logfile ${ARGO_LOG} run --token-file ${ARGO_TOKEN_FILE}"
            ;;
        local)
            tunnel_name=$(argo_tunnel_name)
            tunnel_uuid=$(argo_tunnel_uuid)
            cred_file=$(argo_credentials_file)
            if [[ -z "$tunnel_name" || -z "$tunnel_uuid" || -z "$cred_file" || ! -s "$cred_file" || ! -f "$ARGO_CONFIG_YML" ]]; then
                echo -e "${RED}缺少 local 模式隧道配置，请执行 'xr argo bind' 重新绑定。${PLAIN}"
                return 1
            fi
            command_args="tunnel --no-autoupdate --edge-ip-version ${edge_ip} --protocol http2 --logfile ${ARGO_LOG} --config ${ARGO_CONFIG_YML} run ${tunnel_name}"
            ;;
        quick)
            command_args="tunnel --no-autoupdate --edge-ip-version ${edge_ip} --protocol http2 --logfile ${ARGO_LOG} --url http://127.0.0.1:${port}"
            ;;
        *)
            echo -e "${RED}未知 Argo 模式: ${mode}，请执行 'xr gen' 重新生成。${PLAIN}"
            return 1
            ;;
    esac

    case "$INIT_SYSTEM" in
        systemd)
            cat << EOF > "$ARGO_SYSTEMD_FILE"
[Unit]
Description=Cloudflare Argo Tunnel for Xray
After=network-online.target xray.service
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
            echo -e "${GREEN}Argo systemd 服务已注册（${mode} 模式）。${PLAIN}"
            ;;
        openrc)
            cat << EOF > "$ARGO_INITD_FILE"
#!/sbin/openrc-run

name="${ARGO_SERVICE_NAME}"
description="Cloudflare Argo Tunnel for Xray"

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
    after firewall xray
}
EOF
            chmod 0755 "$ARGO_INITD_FILE"
            rc-update add "$ARGO_SERVICE_NAME" default >/dev/null 2>&1 || return 1
            echo -e "${GREEN}Argo OpenRC 服务已注册（${mode} 模式）。${PLAIN}"
            ;;
        *)
            echo -e "${RED}未检测到 systemd 或 OpenRC，无法注册 Argo 服务。${PLAIN}"
            return 1
            ;;
    esac
}

apply_argo_configuration() {
    if [[ "${ENABLE_ARGO:-0}" -eq 1 ]]; then
        download_cloudflared || return 1
        setup_argo_service || return 1
    else
        local old_mode old_tunnel
        old_mode=$(argo_mode)
        old_tunnel=$(argo_tunnel_name)
        argo_service_remove
        clear_argo_state
        if [[ "$old_mode" == "local" && -n "$old_tunnel" ]]; then
            echo -e "${YELLOW}注意: 已取消 Argo 入站，但云端隧道 '${old_tunnel}' 与 DNS 记录未删除。${PLAIN}"
        fi
    fi
}

argo_start() {
    argo_is_configured || return 0

    if argo_service_is_active; then
        if [[ "$(argo_mode)" == "quick" && -z "$(argo_domain)" ]]; then
            refresh_argo_domain_from_log >/dev/null 2>&1 || true
        fi
        return 0
    fi

    : > "$ARGO_LOG" 2>/dev/null || true
    argo_service_start || return 1

    if [[ "$(argo_mode)" == "quick" ]]; then
        wait_for_argo_domain
    else
        local mode
        mode=$(argo_mode)
        if wait_for_named_ready; then
            echo -e "${GREEN}Argo ${mode} 隧道已启动: $(argo_domain)${PLAIN}"
        elif argo_service_is_active; then
            echo -e "${YELLOW}暂未在日志中确认 Argo ${mode} 隧道注册成功，请执行 'xr argo log' 检查。${PLAIN}"
        else
            if [[ "$mode" == "local" ]]; then
                echo -e "${RED}Argo local 隧道未能保持运行，请检查 ${ARGO_CONFIG_YML} 与 'xr argo log'。${PLAIN}"
            else
                echo -e "${RED}Argo named 隧道未能保持运行，请检查 Token 和 'xr argo log'。${PLAIN}"
            fi
            return 1
        fi
    fi
}

argo_stop() {
    argo_is_configured || return 0
    argo_service_stop
    if [[ "$(argo_mode)" == "quick" ]]; then
        rm -f "$ARGO_DOMAIN_FILE"
    fi
}

argo_restart() {
    argo_is_configured || return 0
    argo_service_stop
    if [[ "$(argo_mode)" == "quick" ]]; then
        rm -f "$ARGO_DOMAIN_FILE"
    fi
    argo_start
}

argo_status() {
    echo -e "=== ${GREEN}Argo 隧道状态${PLAIN} ==="
    if ! argo_is_configured; then
        echo -e "未配置 Argo 隧道。可在 'xr gen' 中选择第 4 项。"
        return 0
    fi

    local mode domain port path
    mode=$(argo_mode)
    port=$(argo_ws_port)
    path=$(argo_ws_path)
    domain=$(argo_domain)

    echo -e "模式:       ${CYAN}${mode:-未配置}${PLAIN}"
    if [[ "$mode" == "local" ]]; then
        echo -e "隧道名称:   ${CYAN}$(argo_tunnel_name)${PLAIN}"
        echo -e "隧道 UUID:  ${CYAN}$(argo_tunnel_uuid)${PLAIN}"
    fi
    if argo_service_is_active; then
        echo -e "服务状态:   ${GREEN}运行中${PLAIN}"
    else
        echo -e "服务状态:   ${RED}未运行${PLAIN}"
    fi

    if [[ "$mode" == "quick" && -z "$domain" ]] && argo_service_is_active; then
        domain=$(refresh_argo_domain_from_log 2>/dev/null || true)
    fi
    echo -e "公网域名:   ${CYAN}${domain:-尚未生成}${PLAIN}"
    echo -e "本地 WS:    ${CYAN}127.0.0.1:${port}${path}${PLAIN}"
    echo -e "日志文件:   ${CYAN}${ARGO_LOG}${PLAIN}"
    if [[ "$mode" == "quick" ]]; then
        echo -e "${YELLOW}提示: Quick Tunnel 域名在 cloudflared 重启后会变化，请重新执行 'xr info'。${PLAIN}"
    fi
}

view_argo_info() {
    argo_is_configured || return 1

    local mode domain port path uuid location_label="${1:-}" argo_node_name
    [[ -z "$location_label" ]] && location_label=$(detect_location_label "$(argo_edge_ip)")
    argo_node_name=$(node_name_with_location "Xray-VMess-Argo" "$location_label")
    mode=$(argo_mode)
    port=$(argo_ws_port)
    path=$(argo_ws_path)
    uuid=$(argo_uuid)
    domain=$(argo_domain)

    if [[ "$mode" == "quick" && -z "$domain" ]] && argo_service_is_active; then
        domain=$(refresh_argo_domain_from_log 2>/dev/null || true)
    fi
    if [[ -z "$domain" ]]; then
        echo -e "${YELLOW}Argo 域名尚未生成（隧道未运行或正在启动），请稍后执行 'xr argo info'。${PLAIN}"
        return 1
    fi

    local mode_label="${mode:-unknown}"
    case "$mode" in
        local) mode_label="local (cloudflared CLI 托管)" ;;
        named) mode_label="named (Token)" ;;
        quick) mode_label="quick (临时域名)" ;;
    esac

    echo -e "${GREEN}【协议: VMess + WS (Cloudflare Argo)】${PLAIN}"
    echo -e "  模式 (Mode):        ${CYAN}${mode_label}${PLAIN}"
    if [[ "$mode" == "local" ]]; then
        echo -e "  隧道名称 (Tunnel):  ${CYAN}$(argo_tunnel_name)${PLAIN}"
    fi
    echo -e "  公网域名 (Host):    ${CYAN}${domain}${PLAIN}"
    echo -e "  本地监听 (Local):   ${CYAN}127.0.0.1:${port}${path}${PLAIN}"
    echo -e "  用户 ID (UUID):     ${CYAN}${uuid}${PLAIN}"
    if [[ "$mode" == "quick" ]]; then
        echo -e "  ${YELLOW}Quick Tunnel 域名在 cloudflared 重启后会变化。${PLAIN}"
    fi

    local argo_vmess_json argo_link
    argo_vmess_json=$(jq -cn \
        --arg ps "$argo_node_name" \
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
        --arg name "$argo_node_name" \
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
    touch "$ARGO_LOG" 2>/dev/null || true
    tail -f "$ARGO_LOG"
}

argo_update() {
    if ! argo_is_configured; then
        echo -e "${RED}未配置 Argo 隧道。${PLAIN}"
        return 1
    fi
    download_cloudflared 1 || return 1
    setup_argo_service || return 1
    argo_restart
}

# local 模式：创建/复用隧道并绑定固定域名
argo_bind() {
    if ! argo_is_configured; then
        echo -e "${RED}未配置 Argo 隧道，请先执行 'xr gen' 并选择 Argo。${PLAIN}"
        return 1
    fi

    local port mode domain name confirm
    port=$(argo_ws_port)
    if [[ -z "$port" || "$port" == "null" ]]; then
        echo -e "${RED}未找到 Argo 本地 WS 端口，请执行 'xr gen' 重新生成。${PLAIN}"
        return 1
    fi

    mode=$(argo_mode)
    if [[ "$mode" != "local" ]]; then
        echo -e "${YELLOW}当前模式为 ${mode:-未配置}，绑定固定域名后将切换为 local（cloudflared CLI 托管隧道）。${PLAIN}"
        read -rp "确认继续？[y/N]: " confirm </dev/tty || confirm=""
        [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    fi

    download_cloudflared || return 1
    ensure_argo_login || return 1

    domain="${1:-}"
    while true; do
        if [[ -z "$domain" ]]; then
            read -rp "输入要绑定的完整域名 (例如 argo.example.com): " domain </dev/tty || domain=""
        fi
        domain=$(printf '%s' "$domain" | tr -d '[:space:]')
        domain=${domain%.}
        domain=${domain,,}
        if validate_domain "$domain"; then
            break
        fi
        echo -e "${RED}域名格式无效，请重新输入。${PLAIN}"
        domain=""
    done

    name=$(argo_tunnel_name)
    if [[ -z "$name" || "$(argo_domain)" != "$domain" ]]; then
        name=$(default_local_tunnel_name "$domain")
    fi

    ensure_local_tunnel "$name" || return 1
    bind_local_dns "$name" "$domain" || return 1
    write_local_argo_config "$BIND_TUNNEL_UUID" "$BIND_CRED_FILE" "$domain" "$port" || return 1

    save_argo_state "local" "$domain" "" "$(argo_edge_ip)" \
        "$name" "$BIND_TUNNEL_UUID" "$BIND_CRED_FILE" "$BIND_ORIGIN_CERT" || {
        echo -e "${RED}Argo 状态写入失败。${PLAIN}"
        return 1
    }

    setup_argo_service || return 1
    argo_restart || return 1
    refresh_links_quiet
    echo -e "${GREEN}固定域名绑定完成: https://${domain} -> 127.0.0.1:${port}${PLAIN}"
    view_argo_info
}

argo_uninstall() {
    local mode tunnel_name
    mode=$(argo_mode)
    tunnel_name=$(argo_tunnel_name)

    argo_service_remove
    clear_argo_state
    rm -f "$ARGO_BIN"
    echo -e "${GREEN}Argo 隧道服务、配置和 cloudflared 已删除。${PLAIN}"

    if [[ "$mode" == "local" && -n "$tunnel_name" ]]; then
        echo -e "${YELLOW}云端隧道 '${tunnel_name}' 与对应 DNS 记录仍保留。如需彻底删除：${PLAIN}"
        echo -e "  在 Cloudflare 面板删除，或重新安装 cloudflared 后执行:"
        echo -e "  cloudflared tunnel delete ${tunnel_name}"
        echo -e "${YELLOW}账号授权文件与隧道凭证仍保留在 ${HOME}/.cloudflared/，未删除。${PLAIN}"
    fi
    echo -e "${YELLOW}如需同时移除本地 WS 入站，请执行 'xr gen' 并取消选择 Argo。${PLAIN}"
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
 6. 查看实时日志 (log)
 7. 更新 cloudflared (update)
 8. 卸载 Argo (uninstall)
 9. 绑定固定域名 (bind, local 模式)
 0. 退出
------------------------"
    read -rp "请输入选项 [0-9]: " argo_choice </dev/tty
    case "$argo_choice" in
        1) argo_status ;;
        2) view_argo_info ;;
        3) argo_start ;;
        4) argo_stop ;;
        5) argo_restart ;;
        6) argo_logs ;;
        7) argo_update ;;
        8) argo_uninstall ;;
        9) argo_bind ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac
}

argo_command() {
    case "${1:-}" in
        start) argo_start ;;
        stop) argo_stop ;;
        restart) argo_restart ;;
        status) argo_status ;;
        info) view_argo_info ;;
        log) argo_logs ;;
        update) argo_update ;;
        uninstall) argo_uninstall ;;
        bind) shift; argo_bind "$@" ;;
        ""|menu) argo_menu ;;
        *)
            echo -e "${RED}未知 Argo 子命令: $1${PLAIN}"
            argo_menu
            ;;
    esac
}

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请以 root 权限运行此脚本！${PLAIN}" && exit 1

# 安装系统依赖
install_deps() {
    echo -e "${YELLOW}正在检查并安装基础依赖...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y curl wget unzip jq openssl systemd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget unzip jq openssl systemd
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget unzip jq openssl systemd
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl wget unzip jq openssl systemd
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y curl wget unzip jq openssl systemd
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash curl wget unzip jq openssl iproute2 ca-certificates openrc
    else
        echo -e "${YELLOW}未识别的包管理器，请确保已安装 bash, curl, wget, unzip, jq, openssl${PLAIN}"
    fi

    # 依赖安装完成后重新检测服务管理器（例如最小化 Alpine 环境）
    detect_init_system
}

# 检测系统架构匹配 Xray Release 文件名
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) ARCH="64" ;;
        aarch64|arm64) ARCH="arm64-v8a" ;;
        armv7l|armv7) ARCH="arm32-v7a" ;;
        s390x) ARCH="s390x" ;;
        riscv64) ARCH="riscv64" ;;
        *)
            echo -e "${RED}不支持的 CPU 架构: ${arch}${PLAIN}"
            exit 1
            ;;
    esac
}

# BBR 与高并发网络优化
apply_bbr_and_optimization() {
    echo -e "${YELLOW}正在配置 BBR 拥塞控制及 Linux 网络栈优化...${PLAIN}"
    modprobe tcp_bbr >/dev/null 2>&1 || true

    cat << 'EOF' > "$SYSCTL_BBR_FILE"
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
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
    echo -e "${GREEN}网络栈调优完成，当前算法: ${cc}${PLAIN}"
}

# 下载固定版本 v26.6.27 的 Xray
download_xray() {
    detect_arch
    local filename="Xray-linux-${ARCH}.zip"
    local url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${filename}"

    echo -e "${GREEN}下载固定版本: ${XRAY_VERSION} (架构: ${ARCH})${PLAIN}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! curl -L -f -o "${tmp_dir}/${filename}" "$url"; then
        echo -e "${RED}下载 Xray 失败，请检查网络！${PLAIN}"
        rm -rf "$tmp_dir"
        exit 1
    fi

    if ! unzip -q -o "${tmp_dir}/${filename}" -d "$tmp_dir" || [[ ! -f "${tmp_dir}/xray" ]]; then
        echo -e "${RED}Xray 安装包无效或不包含 xray 可执行文件。${PLAIN}"
        rm -rf "$tmp_dir"
        exit 1
    fi
    mkdir -p "$CONFIG_DIR"
    mv "${tmp_dir}/xray" "${INSTALL_DIR}/xray"
    chmod +x "${INSTALL_DIR}/xray"

    [[ -f "${tmp_dir}/geoip.dat" ]] && mv "${tmp_dir}/geoip.dat" "${CONFIG_DIR}/"
    [[ -f "${tmp_dir}/geosite.dat" ]] && mv "${tmp_dir}/geosite.dat" "${CONFIG_DIR}/"

    rm -rf "$tmp_dir"
    echo -e "${GREEN}Xray 二进制已就绪: ${INSTALL_DIR}/xray${PLAIN}"
}

# 证书占位处理
ensure_dummy_cert() {
    mkdir -p "$CERT_DIR"
    if [[ -f "${CERT_DIR}/fullchain.pem" || -f "${CERT_DIR}/privkey.pem" ]]; then
        if [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/privkey.pem" ]]; then
            echo -e "${RED}证书目录中只存在证书或私钥其中之一，请补齐后再继续：${CERT_DIR}${PLAIN}"
            return 1
        fi
        return 0
    fi

    if [[ ! -f "${CERT_DIR}/fullchain.pem" && ! -f "${CERT_DIR}/privkey.pem" ]]; then
        echo -e "${YELLOW}生成初始临时自签名证书...${PLAIN}"
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "${CERT_DIR}/privkey.pem" \
            -out "${CERT_DIR}/fullchain.pem" \
            -subj "/CN=temporary.cert" >/dev/null 2>&1 || {
                echo -e "${RED}无法生成临时证书，请确认 openssl 可用。${PLAIN}"
                return 1
            }
    fi
}

validate_domain() {
    local domain="$1"
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

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

check_port_available() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 0

    local listeners
    listeners=$(ss -H -ltn 2>/dev/null | awk -v port="$port" '$4 ~ (":" port "$") { print }')
    if [[ -n "$listeners" ]]; then
        echo -e "${RED}端口 ${port} 已被其他进程监听，Xray 无法启动：${PLAIN}"
        echo "$listeners"
        return 1
    fi
}

# 使用本机到候选站点的 TLS 建连耗时选择 REALITY 伪装目标。
select_reality_target() {
    local -a candidates=(
        "www.icloud.com"
        "xp.apple.com" "vs.aws.amazon.com" "www.xbox.com"
        "www.oracle.com" "images.nvidia.com" "www.amazon.com" "aws.amazon.com"
        "www.amd.com" "www.sony.com" "www.tesla.com" "www.intel.com"
        "www.nvidia.com" "www.apple.com"
    )
    local domain elapsed best_domain="" best_elapsed="" milliseconds

    echo -e "${YELLOW}正在检测 REALITY 伪装目标的 TLS 1.3 建连延迟...${PLAIN}" >&2
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
        echo -e "${RED}所有 REALITY 候选目标均无法完成 TLS 1.3 握手。${PLAIN}" >&2
        return 1
    fi

    milliseconds=$(awk -v value="$best_elapsed" 'BEGIN { printf "%.0f", value * 1000 }')
    echo -e "${GREEN}已选择 REALITY 目标: ${best_domain}:443 (${milliseconds} ms)${PLAIN}" >&2
    if [[ "$best_domain" == *apple.com || "$best_domain" == "www.icloud.com" ]]; then
        echo -e "${YELLOW}提示: Xray 会警告 Apple/iCloud 目标可能带来 IP 封锁风险。${PLAIN}" >&2
    fi
    printf '%s\n' "$best_domain"
}

# 随机高位端口，避免与其他部署或常用端口撞车
random_free_port() {
    local port attempt
    for attempt in $(seq 1 50); do
        port=$(( (RANDOM % 30000) + 20000 ))
        if ! ss -H -ltn 2>/dev/null | awk -v p="$port" '$4 ~ (":" p "$") { found=1 } END { exit !found }'; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    printf '%s\n' "$(( (RANDOM % 20000) + 40000 ))"
}

# 随机 WS 路径，避免所有部署共用同一路径指纹
random_ws_path() {
    local suffix
    suffix=$(openssl rand -hex 6 2>/dev/null || head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf '/%s\n' "$suffix"
}

# 将 Cloudflare 元数据格式化为节点备注标签 (例如 US-LosAngeles-AS13335)
location_label_from_meta() {
    jq -r '
        [ (.country // ""), (.city // ""),
          (if (.asn // "") != "" then ("AS" + (.asn | tostring)) else "" end) ]
        | map(select(length > 0)) | join("-")' 2>/dev/null |
        tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//'
}

detect_location_label() {
    local family="${1:-4}" ip_flag="--ipv4" meta=""
    [[ "$family" == "6" ]] && ip_flag="--ipv6"
    meta=$(curl -s "$ip_flag" --max-time 4 https://speed.cloudflare.com/meta 2>/dev/null || true)
    [[ -z "$meta" ]] && return 0
    location_label_from_meta <<<"$meta"
}

node_name_with_location() {
    local base="$1" label="$2"
    if [[ -n "$label" ]]; then
        printf '%s-%s\n' "$base" "$label"
    else
        printf '%s\n' "$base"
    fi
}

# 查看节点配置与分享链接（同时写入 links.txt）
view_inbound_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}未找到配置文件: ${CONFIG_FILE}${PLAIN}"
        return 1
    fi

    local output status plain
    output=$(render_inbound_info)
    status=$?
    printf '%s\n' "$output"

    plain=$(printf '%s\n' "$output" | sed -E $'s/\x1b\\[[0-9;]*[mK]//g')
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    if (umask 077; {
        printf '# 节点信息（由 xr info 生成，%s）\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# 刷新并查看: xr info    仅查看已保存内容: xr links\n'
        if argo_is_configured && [[ "$(argo_mode)" == "quick" ]]; then
            printf '# 注意: Quick Tunnel 域名会随 cloudflared 重启变化，请重新执行 xr info。\n'
        fi
        printf '\n%s\n' "$plain"
    } > "$LINKS_FILE"); then
        chmod 600 "$LINKS_FILE" 2>/dev/null || true
        echo -e "${YELLOW}节点信息已保存: ${LINKS_FILE}（权限 600）${PLAIN}"
    else
        echo -e "${YELLOW}警告: 无法写入 ${LINKS_FILE}${PLAIN}"
    fi
    return "$status"
}

# 渲染节点配置与分享链接（内部使用）
render_inbound_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}未找到配置文件: ${CONFIG_FILE}${PLAIN}"
        return 1
    fi

    local server_ip location_label meta
    meta=$(curl -s --ipv4 --max-time 4 https://speed.cloudflare.com/meta 2>/dev/null || true)
    [[ -z "$meta" ]] && meta=$(curl -s --ipv6 --max-time 4 https://speed.cloudflare.com/meta 2>/dev/null || true)
    server_ip=$(jq -r '.clientIp // empty' <<<"$meta" 2>/dev/null || true)
    location_label=$(location_label_from_meta <<<"$meta")
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -s4m 6 https://api.ipify.org || curl -s4m 6 https://ip.sb || echo "YOUR_SERVER_IP")
    fi

    local ss_tag r_tag ws_tag argo_tag
    ss_tag=$(jq -r '.inbounds[] | select(.tag=="shadowsocks-in") | .tag' "$CONFIG_FILE" 2>/dev/null)
    r_tag=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .tag' "$CONFIG_FILE" 2>/dev/null)
    ws_tag=$(jq -r '.inbounds[] | select(.tag=="vmess-ws-tls-in") | .tag' "$CONFIG_FILE" 2>/dev/null)
    argo_tag=$(jq -r '.inbounds[] | select(.tag=="vmess-ws-argo-in") | .tag' "$CONFIG_FILE" 2>/dev/null)

    if jq -e 'any(.inbounds[]?; .tag == "vmess-grpc-tls-in" or .tag == "vmess-xhttp-tls-in")' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}提示: 检测到旧版 gRPC/XHTTP 入站，当前版本已改为 Shadowsocks + VMess-WS-TLS。${PLAIN}"
        echo -e "${YELLOW}      执行 'xr gen' 可重新选择并生成入站配置。${PLAIN}"
    fi

    if [[ -z "$ss_tag" && -z "$r_tag" && -z "$ws_tag" && -z "$argo_tag" ]]; then
        echo -e "${RED}未找到可识别的入站配置，请执行 'xr gen' 重新生成。${PLAIN}"
        return 1
    fi

    echo -e "\n${CYAN}================================================================${PLAIN}"
    echo -e "${CYAN}                     当前 Xray 入站节点配置详情                 ${PLAIN}"
    echo -e "${CYAN}================================================================${PLAIN}"
    if [[ -n "$location_label" ]]; then
        echo -e "${CYAN}出口识别: ${location_label}${PLAIN}"
    fi

    if [[ -n "$ss_tag" ]]; then
        local ss_port ss_method ss_password ss_node_name
        ss_port=$(jq -r --arg t "$ss_tag" '.inbounds[] | select(.tag==$t) | .port' "$CONFIG_FILE")
        ss_method=$(jq -r --arg t "$ss_tag" '.inbounds[] | select(.tag==$t) | .settings.method' "$CONFIG_FILE")
        ss_password=$(jq -r --arg t "$ss_tag" '.inbounds[] | select(.tag==$t) | .settings.password' "$CONFIG_FILE")
        ss_node_name=$(node_name_with_location "Xray-Shadowsocks" "$location_label")

        echo -e "${GREEN}【协议: Shadowsocks (SS2022)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${server_ip}${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${ss_port}${PLAIN}"
        echo -e "  加密方式 (Method):  ${CYAN}${ss_method}${PLAIN}"
        echo -e "  密码 (Password):    ${CYAN}${ss_password}${PLAIN}"

        # SIP002: ss://base64url(method:password)@host:port#tag
        local ss_userinfo ss_link
        ss_userinfo=$(printf '%s' "${ss_method}:${ss_password}" | base64 | tr '+/' '-_' | tr -d '=\n')
        ss_link="ss://${ss_userinfo}@${server_ip}:${ss_port}#${ss_node_name}"
        echo -e "  分享链接 (Link):"
        echo -e "  ${YELLOW}${ss_link}${PLAIN}"
        echo -e "  Mihomo 节点 JSON (添加到 proxies 数组):"
        jq -n \
            --arg name "$ss_node_name" \
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
        local r_port r_uuid r_flow r_sni r_sid r_pri r_pub r_node_name
        r_port=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .port' "$CONFIG_FILE")
        r_uuid=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .settings.clients[0].id' "$CONFIG_FILE")
        r_flow=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .settings.clients[0].flow' "$CONFIG_FILE")
        r_sni=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
        r_pri=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .streamSettings.realitySettings.privateKey' "$CONFIG_FILE")
        r_sid=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")
        r_node_name=$(node_name_with_location "Xray-Reality" "$location_label")

        # 优先从文件读取，若文件缺失则直接由私钥逆向推导公钥
        if [[ -s "${CONFIG_DIR}/reality_pub.key" ]]; then
            r_pub=$(cat "${CONFIG_DIR}/reality_pub.key" | tr -d '[:space:]')
        fi
        if [[ -z "$r_pub" && -n "$r_pri" ]]; then
            r_pub=$(${INSTALL_DIR}/xray x25519 -i "$r_pri" 2>/dev/null | grep -iE 'Public[[:space:]]*key' | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')
            [[ -n "$r_pub" ]] && echo "$r_pub" > "${CONFIG_DIR}/reality_pub.key"
        fi

        echo -e "${GREEN}【协议: VLESS + Reality (直连推荐)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${server_ip}${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${r_port}${PLAIN}"
        echo -e "  用户 ID (UUID):     ${CYAN}${r_uuid}${PLAIN}"
        echo -e "  流控 (Flow):        ${CYAN}${r_flow}${PLAIN}"
        echo -e "  传输协议 (Network): tcp"
        echo -e "  伪装域名 (SNI):     ${CYAN}${r_sni}${PLAIN}"
        echo -e "  公钥 (PublicKey):   ${CYAN}${r_pub:-未找到}${PLAIN}"
        echo -e "  Short ID:           ${CYAN}${r_sid}${PLAIN}"

        if [[ -n "$r_pub" ]]; then
            local r_link="vless://${r_uuid}@${server_ip}:${r_port}?encryption=none&flow=${r_flow}&security=reality&sni=${r_sni}&fp=chrome&pbk=${r_pub}&sid=${r_sid}&type=tcp&headerType=none#${r_node_name}"
            echo -e "  分享链接 (Link):"
            echo -e "  ${YELLOW}${r_link}${PLAIN}"
            echo -e "  Mihomo 节点 JSON (添加到 proxies 数组):"
            jq -n \
                --arg name "$r_node_name" \
                --arg server "$server_ip" \
                --argjson port "$r_port" \
                --arg uuid "$r_uuid" \
                --arg flow "$r_flow" \
                --arg sni "$r_sni" \
                --arg public_key "$r_pub" \
                --arg short_id "$r_sid" \
                '{
                  name: $name,
                  type: "vless",
                  server: $server,
                  port: $port,
                  udp: true,
                  uuid: $uuid,
                  flow: $flow,
                  "packet-encoding": "xudp",
                  encryption: "",
                  tls: true,
                  servername: $sni,
                  "client-fingerprint": "chrome",
                  network: "tcp",
                  "reality-opts": {
                    "public-key": $public_key,
                    "short-id": $short_id
                  }
                }'
        fi
        echo -e "----------------------------------------------------------------"
    fi

    if [[ -n "$ws_tag" ]]; then
        local ws_port ws_uuid ws_sni ws_path ws_alpn ws_node_name
        ws_port=$(jq -r --arg t "$ws_tag" '.inbounds[] | select(.tag==$t) | .port' "$CONFIG_FILE")
        ws_uuid=$(jq -r --arg t "$ws_tag" '.inbounds[] | select(.tag==$t) | .settings.clients[0].id' "$CONFIG_FILE")
        ws_sni=$(jq -r --arg t "$ws_tag" '.inbounds[] | select(.tag==$t) | .streamSettings.tlsSettings.serverName' "$CONFIG_FILE")
        ws_path=$(jq -r --arg t "$ws_tag" '.inbounds[] | select(.tag==$t) | .streamSettings.wsSettings.path' "$CONFIG_FILE")
        ws_alpn=$(jq -r --arg t "$ws_tag" '.inbounds[] | select(.tag==$t) | (.streamSettings.tlsSettings.alpn[0] // "http/1.1")' "$CONFIG_FILE")
        ws_node_name=$(node_name_with_location "Xray-VMess-WS-TLS" "$location_label")

        echo -e "${GREEN}【协议: VMess + WS + TLS (支持 CDN 回源)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${ws_sni} (或填服务器IP/CDN优选IP)${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${ws_port}${PLAIN}"
        echo -e "  用户 ID (UUID):     ${CYAN}${ws_uuid}${PLAIN}"
        echo -e "  加密方式 (Cipher):  ${CYAN}auto${PLAIN}"
        echo -e "  传输协议 (Network): ws"
        echo -e "  传输安全 (Security):tls"
        echo -e "  伪装域名 (SNI/Host):${CYAN}${ws_sni}${PLAIN}"
        echo -e "  路径 (Path):        ${CYAN}${ws_path}${PLAIN}"

        # vmess:// 分享链接 = base64(标准 vmess 节点 JSON)
        local ws_vmess_json ws_link
        ws_vmess_json=$(jq -cn \
            --arg ps "$ws_node_name" \
            --arg add "$ws_sni" \
            --argjson port "$ws_port" \
            --arg id "$ws_uuid" \
            --arg host "$ws_sni" \
            --arg path "$ws_path" \
            --arg sni "$ws_sni" \
            --arg alpn "$ws_alpn" \
            '{v: "2", ps: $ps, add: $add, port: ($port | tostring), id: $id, aid: "0",
              scy: "auto", net: "ws", type: "none", host: $host, path: $path,
              tls: "tls", sni: $sni, alpn: $alpn, fp: "chrome"}')
        ws_link="vmess://$(printf '%s' "$ws_vmess_json" | base64 | tr -d '\n')"
        echo -e "  分享链接 (Link):"
        echo -e "  ${YELLOW}${ws_link}${PLAIN}"
        echo -e "  Mihomo 节点 JSON (添加到 proxies 数组):"
        jq -n \
            --arg name "$ws_node_name" \
            --arg server "$ws_sni" \
            --argjson port "$ws_port" \
            --arg uuid "$ws_uuid" \
            --arg sni "$ws_sni" \
            --arg alpn "$ws_alpn" \
            --arg path "$ws_path" \
            '{
              name: $name,
              type: "vmess",
              server: $server,
              port: $port,
              udp: true,
              uuid: $uuid,
              alterId: 0,
              cipher: "auto",
              tls: true,
              servername: $sni,
              alpn: [$alpn],
              "client-fingerprint": "chrome",
              "skip-cert-verify": false,
              network: "ws",
              "ws-opts": {
                path: $path,
                headers: {
                  Host: $sni
                }
              }
            }'
        echo -e "----------------------------------------------------------------"
    fi

    if [[ -n "$argo_tag" ]]; then
        view_argo_info "$location_label"
    fi

    # 住宅 IP 出站
    if jq -e 'any(.outbounds[]?; .tag == "residential-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
        local proxy_protocol proxy_addr proxy_port proxy_user proxy_pass proxy_type_display mode_display
        proxy_protocol=$(jq -r '.outbounds[] | select(.tag=="residential-out") | .protocol' "$CONFIG_FILE")
        proxy_addr=$(jq -r '.outbounds[] | select(.tag=="residential-out") | .settings.servers[0].address' "$CONFIG_FILE")
        proxy_port=$(jq -r '.outbounds[] | select(.tag=="residential-out") | .settings.servers[0].port' "$CONFIG_FILE")
        proxy_user=$(jq -r '.outbounds[] | select(.tag=="residential-out") | (.settings.servers[0].users[0].user // "")' "$CONFIG_FILE")
        proxy_pass=$(jq -r '.outbounds[] | select(.tag=="residential-out") | (.settings.servers[0].users[0].pass // "")' "$CONFIG_FILE")
        if [[ "$proxy_protocol" == "http" ]]; then
            proxy_type_display="HTTP"
        else
            proxy_type_display="SOCKS5"
        fi
        mode_display="全局"
        if jq -e 'any(.routing.rules[]?; .outboundTag == "residential-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
            mode_display="规则分流"
        fi

        echo -e "${GREEN}【出站: 住宅 IP 代理（${mode_display}）】${PLAIN}"
        echo -e "  类型:   ${CYAN}${proxy_type_display}${PLAIN}"
        echo -e "  地址:   ${CYAN}${proxy_addr}:${proxy_port}${PLAIN}"
        if [[ -n "$proxy_user" ]]; then
            echo -e "  用户名: ${CYAN}${proxy_user}${PLAIN}"
            echo -e "  密码:   ${CYAN}${proxy_pass:-<空>}${PLAIN}"
        else
            echo -e "  认证:   ${CYAN}无${PLAIN}"
        fi
        if [[ "$mode_display" == "规则分流" ]]; then
            local res_rule_count
            res_rule_count=$(jq '[.routing.rules[]? | select(.outboundTag == "residential-out") | (.domain // []) | length] | add // 0' "$CONFIG_FILE")
            echo -e "  规则:   ${CYAN}${res_rule_count} 条域名/关键字${PLAIN}"
        fi
        echo -e "----------------------------------------------------------------"
    fi

    if [[ -n "$ws_tag" ]]; then
        echo -e "${CYAN}证书目录: ${CERT_DIR}/${PLAIN}"
        echo -e "  公钥路径: ${YELLOW}${CERT_DIR}/fullchain.pem${PLAIN}"
        echo -e "  私钥路径: ${YELLOW}${CERT_DIR}/privkey.pem${PLAIN}"
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
    ENABLE_ARGO=0
    SELECTED_PORTS=()

    local input token
    while true; do
        echo -e "\n${CYAN}请选择要启用的入站协议（可多选，至少选择一个）：${PLAIN}"
        echo -e "  ${GREEN}1)${PLAIN} Shadowsocks      ${YELLOW}默认端口 ${DEFAULT_SS_PORT}，加密 ${SS_METHOD}${PLAIN}"
        echo -e "  ${GREEN}2)${PLAIN} VLESS + Reality  ${YELLOW}默认端口 ${DEFAULT_REALITY_PORT}${PLAIN}"
        echo -e "  ${GREEN}3)${PLAIN} VMess + WS + TLS ${YELLOW}默认端口 ${DEFAULT_VMESS_WS_PORT}${PLAIN}"
        echo -e "  ${GREEN}4)${PLAIN} Argo 隧道        ${YELLOW}本地明文 VMess-WS(默认随机高位端口) + 外部 cloudflared${PLAIN}"
        read -rp "请输入编号（多个用空格或逗号分隔，输入 all 全选）: " input </dev/tty || return 1
        input=$(printf '%s' "$input" | tr ',' ' ')

        local ss=0 reality=0 vmess=0 argo=0 invalid=0
        for token in $input; do
            case "$token" in
                1) ss=1 ;;
                2) reality=1 ;;
                3) vmess=1 ;;
                4) argo=1 ;;
                all|ALL|All) ss=1; reality=1; vmess=1; argo=1 ;;
                *) invalid=1 ;;
            esac
        done

        if [[ $invalid -eq 1 || $((ss + reality + vmess + argo)) -eq 0 ]]; then
            echo -e "${RED}输入无效，请输入 1、2、3、4 的组合（如 1,3），或输入 all。${PLAIN}"
            continue
        fi

        ENABLE_SS=$ss
        ENABLE_REALITY=$reality
        ENABLE_VMESS=$vmess
        ENABLE_ARGO=$argo
        break
    done

    echo -e "${GREEN}已选择入站协议：${PLAIN}"
    [[ $ENABLE_SS -eq 1 ]] && echo -e "  - Shadowsocks"
    [[ $ENABLE_REALITY -eq 1 ]] && echo -e "  - VLESS + Reality"
    [[ $ENABLE_VMESS -eq 1 ]] && echo -e "  - VMess + WS + TLS"
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
    ARGO_WS_PORT=$(random_free_port)
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
    if [[ $ENABLE_ARGO -eq 1 ]]; then
        while port_in_selected "$ARGO_WS_PORT"; do
            ARGO_WS_PORT=$(random_free_port)
        done
        ARGO_WS_PORT=$(prompt_inbound_port "Argo 本地 WS (仅 127.0.0.1)" "$ARGO_WS_PORT")
        SELECTED_PORTS+=("$ARGO_WS_PORT")
    fi

    echo -e "${GREEN}入站端口：${PLAIN}"
    [[ $ENABLE_SS -eq 1 ]] && echo -e "  - Shadowsocks: ${SS_PORT}"
    [[ $ENABLE_REALITY -eq 1 ]] && echo -e "  - VLESS + Reality: ${REALITY_PORT}"
    [[ $ENABLE_VMESS -eq 1 ]] && echo -e "  - VMess + WS + TLS: ${VMESS_WS_PORT}"
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

# 获取住宅 IP 出站规则集：优先远程拉取，失败时回退本地缓存
load_residential_rules() {
    local tmp rc=1
    tmp=$(mktemp) || return 1
    if curl -fsSL --connect-timeout 5 --max-time 15 "$RESIDENTIAL_RULE_URL" -o "$tmp" 2>/dev/null \
        && jq -e '.rules | type == "array" and length > 0' "$tmp" >/dev/null 2>&1; then
        cp "$tmp" "$RESIDENTIAL_RULE_CACHE" 2>/dev/null || true
        RESIDENTIAL_RULES=$(cat "$tmp")
        rc=0
    elif [[ -f "$RESIDENTIAL_RULE_CACHE" ]] \
        && jq -e '.rules | type == "array" and length > 0' "$RESIDENTIAL_RULE_CACHE" >/dev/null 2>&1; then
        RESIDENTIAL_RULES=$(cat "$RESIDENTIAL_RULE_CACHE")
        rc=0
    fi
    rm -f "$tmp"
    return $rc
}

# 配置住宅 IP 出站（可选）
configure_residential_outbound() {
    RESIDENTIAL_ENABLED=0
    RESIDENTIAL_TYPE=""
    RESIDENTIAL_HOST=""
    RESIDENTIAL_PORT=""
    RESIDENTIAL_USER=""
    RESIDENTIAL_PASS=""
    RESIDENTIAL_MODE="global"

    local use_proxy
    read -rp "是否启用住宅 IP 出站（可选择全局或规则分流）？[y/N]: " use_proxy </dev/tty || return 0
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

    local mode_choice
    echo -e "${CYAN}请选择住宅 IP 出站模式：${PLAIN}"
    echo -e "  ${GREEN}1)${PLAIN} 全局：所有流量都从住宅 IP 出站"
    echo -e "  ${GREEN}2)${PLAIN} 规则：仅 Claude / Google / 支付等指定域名从住宅 IP 出站，其余直连"
    while true; do
        read -rp "请输入编号 [1-2，默认 1]: " mode_choice </dev/tty || return 0
        case "$mode_choice" in
            ""|1|global) RESIDENTIAL_MODE="global"; break ;;
            2|rule) RESIDENTIAL_MODE="rule"; break ;;
            *) echo -e "${RED}输入无效，请输入 1 或 2。${PLAIN}" ;;
        esac
    done

    RESIDENTIAL_ENABLED=1
    local type_display="SOCKS5"
    [[ "$RESIDENTIAL_TYPE" == "http" ]] && type_display="HTTP"
    local mode_display="全局"
    [[ "$RESIDENTIAL_MODE" == "rule" ]] && mode_display="规则分流"
    echo -e "${GREEN}已启用住宅 IP 出站：${type_display} ${RESIDENTIAL_HOST}:${RESIDENTIAL_PORT}（${mode_display}）${PLAIN}"
}

# 按用户选择的协议规范化写入标准 Xray 配置
generate_production_config() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CERT_DIR"

    echo -e "\n${CYAN}=================================================${PLAIN}"
    echo -e "${CYAN}        Xray 节点配置生成器 (可选多入站)          ${PLAIN}"
    echo -e "${CYAN}=================================================${PLAIN}"

    select_inbound_protocols || return 1
    configure_inbound_ports
    configure_residential_outbound
    if [[ $RESIDENTIAL_ENABLED -eq 1 && "$RESIDENTIAL_MODE" == "rule" ]] && ! load_residential_rules; then
        echo -e "${RED}无法获取住宅 IP 规则集（远程下载失败且无本地缓存），请检查网络后重试，或改用全局模式。${PLAIN}"
        return 1
    fi

    # 每次生成配置都使用随机 WS 路径，避免固定路径指纹
    if [[ $ENABLE_VMESS -eq 1 ]]; then
        VMESS_WS_PATH=$(random_ws_path)
    fi
    if [[ $ENABLE_ARGO -eq 1 ]]; then
        ARGO_WS_PATH=$(random_ws_path)
    fi

    local ws_domain=""
    if [[ $ENABLE_VMESS -eq 1 ]]; then
        ensure_dummy_cert || return 1
        while [[ -z "$ws_domain" ]]; do
            read -rp "请输入 VMess-WS-TLS 入站绑定的域名: " ws_domain </dev/tty
            ws_domain=$(echo "$ws_domain" | tr -d '[:space:]')
            ws_domain=${ws_domain%.}
            ws_domain=${ws_domain,,}
            if ! validate_domain "$ws_domain"; then
                echo -e "${RED}域名格式无效，请输入完整的域名，例如 node.example.com。${PLAIN}"
                ws_domain=""
            fi
        done
    fi

    local argo_mode="" argo_public_domain="" argo_token="" argo_edge_ip="4"
    local argo_local_tunnel_name="" argo_tunnel_uuid="" argo_cred_file="" argo_origin_cert=""
    if [[ $ENABLE_ARGO -eq 1 ]]; then
        echo -e "\n${CYAN}Argo 隧道配置${PLAIN}"
        echo -e "  ${GREEN}1)${PLAIN} quick  随机域名（临时）"
        echo -e "  ${GREEN}2)${PLAIN} named  固定域名，使用 Tunnel Token（需先在面板创建隧道）"
        echo -e "  ${GREEN}3)${PLAIN} local  固定域名，cloudflared CLI 自动创建隧道并绑定 DNS（需浏览器授权）"
        local argo_mode_choice
        read -rp "请选择 Argo 模式 [1/2/3，默认 1]: " argo_mode_choice </dev/tty || argo_mode_choice=""
        case "$argo_mode_choice" in
            2|named|NAMED) argo_mode="named" ;;
            3|local|LOCAL) argo_mode="local" ;;
            *) argo_mode="quick" ;;
        esac

        local argo_ip_choice
        read -rp "Argo 连接 Cloudflare 边缘使用 IPv4 还是 IPv6？[4/6，默认 4]: " argo_ip_choice </dev/tty || argo_ip_choice=""
        if [[ "$argo_ip_choice" == "6" ]]; then
            argo_edge_ip="6"
        else
            argo_edge_ip="4"
        fi

        if [[ "$argo_mode" == "named" || "$argo_mode" == "local" ]]; then
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
        fi

        if [[ "$argo_mode" == "named" ]]; then
            while true; do
                read -rsp "请输入 Cloudflare Tunnel Token（输入不回显）: " argo_token </dev/tty || argo_token=""
                echo
                argo_token=$(printf '%s' "$argo_token" | tr -d '[:space:]')
                if [[ -n "$argo_token" ]]; then
                    break
                fi
                echo -e "${RED}Token 不能为空。${PLAIN}"
            done

            echo -e "${YELLOW}请确保已在 Cloudflare Zero Trust 中将该域名指向 http://127.0.0.1:${ARGO_WS_PORT}${PLAIN}"
        elif [[ "$argo_mode" == "local" ]]; then
            echo -e "${YELLOW}local 模式将通过 cloudflared CLI 创建隧道并写入 DNS 记录。${PLAIN}"
            download_cloudflared || return 1
            ensure_argo_login || return 1
            argo_origin_cert="$BIND_ORIGIN_CERT"

            argo_local_tunnel_name=$(argo_tunnel_name)
            if [[ -z "$argo_local_tunnel_name" || "$(argo_domain)" != "$argo_public_domain" ]]; then
                argo_local_tunnel_name=$(default_local_tunnel_name "$argo_public_domain")
            fi

            ensure_local_tunnel "$argo_local_tunnel_name" || return 1
            argo_tunnel_uuid="$BIND_TUNNEL_UUID"
            argo_cred_file="$BIND_CRED_FILE"

            bind_local_dns "$argo_local_tunnel_name" "$argo_public_domain" || return 1
            write_local_argo_config "$argo_tunnel_uuid" "$argo_cred_file" \
                "$argo_public_domain" "$ARGO_WS_PORT" || return 1
            echo -e "${GREEN}隧道 ${argo_local_tunnel_name} 已绑定到 ${argo_public_domain}${PLAIN}"
        fi

        echo -e "${GREEN}Argo 模式: ${argo_mode}${PLAIN}"
    fi

    # VLESS 与 VMess 共用固定 UUID
    local uuid="$FIXED_UUID"

    local reality_domain="" private_key="" public_key="" short_id=""
    if [[ $ENABLE_REALITY -eq 1 ]]; then
        echo -e "${YELLOW}生成 Reality 密钥参数中...${PLAIN}"
        reality_domain=$(select_reality_target) || {
            echo -e "${RED}无法选择 REALITY 伪装目标，未写入新配置。请检查服务器的 IPv4 出站网络后重试。${PLAIN}"
            return 1
        }

        local keypair
        keypair=$(${INSTALL_DIR}/xray x25519) || {
            echo -e "${RED}无法生成 REALITY 密钥对。${PLAIN}"
            return 1
        }
        private_key=$(echo "$keypair" | grep -iE 'Private[[:space:]]*key' | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')
        public_key=$(echo "$keypair" | grep -iE 'Public[[:space:]]*key' | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')

        # 双重保障：若提取失败，使用 -i 显式推导
        if [[ -z "$public_key" && -n "$private_key" ]]; then
            public_key=$(${INSTALL_DIR}/xray x25519 -i "$private_key" | grep -iE 'Public[[:space:]]*key' | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')
        fi

        if [[ -z "$private_key" || -z "$public_key" ]]; then
            echo -e "${RED}无法解析 REALITY 密钥对，Xray 版本可能不兼容。${PLAIN}"
            return 1
        fi

        echo "$public_key" > "${CONFIG_DIR}/reality_pub.key"
        short_id=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | xxd -p)
    fi

    local ss_password=""
    if [[ $ENABLE_SS -eq 1 ]]; then
        # 2022-blake3-aes-128-gcm 需要 16 字节密钥（base64 编码）
        ss_password=$(openssl rand -base64 16 | tr -d '\n')
    fi

    local inbounds='[]'

    if [[ $ENABLE_SS -eq 1 ]]; then
        inbounds=$(jq -c \
            --argjson port "$SS_PORT" \
            --arg method "$SS_METHOD" \
            --arg password "$ss_password" \
            '. + [{
              "tag": "shadowsocks-in",
              "port": $port,
              "listen": "0.0.0.0",
              "protocol": "shadowsocks",
              "settings": {
                "method": $method,
                "password": $password,
                "network": "tcp,udp"
              },
              "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
              }
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
              "tag": "vless-reality-in",
              "port": $port,
              "listen": "0.0.0.0",
              "protocol": "vless",
              "settings": {
                "clients": [
                  {
                    "id": $uuid,
                    "flow": "xtls-rprx-vision"
                  }
                ],
                "decryption": "none"
              },
              "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                  "show": false,
                  "dest": ($domain + ":443"),
                  "xver": 0,
                  "serverNames": [$domain],
                  "privateKey": $private_key,
                  "shortIds": [$short_id]
                }
              },
              "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
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
              "tag": "vmess-ws-tls-in",
              "port": $port,
              "listen": "0.0.0.0",
              "protocol": "vmess",
              "settings": {
                "clients": [
                  {
                    "id": $uuid
                  }
                ]
              },
              "streamSettings": {
                "network": "ws",
                "security": "tls",
                "tlsSettings": {
                  "serverName": $domain,
                  "alpn": ["http/1.1"],
                  "certificates": [
                    {
                      "certificateFile": $cert,
                      "keyFile": $key
                    }
                  ]
                },
                "wsSettings": {
                  "path": $path
                }
              },
              "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
              }
            }]' <<<"$inbounds") || return 1
    fi

    if [[ $ENABLE_ARGO -eq 1 ]]; then
        inbounds=$(jq -c \
            --argjson port "$ARGO_WS_PORT" \
            --arg uuid "$uuid" \
            --arg path "$ARGO_WS_PATH" \
            '. + [{
              "tag": "vmess-ws-argo-in",
              "port": $port,
              "listen": "127.0.0.1",
              "protocol": "vmess",
              "settings": {
                "clients": [
                  {
                    "id": $uuid
                  }
                ]
              },
              "streamSettings": {
                "network": "ws",
                "wsSettings": {
                  "path": $path
                }
              },
              "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
              }
            }]' <<<"$inbounds") || return 1
    fi

    # 出站：全局模式下住宅 IP 为默认出站；规则模式下默认直连，由路由规则分流
    local outbounds residential_out
    if [[ $RESIDENTIAL_ENABLED -eq 1 ]]; then
        if [[ -n "$RESIDENTIAL_USER" ]]; then
            residential_out=$(jq -cn \
                --arg protocol "$RESIDENTIAL_TYPE" \
                --arg address "$RESIDENTIAL_HOST" \
                --argjson port "$RESIDENTIAL_PORT" \
                --arg user "$RESIDENTIAL_USER" \
                --arg pass "$RESIDENTIAL_PASS" \
                '{
                  "tag": "residential-out",
                  "protocol": $protocol,
                  "settings": {
                    "servers": [{
                      "address": $address,
                      "port": $port,
                      "users": [{"user": $user, "pass": $pass}]
                    }]
                  }
                }') || return 1
        else
            residential_out=$(jq -cn \
                --arg protocol "$RESIDENTIAL_TYPE" \
                --arg address "$RESIDENTIAL_HOST" \
                --argjson port "$RESIDENTIAL_PORT" \
                '{
                  "tag": "residential-out",
                  "protocol": $protocol,
                  "settings": {
                    "servers": [{
                      "address": $address,
                      "port": $port
                    }]
                  }
                }') || return 1
        fi
        if [[ "$RESIDENTIAL_MODE" == "rule" ]]; then
            outbounds=$(jq -cn --argjson residential "$residential_out" \
                '[{"protocol": "freedom", "tag": "direct"}, $residential, {"protocol": "blackhole", "tag": "blocked"}]') || return 1
        else
            outbounds=$(jq -cn --argjson residential "$residential_out" \
                '[$residential, {"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "blocked"}]') || return 1
        fi
    else
        outbounds='[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]'
    fi

    # 规则集转换为 Xray 内联域名规则：domain: 匹配后缀，keyword: 匹配关键字
    local res_domains='[]'
    if [[ $RESIDENTIAL_ENABLED -eq 1 && "$RESIDENTIAL_MODE" == "rule" ]]; then
        res_domains=$(jq -c '[
          (.rules[].domain_suffix[]? | "domain:" + .),
          (.rules[].domain_keyword[]? | "keyword:" + .)
        ]' <<<"$RESIDENTIAL_RULES") || return 1
        if [[ $(jq 'length' <<<"$res_domains") -eq 0 ]]; then
            echo -e "${RED}住宅 IP 规则集为空，无法启用规则模式。${PLAIN}"
            return 1
        fi
    fi

    if ! jq -n --argjson inbounds "$inbounds" --argjson outbounds "$outbounds" \
        --argjson residential "$RESIDENTIAL_ENABLED" --arg mode "$RESIDENTIAL_MODE" \
        --argjson res_domains "$res_domains" '{
      "log": {
        "loglevel": "warning"
      },
      "dns": {
        "servers": [
          "8.8.8.8",
          "1.1.1.1",
          "2001:4860:4860::8888",
          "2606:4700:4700::1111"
        ]
      },
      "inbounds": $inbounds,
      "outbounds": $outbounds,
      "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": ([
          {
            "type": "field",
            "outboundTag": "blocked",
            "domain": [
              "geosite:category-ads-all"
            ]
          },
          {
            "type": "field",
            "outboundTag": "blocked",
            "ip": [
              "geoip:private"
            ]
          }
        ] + (if $residential == 1 and $mode == "rule" then [
          {
            "type": "field",
            "outboundTag": "residential-out",
            "domain": $res_domains
          }
        ] else [] end)
        + (if $residential == 1 then [
          {
            "type": "field",
            "outboundTag": "direct",
            "port": "53"
          }
        ] else [] end))
      }
    }' > "$CONFIG_FILE"; then
        echo -e "${RED}配置文件写入失败，请检查 jq 是否可用。${PLAIN}"
        return 1
    fi

    if [[ $ENABLE_ARGO -eq 1 ]]; then
        save_argo_state "$argo_mode" "$argo_public_domain" "$argo_token" "$argo_edge_ip" \
            "$argo_local_tunnel_name" "$argo_tunnel_uuid" "$argo_cred_file" "$argo_origin_cert" || {
            echo -e "${RED}Argo 状态写入失败。${PLAIN}"
            return 1
        }
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
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target
Wants=network-online.target
After=network-online.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Environment="XRAY_LOCATION_ASSET=${CONFIG_DIR}"
ExecStartPre=${INSTALL_DIR}/xray run -test -config ${CONFIG_FILE}
ExecStart=${INSTALL_DIR}/xray run -config ${CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

            systemctl daemon-reload || return 1
            systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || {
                echo -e "${RED}无法启用 xray 服务。${PLAIN}"
                return 1
            }
            echo -e "${GREEN}systemd 服务已注册并配置为开机自启。${PLAIN}"
            ;;
        openrc)
            cat << EOF > "$INITD_FILE"
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="Xray Service"

supervisor="supervise-daemon"
command="${INSTALL_DIR}/xray"
command_args="run -config ${CONFIG_FILE}"
pidfile="/run/${SERVICE_NAME}.pid"
respawn_delay=5
respawn_max=0
output_log="${SERVICE_LOG}"
error_log="${SERVICE_LOG}"
export XRAY_LOCATION_ASSET="${CONFIG_DIR}"
rc_ulimit="-n 1000000"

depend() {
    need net
    after firewall
}

start_pre() {
    ${INSTALL_DIR}/xray run -test -config ${CONFIG_FILE}
}
EOF
            chmod 0755 "$INITD_FILE"
            rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || {
                echo -e "${RED}无法将 xray 加入 OpenRC 默认运行级别。${PLAIN}"
                return 1
            }
            echo -e "${GREEN}OpenRC 服务已注册并配置为开机自启。${PLAIN}"
            ;;
        *)
            echo -e "${RED}未检测到 systemd 或 OpenRC，无法注册服务。${PLAIN}"
            return 1
            ;;
    esac
}

# 状态控制
show_start_failure() {
    echo -e "${RED}Xray 启动失败。以下是最近的日志：${PLAIN}"
    service_logs_recent
    local port_regex
    port_regex=$(jq -r '[.inbounds[]? | (.port // .listen_port)] | map(tostring) | join("|")' "$CONFIG_FILE" 2>/dev/null)
    [[ -z "$port_regex" || "$port_regex" == "null" ]] && port_regex="${DEFAULT_SS_PORT}|${DEFAULT_REALITY_PORT}|${DEFAULT_VMESS_WS_PORT}|${DEFAULT_ARGO_WS_PORT}"
    echo -e "${YELLOW}可依次执行：xr test、ss -ltnp | grep -E ':(${port_regex})'、xr log${PLAIN}"
}

start_service() {
    test_config || return 1
    if service_start; then
        echo -e "${GREEN}Xray 服务已启动。${PLAIN}"
        if argo_is_configured; then
            argo_start || echo -e "${YELLOW}Argo 隧道启动异常，请执行 'xr argo log' 排查。${PLAIN}"
            refresh_links_quiet
        fi
        check_status
    else
        show_start_failure
        return 1
    fi
}

stop_service() {
    if argo_is_configured; then
        argo_stop
    fi
    service_stop
    echo -e "${YELLOW}Xray 服务已停止。${PLAIN}"
}

restart_service() {
    test_config || return 1
    if service_restart; then
        echo -e "${GREEN}Xray 服务已重启。${PLAIN}"
        if argo_is_configured; then
            argo_restart || echo -e "${YELLOW}Argo 隧道重启异常，请执行 'xr argo log' 排查。${PLAIN}"
            refresh_links_quiet
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
        echo -e "${YELLOW}提示: 若启动失败，可运行 'xr test' 查看具体配置报错行${PLAIN}"
    fi

    if argo_is_configured; then
        local mode domain
        mode=$(argo_mode)
        domain=$(argo_domain)
        if [[ "$mode" == "quick" && -z "$domain" ]] && argo_service_is_active; then
            domain=$(refresh_argo_domain_from_log 2>/dev/null || true)
        fi
        if argo_service_is_active; then
            echo -e "Argo 隧道: ${GREEN}运行中${PLAIN} (${mode:-unknown}) ${CYAN}${domain:-域名待生成}${PLAIN}"
        else
            echo -e "Argo 隧道: ${RED}未运行${PLAIN} (${mode:-unknown})"
        fi
    fi
}

view_logs() {
    service_logs_follow
}

test_config() {
    if [[ ! -x "${INSTALL_DIR}/xray" ]]; then
        echo -e "${RED}未找到 Xray 可执行文件：${INSTALL_DIR}/xray${PLAIN}"
        return 1
    fi
    [[ -f "$CONFIG_FILE" ]] || {
        echo -e "${RED}未找到配置文件：${CONFIG_FILE}${PLAIN}"
        return 1
    }
    # 仅在启用 VMess-WS-TLS 入站时才校验证书文件
    if jq -e 'any(.inbounds[]?; .tag == "vmess-ws-tls-in")' "$CONFIG_FILE" >/dev/null 2>&1; then
        check_certificate_files || return 1
    fi
    echo -e "${YELLOW}正在检查 Xray 配置...${PLAIN}"
    XRAY_LOCATION_ASSET="${CONFIG_DIR}" ${INSTALL_DIR}/xray run -test -config "$CONFIG_FILE"
}

edit_config() {
    local editor="nano"
    command -v nano >/dev/null 2>&1 || editor="vi"
    $editor "$CONFIG_FILE"
    echo -e "${YELLOW}正在检查配置文件语法...${PLAIN}"
    if test_config; then
        read -rp "配置正确，是否重启 Xray 使其生效？[y/N]: " reload_choice </dev/tty
        [[ "$reload_choice" =~ ^[Yy]$ ]] && restart_service
    else
        echo -e "${RED}配置文件存在语法错误，请手动修正！${PLAIN}"
    fi
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
    read -rp "确定要完全卸载 Xray 吗？[y/N]: " confirm </dev/tty
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0

    local argo_mode_before argo_tunnel_before
    argo_mode_before=$(argo_mode)
    argo_tunnel_before=$(argo_tunnel_name)

    service_remove
    argo_service_remove

    rm -f "${INSTALL_DIR}/xray"
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

    echo -e "${GREEN}Xray 及快捷管理命令已完全卸载。${PLAIN}"
    if [[ "$argo_mode_before" == "local" && -n "$argo_tunnel_before" ]]; then
        echo -e "${YELLOW}注意: 云端 Argo 隧道 '${argo_tunnel_before}' 与 DNS 记录仍保留。${PLAIN}"
        echo -e "${YELLOW}如需删除，请在 Cloudflare 面板操作，或重新安装 cloudflared 后执行 tunnel delete。${PLAIN}"
    fi
    exit 0
}

# 部署全局 xr 快捷命令
install_cli() {
    if [[ -f "$0" && -r "$0" ]]; then
        cp "$0" "$CLI_TARGET"
    else
        curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_xray.sh -o "$CLI_TARGET" || {
            echo -e "${RED}无法安装 xr 快捷命令。${PLAIN}"
            return 1
        }
    fi
    chmod 0755 "$CLI_TARGET"
    echo -e "${GREEN}快捷管理命令 'xr' 部署完成。${PLAIN}"
}

# 查看已保存的节点链接（不重新探测网络）
view_saved_links() {
    if [[ ! -s "$LINKS_FILE" ]]; then
        echo -e "${YELLOW}尚未生成链接文件，请先执行 'xr info'。${PLAIN}"
        return 1
    fi
    if argo_is_configured && [[ "$(argo_mode)" == "quick" ]]; then
        echo -e "${YELLOW}提示: quick 模式域名可能已变化，建议执行 'xr info' 重新生成。${PLAIN}"
    fi
    cat "$LINKS_FILE"
}

# 静默刷新 links.txt（例如 Argo quick 域名生成之后）
refresh_links_quiet() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    view_inbound_info >/dev/null 2>&1 || true
}

# 交互菜单
show_menu() {
    echo -e "
${GREEN}Xray (${XRAY_VERSION}) 服务管理工具 (xr)${PLAIN}
------------------------
 1. 启动服务 (start)
 2. 停止服务 (stop)
 3. 重启服务 (restart)
 4. 查看状态 (status)
 5. 查看实时日志 (log)
 6. 查看入站节点配置 (info)
 7. 检查配置文件 (check/test)
 8. 编辑配置文件 (edit)
 9. 重新生成入站配置 (gen)
10. BBR 状态与网络调优 (bbr)
11. Argo 隧道管理 (argo)
12. 卸载 Xray (uninstall)
13. 查看已保存节点链接 (links)
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
        10) manage_bbr ;;
        11) argo_menu ;;
        12) uninstall_all ;;
        13) view_saved_links ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac
}

# 命令分发
main() {
    case "$1" in
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) check_status ;;
        log) view_logs ;;
        info) view_inbound_info ;;
        links) view_saved_links ;;
        check|test) test_config ;;
        edit) edit_config ;;
        gen) generate_production_config && apply_argo_configuration ;;
        argo) shift; argo_command "$@" ;;
        bbr) manage_bbr ;;
        uninstall) uninstall_all ;;
        menu) show_menu ;;
        "")
            if [[ "$0" == *"/xr" || "$0" == "xr" ]]; then
                show_menu
            else
                install_deps
                apply_bbr_and_optimization
                download_xray
                generate_production_config || exit 1

                # 仅检查用户实际选择的入站端口
                for port in "${SELECTED_PORTS[@]}"; do
                    check_port_available "$port" || exit 1
                done

                apply_argo_configuration || exit 1
                setup_service
                install_cli

                if ! start_service; then
                    echo -e "${RED}安装完成，但 Xray 未能启动；请根据上方日志修复后执行 xr start。${PLAIN}"
                    exit 1
                fi

                echo -e "\n${GREEN}=================================================${PLAIN}"
                echo -e " Xray (${XRAY_VERSION}) 安装完成！"
                echo -e " 配置文件: ${CONFIG_FILE}"
                echo -e " 证书目录: ${CERT_DIR}/"
                echo -e " 查看节点信息: ${YELLOW}xr info${PLAIN}"
                echo -e " 已保存链接:   ${YELLOW}${LINKS_FILE}${PLAIN} (${YELLOW}xr links${PLAIN})"
                echo -e " Argo 管理:    ${YELLOW}xr argo${PLAIN}"
                echo -e " 全局管理工具: ${YELLOW}xr${PLAIN}"
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
