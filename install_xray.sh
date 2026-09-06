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

    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_BBR_FILE" >/dev/null 2>&1
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    echo -e "${GREEN}网络栈调优完成，当前拥塞控制算法: ${cc}${PLAIN}"
}

# 下载固定版本 v26.6.27 的 Xray
download_xray() {
    detect_arch
    local filename="Xray-linux-${ARCH}.zip"
    local url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${filename}"

    echo -e "${GREEN}下载固定版本: ${XRAY_VERSION} (架构: ${ARCH})${PLAIN}"
    echo -e "${YELLOW}下载地址: ${url}${PLAIN}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! curl -L -f -o "${tmp_dir}/${filename}" "$url"; then
        echo -e "${RED}下载 Xray 失败，请检查网络连接或确认该架构包是否存在！${PLAIN}"
        rm -rf "$tmp_dir"
        exit 1
    fi

    unzip -q -o "${tmp_dir}/${filename}" -d "$tmp_dir"
    mkdir -p "$CONFIG_DIR"
    mv "${tmp_dir}/xray" "${INSTALL_DIR}/xray"
    chmod +x "${INSTALL_DIR}/xray"

    # 移动地理路由规则库到配置目录
    [[ -f "${tmp_dir}/geoip.dat" ]] && mv "${tmp_dir}/geoip.dat" "${CONFIG_DIR}/"
    [[ -f "${tmp_dir}/geosite.dat" ]] && mv "${tmp_dir}/geosite.dat" "${CONFIG_DIR}/"

    rm -rf "$tmp_dir"
    echo -e "${GREEN}Xray 二进制安装完成: ${INSTALL_DIR}/xray${PLAIN}"
}

