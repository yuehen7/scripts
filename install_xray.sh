#!/usr/bin/env bash
# =========================================================
# Xray (v26.6.27) 一键安装、服务管理、BBR 调优与配置生成脚本
# =========================================================

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
SYSTEMD_FILE="/etc/systemd/system/xray.service"
CLI_TARGET="/usr/local/bin/xr"
SYSCTL_BBR_FILE="/etc/sysctl.d/99-network-bbr.conf"
LIMITS_FILE="/etc/security/limits.d/99-nofile.conf"

set -o pipefail

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
        apk add --no-cache curl wget unzip jq openssl
    else
        echo -e "${YELLOW}未识别的包管理器，请确保已安装 curl, wget, unzip, jq, openssl${PLAIN}"
    fi
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

    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_BBR_FILE" >/dev/null 2>&1
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

# 查看节点配置与分享链接
view_inbound_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}未找到配置文件: ${CONFIG_FILE}${PLAIN}"
        return 1
    fi

    local server_ip
    server_ip=$(curl -s4m 6 https://api.ipify.org || curl -s4m 6 https://ip.sb || echo "YOUR_SERVER_IP")

    local r_tag ws_tag xhttp_tag
    r_tag=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .tag' "$CONFIG_FILE" 2>/dev/null)
    ws_tag=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .tag' "$CONFIG_FILE" 2>/dev/null)
    xhttp_tag=$(jq -r '.inbounds[] | select(.tag=="vless-xhttp-tls-in") | .tag' "$CONFIG_FILE" 2>/dev/null)

    echo -e "\n${CYAN}================================================================${PLAIN}"
    echo -e "${CYAN}                     当前 Xray 入站节点配置详情                 ${PLAIN}"
    echo -e "${CYAN}================================================================${PLAIN}"

    if [[ -n "$r_tag" ]]; then
        local r_port r_uuid r_flow r_sni r_sid r_pri r_pub
        r_port=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .port' "$CONFIG_FILE")
        r_uuid=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .settings.clients[0].id' "$CONFIG_FILE")
        r_flow=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .settings.clients[0].flow' "$CONFIG_FILE")
        r_sni=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
        r_pri=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .streamSettings.realitySettings.privateKey' "$CONFIG_FILE")
        r_sid=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")

        # 优先从文件读取，若文件缺失则直接由私钥逆向推导公钥
        if [[ -s "${CONFIG_DIR}/reality_pub.key" ]]; then
            r_pub=$(cat "${CONFIG_DIR}/reality_pub.key" | tr -d '[:space:]')
        fi
        if [[ -z "$r_pub" && -n "$r_pri" ]]; then
            r_pub=$(${INSTALL_DIR}/xray x25519 -i "$r_pri" 2>/dev/null | grep -iE 'Public[[:space:]]*key' | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')
            [[ -n "$r_pub" ]] && echo "$r_pub" > "${CONFIG_DIR}/reality_pub.key"
        fi

        echo -e "${GREEN}【协议 1: VLESS + Reality (直连推荐)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${server_ip}${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${r_port}${PLAIN}"
        echo -e "  用户 ID (UUID):     ${CYAN}${r_uuid}${PLAIN}"
        echo -e "  流控 (Flow):        ${CYAN}${r_flow}${PLAIN}"
        echo -e "  传输协议 (Network): tcp"
        echo -e "  伪装域名 (SNI):     ${CYAN}${r_sni}${PLAIN}"
        echo -e "  公钥 (PublicKey):   ${CYAN}${r_pub:-未找到}${PLAIN}"
        echo -e "  Short ID:           ${CYAN}${r_sid}${PLAIN}"

        if [[ -n "$r_pub" ]]; then
            local r_link="vless://${r_uuid}@${server_ip}:${r_port}?encryption=none&flow=${r_flow}&security=reality&sni=${r_sni}&fp=chrome&pbk=${r_pub}&sid=${r_sid}&type=tcp&headerType=none#Xray-Reality"
            echo -e "  分享链接 (Link):"
            echo -e "  ${YELLOW}${r_link}${PLAIN}"
            echo -e "  Mihomo 节点 JSON (添加到 proxies 数组):"
            jq -n \
                --arg name "Xray-Reality" \
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
        local ws_port ws_uuid ws_sni ws_path ws_alpn ws_path_uri ws_alpn_uri
        ws_port=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .port' "$CONFIG_FILE")
        ws_uuid=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .settings.clients[0].id' "$CONFIG_FILE")
        ws_sni=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .streamSettings.tlsSettings.serverName' "$CONFIG_FILE")
        ws_path=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .streamSettings.wsSettings.path' "$CONFIG_FILE")
        ws_alpn=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | (.streamSettings.tlsSettings.alpn[0] // "http/1.1")' "$CONFIG_FILE")
        ws_path_uri=${ws_path//\//%2F}
        ws_alpn_uri=${ws_alpn//\//%2F}

        echo -e "${GREEN}【协议 2: VLESS + WS + TLS (支持 CDN 回源)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${ws_sni} (或填服务器IP/CDN优选IP)${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${ws_port}${PLAIN}"
        echo -e "  用户 ID (UUID):     ${CYAN}${ws_uuid}${PLAIN}"
        echo -e "  传输协议 (Network): ws"
        echo -e "  传输安全 (Security):tls"
        echo -e "  伪装域名 (SNI/Host):${CYAN}${ws_sni}${PLAIN}"
        echo -e "  路径 (Path):        ${CYAN}${ws_path}${PLAIN}"

        local ws_link="vless://${ws_uuid}@${ws_sni}:${ws_port}?encryption=none&security=tls&sni=${ws_sni}&fp=chrome&alpn=${ws_alpn_uri}&insecure=0&allowInsecure=0&type=ws&host=${ws_sni}&path=${ws_path_uri}#Xray-WS-TLS"
        echo -e "  分享链接 (Link):"
        echo -e "  ${YELLOW}${ws_link}${PLAIN}"
        echo -e "  Mihomo 节点 JSON (添加到 proxies 数组):"
        jq -n \
            --arg name "Xray-WS-TLS" \
            --arg server "$ws_sni" \
            --argjson port "$ws_port" \
            --arg uuid "$ws_uuid" \
            --arg sni "$ws_sni" \
            --arg alpn "$ws_alpn" \
            --arg path "$ws_path" \
            '{
              name: $name,
              type: "vless",
              server: $server,
              port: $port,
              udp: true,
              uuid: $uuid,
              encryption: "",
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

    if [[ -n "$xhttp_tag" ]]; then
        local xhttp_port xhttp_uuid xhttp_sni xhttp_path xhttp_alpn xhttp_mode xhttp_path_uri
        xhttp_port=$(jq -r '.inbounds[] | select(.tag=="vless-xhttp-tls-in") | .port' "$CONFIG_FILE")
        xhttp_uuid=$(jq -r '.inbounds[] | select(.tag=="vless-xhttp-tls-in") | .settings.clients[0].id' "$CONFIG_FILE")
        xhttp_sni=$(jq -r '.inbounds[] | select(.tag=="vless-xhttp-tls-in") | .streamSettings.tlsSettings.serverName' "$CONFIG_FILE")
        xhttp_path=$(jq -r '.inbounds[] | select(.tag=="vless-xhttp-tls-in") | .streamSettings.xhttpSettings.path' "$CONFIG_FILE")
        xhttp_alpn=$(jq -r '.inbounds[] | select(.tag=="vless-xhttp-tls-in") | (.streamSettings.tlsSettings.alpn[0] // "h2")' "$CONFIG_FILE")
        xhttp_mode=$(jq -r '.inbounds[] | select(.tag=="vless-xhttp-tls-in") | (.streamSettings.xhttpSettings.mode // "packet-up")' "$CONFIG_FILE")
        xhttp_path_uri=${xhttp_path//\//%2F}

        echo -e "${GREEN}【协议 3: VLESS + XHTTP + TLS (CDN 备用)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${xhttp_sni} (或填服务器IP/CDN优选IP)${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${xhttp_port}${PLAIN}"
        echo -e "  用户 ID (UUID):     ${CYAN}${xhttp_uuid}${PLAIN}"
        echo -e "  传输协议 (Network): xhttp"
        echo -e "  传输模式 (Mode):    ${CYAN}${xhttp_mode}${PLAIN}"
        echo -e "  传输安全 (Security):tls"
        echo -e "  伪装域名 (SNI/Host):${CYAN}${xhttp_sni}${PLAIN}"
        echo -e "  路径 (Path):        ${CYAN}${xhttp_path}${PLAIN}"

        local xhttp_link="vless://${xhttp_uuid}@${xhttp_sni}:${xhttp_port}?encryption=none&security=tls&sni=${xhttp_sni}&fp=chrome&alpn=${xhttp_alpn}&insecure=0&allowInsecure=0&type=xhttp&host=${xhttp_sni}&path=${xhttp_path_uri}&mode=${xhttp_mode}#Xray-XHTTP-TLS"
        echo -e "  分享链接 (Link):"
        echo -e "  ${YELLOW}${xhttp_link}${PLAIN}"
        echo -e "  Mihomo 节点 JSON (添加到 proxies 数组):"
        jq -n \
            --arg name "Xray-XHTTP-TLS" \
            --arg server "$xhttp_sni" \
            --argjson port "$xhttp_port" \
            --arg uuid "$xhttp_uuid" \
            --arg sni "$xhttp_sni" \
            --arg alpn "$xhttp_alpn" \
            --arg path "$xhttp_path" \
            --arg mode "$xhttp_mode" \
            '{
              name: $name,
              type: "vless",
              server: $server,
              port: $port,
              udp: true,
              uuid: $uuid,
              encryption: "",
              tls: true,
              servername: $sni,
              alpn: [$alpn],
              "client-fingerprint": "chrome",
              "skip-cert-verify": false,
              network: "xhttp",
              "xhttp-opts": {
                path: $path,
                host: $sni,
                mode: $mode
              }
            }'
        echo -e "----------------------------------------------------------------"
    fi

    echo -e "${CYAN}证书目录: ${CERT_DIR}/${PLAIN}"
    echo -e "  公钥路径: ${YELLOW}${CERT_DIR}/fullchain.pem${PLAIN}"
    echo -e "  私钥路径: ${YELLOW}${CERT_DIR}/privkey.pem${PLAIN}"
    echo -e "${CYAN}================================================================${PLAIN}\n"
}

# 规范化写入标准 Xray 配置
generate_production_config() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CERT_DIR"
    ensure_dummy_cert || return 1

    echo -e "\n${CYAN}=================================================${PLAIN}"
    echo -e "${CYAN}        Xray 节点配置生成器 (Triple-Inbound)     ${PLAIN}"
    echo -e "${CYAN}=================================================${PLAIN}"

    local ws_domain=""
    while [[ -z "$ws_domain" ]]; do
        read -rp "请输入 vless-ws-tls-in 绑定的域名: " ws_domain </dev/tty
        ws_domain=$(echo "$ws_domain" | tr -d '[:space:]')
        ws_domain=${ws_domain%.}
        ws_domain=${ws_domain,,}
        if ! validate_domain "$ws_domain"; then
            echo -e "${RED}域名格式无效，请输入完整的域名，例如 node.example.com。${PLAIN}"
            ws_domain=""
        fi
    done

    echo -e "${YELLOW}生成密钥参数中...${PLAIN}"
    local uuid
    uuid=$(${INSTALL_DIR}/xray uuid) || {
        echo -e "${RED}无法生成 UUID。${PLAIN}"
        return 1
    }

    local reality_domain
    reality_domain=$(select_reality_target) || {
        echo -e "${RED}无法选择 REALITY 伪装目标，未写入新配置。请检查服务器的 IPv4 出站网络后重试。${PLAIN}"
        return 1
    }

    # 精确匹配提取 private_key 与 public_key
    local keypair
    keypair=$(${INSTALL_DIR}/xray x25519) || {
        echo -e "${RED}无法生成 REALITY 密钥对。${PLAIN}"
        return 1
    }
    local private_key
    private_key=$(echo "$keypair" | grep -iE 'Private[[:space:]]*key' | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')
    local public_key
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

    local short_id
    short_id=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | xxd -p)

    cat << EOF > "$CONFIG_FILE"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
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
          "dest": "${reality_domain}:443",
          "xver": 0,
          "serverNames": [
            "${reality_domain}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "tag": "vless-ws-tls-in",
      "port": 8443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${ws_domain}",
          "alpn": [
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/fullchain.pem",
              "keyFile": "${CERT_DIR}/privkey.pem"
            }
          ]
        },
        "wsSettings": {
          "path": "/ray"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "tag": "vless-xhttp-tls-in",
      "port": 2053,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${ws_domain}",
          "alpn": [
            "h2"
          ],
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/fullchain.pem",
              "keyFile": "${CERT_DIR}/privkey.pem"
            }
          ]
        },
        "xhttpSettings": {
          "path": "/xhttp",
          "mode": "packet-up"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "blocked",
        "domain": [
          "geosite:cn",
          "geosite:category-ads-all"
        ]
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": [
          "geoip:cn",
          "geoip:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF

    echo -e "${GREEN}配置文件生成并写入成功！${PLAIN}"
    view_inbound_info
}

# 注册 Systemd 守护进程
setup_service() {
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
    systemctl enable xray >/dev/null 2>&1 || {
        echo -e "${RED}无法启用 xray 服务。${PLAIN}"
        return 1
    }
    echo -e "${GREEN}Systemd 系统服务已注册并配置为开机自启。${PLAIN}"
}

# 状态控制
show_start_failure() {
    echo -e "${RED}Xray 启动失败。以下是最近的 systemd 日志：${PLAIN}"
    journalctl -u xray --no-pager -n 40 -o cat 2>/dev/null || true
    echo -e "${YELLOW}可依次执行：xr test、ss -ltnp | grep -E ':(443|2053|8443)'、xr log${PLAIN}"
}

start_service() {
    test_config || return 1
    if systemctl start xray; then
        echo -e "${GREEN}Xray 服务已启动。${PLAIN}"
        check_status
    else
        show_start_failure
        return 1
    fi
}

stop_service() {
    systemctl stop xray
    echo -e "${YELLOW}Xray 服务已停止。${PLAIN}"
}

restart_service() {
    test_config || return 1
    if systemctl restart xray; then
        echo -e "${GREEN}Xray 服务已重启。${PLAIN}"
        check_status
    else
        show_start_failure
        return 1
    fi
}

check_status() {
    if systemctl is-active --quiet xray; then
        echo -e "运行状态: ${GREEN}运行中 (Active)${PLAIN}"
    else
        echo -e "运行状态: ${RED}未运行 (Inactive)${PLAIN}"
        echo -e "${YELLOW}提示: 若启动失败，可运行 'xr test' 查看具体配置报错行${PLAIN}"
    fi
}

view_logs() {
    journalctl -u xray -f -o cat
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
    check_certificate_files || return 1
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

    systemctl stop xray >/dev/null 2>&1 || true
    systemctl disable xray >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_FILE"
    systemctl daemon-reload

    rm -f "${INSTALL_DIR}/xray"
    rm -f "$CLI_TARGET"

    read -rp "是否删除配置文件与证书目录 (${CONFIG_DIR})？[y/N]: " del_cfg </dev/tty
    [[ "$del_cfg" =~ ^[Yy]$ ]] && rm -rf "$CONFIG_DIR"

    read -rp "是否还原/删除 BBR 与网络优化配置文件？[y/N]: " del_bbr </dev/tty
    if [[ "$del_bbr" =~ ^[Yy]$ ]]; then
        rm -f "$SYSCTL_BBR_FILE" "$LIMITS_FILE"
        sysctl --system >/dev/null 2>&1 || true
        echo -e "${YELLOW}BBR 与网络配置文件已移除。${PLAIN}"
    fi

    echo -e "${GREEN}Xray 及快捷管理命令已完全卸载。${PLAIN}"
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
 9. 重新生成三协议配置 (gen)
10. BBR 状态与网络调优 (bbr)
11. 卸载 Xray (uninstall)
 0. 退出
------------------------"
    read -rp "请输入选项 [0-11]: " choice </dev/tty
    case "$choice" in
        1) start_service ;;
        2) stop_service ;;
        3) restart_service ;;
        4) check_status ;;
        5) view_logs ;;
        6) view_inbound_info ;;
        7) test_config ;;
        8) edit_config ;;
        9) generate_production_config ;;
        10) manage_bbr ;;
        11) uninstall_all ;;
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
        check|test) test_config ;;
        edit) edit_config ;;
        gen) generate_production_config ;;
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
                generate_production_config
                setup_service
                install_cli

                check_port_available 443 || exit 1
                check_port_available 8443 || exit 1
                check_port_available 2053 || exit 1
                if ! start_service; then
                    echo -e "${RED}安装完成，但 Xray 未能启动；请根据上方日志修复后执行 xr start。${PLAIN}"
                    exit 1
                fi

                echo -e "\n${GREEN}=================================================${PLAIN}"
                echo -e " Xray (${XRAY_VERSION}) 安装完成！"
                echo -e " 配置文件: ${CONFIG_FILE}"
                echo -e " 证书目录: ${CERT_DIR}/"
                echo -e " 查看节点信息: ${YELLOW}xr info${PLAIN}"
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