# 确保证书文件存在，不存在则自动生成占位临时自签名证书防启动崩溃
ensure_dummy_cert() {
    mkdir -p "$CERT_DIR"
    if [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/privkey.pem" ]]; then
        echo -e "${YELLOW}未检测到 SSL 证书，正在生成临时自签名证书以保证服务顺利启动...${PLAIN}"
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "${CERT_DIR}/privkey.pem" \
            -out "${CERT_DIR}/fullchain.pem" \
            -subj "/CN=temporary.cert" >/dev/null 2>&1 || true
        echo -e "${YELLOW}临时证书已就绪。后续请将该域名的真实证书覆盖至此目录。${PLAIN}"
    fi
}

# 查看节点参数与客户端链接
view_inbound_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}未找到配置文件: ${CONFIG_FILE}，请先执行安装或重新生成配置！${PLAIN}"
        return 1
    fi

    echo -e "\n${YELLOW}正在解析配置文件与服务器公网 IP...${PLAIN}"
    local server_ip
    server_ip=$(curl -s4m 6 https://api.ipify.org || curl -s4m 6 https://ip.sb || echo "YOUR_SERVER_IP")

    local r_tag ws_tag
    r_tag=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .tag' "$CONFIG_FILE" 2>/dev/null)
    ws_tag=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .tag' "$CONFIG_FILE" 2>/dev/null)

    echo -e "\n${CYAN}================================================================${PLAIN}"
    echo -e "${CYAN}                     当前 Xray 入站节点配置详情                 ${PLAIN}"
    echo -e "${CYAN}================================================================${PLAIN}"

    if [[ -n "$r_tag" ]]; then
        local r_port r_uuid r_flow r_sni r_sid r_pub
        r_port=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .port' "$CONFIG_FILE")
        r_uuid=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .settings.clients[0].id' "$CONFIG_FILE")
        r_flow=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .settings.clients[0].flow' "$CONFIG_FILE")
        r_sni=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
        r_sid=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")

        if [[ -f "${CONFIG_DIR}/reality_pub.key" ]]; then
            r_pub=$(cat "${CONFIG_DIR}/reality_pub.key")
        fi

        echo -e "${GREEN}【协议 1: VLESS + Reality (直连推荐)】${PLAIN}"
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
            local r_link="vless://${r_uuid}@${server_ip}:${r_port}?security=reality&encryption=none&pbk=${r_pub}&headerType=none&type=tcp&flow=${r_flow}&sni=${r_sni}&sid=${r_sid}#Xray-Reality"
            echo -e "  分享链接 (Link):"
            echo -e "  ${YELLOW}${r_link}${PLAIN}"
        fi
        echo -e "----------------------------------------------------------------"
    fi

    if [[ -n "$ws_tag" ]]; then
        local ws_port ws_uuid ws_sni ws_path
        ws_port=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .port' "$CONFIG_FILE")
        ws_uuid=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .settings.clients[0].id' "$CONFIG_FILE")
        ws_sni=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .streamSettings.tlsSettings.serverName' "$CONFIG_FILE")
        ws_path=$(jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .streamSettings.wsSettings.path' "$CONFIG_FILE")

        echo -e "${GREEN}【协议 2: VLESS + WS + TLS (支持 CDN/Cloudflare 回源)】${PLAIN}"
        echo -e "  地址 (Address):     ${CYAN}${ws_sni} (或填服务器 IP / CDN 优选 IP)${PLAIN}"
        echo -e "  端口 (Port):        ${CYAN}${ws_port}${PLAIN}"
        echo -e "  用户 ID (UUID):     ${CYAN}${ws_uuid}${PLAIN}"
        echo -e "  加密 (Encryption):  ${CYAN}none${PLAIN}"
        echo -e "  传输协议 (Network): ${CYAN}ws${PLAIN}"
        echo -e "  传输安全 (Security):${CYAN}tls${PLAIN}"
        echo -e "  伪装域名 (SNI/Host):${CYAN}${ws_sni}${PLAIN}"
        echo -e "  路径 (Path):        ${CYAN}${ws_path}${PLAIN}"

        local ws_link="vless://${ws_uuid}@${ws_sni}:${ws_port}?security=tls&encryption=none&type=ws&host=${ws_sni}&path=${ws_path}#Xray-WS-TLS"
        echo -e "  分享链接 (Link):"
        echo -e "  ${YELLOW}${ws_link}${PLAIN}"
        echo -e "----------------------------------------------------------------"
    fi

    echo -e "${CYAN}证书目录: ${CERT_DIR}/${PLAIN}"
    echo -e "  公钥路径: ${YELLOW}${CERT_DIR}/fullchain.pem${PLAIN}"
    echo -e "  私钥路径: ${YELLOW}${CERT_DIR}/privkey.pem${PLAIN}"
    echo -e "${CYAN}================================================================${PLAIN}\n"
}

# 生成 Xray 配置文件
generate_production_config() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CERT_DIR"
    ensure_dummy_cert

    echo -e "\n${CYAN}=================================================${PLAIN}"
    echo -e "${CYAN}        Xray 节点配置生成器 (Dual-Inbound)       ${PLAIN}"
    echo -e "${CYAN}=================================================${PLAIN}"

    local ws_domain=""
    while [[ -z "$ws_domain" ]]; do
        read -rp "请输入 vless-ws-tls-in 绑定的域名 (例如: node.yourdomain.com): " ws_domain </dev/tty
        ws_domain=$(echo "$ws_domain" | tr -d '[:space:]')
    done

    echo -e "${YELLOW}正在自动生成 UUID、Reality 密钥对与 Short-ID...${PLAIN}"
    local uuid
    uuid=$(${INSTALL_DIR}/xray uuid)

    local keypair
    keypair=$(${INSTALL_DIR}/xray x25519)
    local private_key
    private_key=$(echo "$keypair" | grep -i "Private key:" | awk '{print $3}')
    local public_key
    public_key=$(echo "$keypair" | grep -i "Public key:" | awk '{print $3}')

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
          "dest": "www.apple.com:443",
          "xver": 0,
          "serverNames": [
            "www.apple.com"
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

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Environment="XRAY_LOCATION_ASSET=${CONFIG_DIR}"
ExecStart=${INSTALL_DIR}/xray run -config ${CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    echo -e "${GREEN}Systemd 系统服务已注册并配置为开机自启。${PLAIN}"
}

# 运行控制
start_service() {
    systemctl start xray
    echo -e "${GREEN}Xray 服务已尝试启动。${PLAIN}"
    check_status
}

stop_service() {
    systemctl stop xray
    echo -e "${YELLOW}Xray 服务已停止。${PLAIN}"
}

restart_service() {
    systemctl restart xray
    echo -e "${GREEN}Xray 服务已重启。${PLAIN}"
    check_status
}

check_status() {
    if systemctl is-active --quiet xray; then
        echo -e "运行状态: ${GREEN}运行中 (Active)${PLAIN}"
    else
        echo -e "运行状态: ${RED}未运行 (Inactive)${PLAIN}"
    fi
}

view_logs() {
    journalctl -u xray -f -o cat
}

test_config() {
    XRAY_LOCATION_ASSET="${CONFIG_DIR}" ${INSTALL_DIR}/xray -test -config "$CONFIG_FILE"
}

edit_config() {
    local editor="nano"
    command -v nano >/dev/null 2>&1 || editor="vi"
    $editor "$CONFIG_FILE"
    echo -e "${YELLOW}正在检查配置文件语法...${PLAIN}"
    if XRAY_LOCATION_ASSET="${CONFIG_DIR}" ${INSTALL_DIR}/xray -test -config "$CONFIG_FILE"; then
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

# 部署全局 xr 快捷命令（通过固定链接拉取脚本，避免进程替换失效）
install_cli() {
    curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_xray.sh -o "$CLI_TARGET"
    chmod +x "$CLI_TARGET"
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
 7. 检查配置文件 (check)
 8. 编辑配置文件 (edit)
 9. 重新生成双协议配置 (gen)
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

# 主执行流程
main() {
    case "$1" in
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) check_status ;;
        log) view_logs ;;
        info) view_inbound_info ;;
        check) test_config ;;
        edit) edit_config ;;
        gen) generate_production_config ;;
        bbr) manage_bbr ;;
        uninstall) uninstall_all ;;
        menu) show_menu ;;
        *)
            if [[ "$0" == *"/xr" ]]; then
                show_menu
            else
                install_deps
                apply_bbr_and_optimization
                download_xray
                generate_production_config
                setup_service
                install_cli

                systemctl restart xray >/dev/null 2>&1 || true

                echo -e "\n${GREEN}=================================================${PLAIN}"
                echo -e " Xray (${XRAY_VERSION}) 安装完成！"
                echo -e " 配置文件: ${CONFIG_FILE}"
                echo -e " 证书目录: ${CERT_DIR}/"
                echo -e " 查看节点信息: ${YELLOW}xr info${PLAIN}"
                echo -e " 全局管理工具: ${YELLOW}xr${PLAIN}"
                echo -e "${GREEN}=================================================${PLAIN}"
            fi
            ;;
    esac
}

main "$@"
