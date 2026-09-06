#!/usr/bin/env bash
# =========================================================
# sing-box 一键安装、服务管理与 BBR 性能调优脚本
# =========================================================

set -e

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SYSTEMD_FILE="/etc/systemd/system/sing-box.service"
CLI_LINK="/usr/local/bin/sb"
SYSCTL_BBR_FILE="/etc/sysctl.d/99-network-bbr.conf"
LIMITS_FILE="/etc/security/limits.d/99-nofile.conf"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请以 root 权限运行此脚本！${PLAIN}" && exit 1

# 检测包管理器并安装必要依赖
install_deps() {
    echo -e "${YELLOW}正在检查并安装基础依赖...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y curl wget tar jq systemd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget tar jq systemd
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar jq systemd
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl wget tar jq systemd
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y curl wget tar jq systemd
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl wget tar jq
    else
        echo -e "${YELLOW}未识别的包管理器，请确保已安装 curl, wget, tar, jq${PLAIN}"
    fi
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

# BBR 与网络栈调优
apply_bbr_and_optimization() {
    echo -e "${YELLOW}正在配置 BBR 拥塞控制及 Linux 网络栈优化...${PLAIN}"

    # 尝试加载内核模块（部分虚拟化或定制内核需显式加载）
    modprobe tcp_bbr >/dev/null 2>&1 || true

    # 写入 sysctl 优化参数
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

    # 写入系统文件句柄并发数限制
    mkdir -p /etc/security/limits.d
    cat << 'EOF' > "$LIMITS_FILE"
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    # 刷新配置
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_BBR_FILE" >/dev/null 2>&1

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$cc" == "bbr" ]]; then
        echo -e "${GREEN}BBR 算法启用成功 (当前拥塞控制: ${cc})。${PLAIN}"
    else
        echo -e "${YELLOW}注意: 内核设置已下发，当前拥塞控制为 ${cc}（若内核版本低于 4.9 可能不支持 BBR）。${PLAIN}"
    fi
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
    curl -L -o "${tmp_dir}/${filename}" "$url"

    tar -xzf "${tmp_dir}/${filename}" -C "$tmp_dir"
    mv "${tmp_dir}/sing-box-${version}-${ARCH}/sing-box" "${INSTALL_DIR}/sing-box"
    chmod +x "${INSTALL_DIR}/sing-box"
    rm -rf "$tmp_dir"

    echo -e "${GREEN}sing-box 二进制已就绪：${INSTALL_DIR}/sing-box${PLAIN}"
}

# 部署默认配置文件
setup_config() {
    mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat << 'EOF' > "$CONFIG_FILE"
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": 1080
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
        echo -e "${GREEN}已创建基础示例配置文件：${CONFIG_FILE}${PLAIN}"
    fi
}

# 注册 Systemd 服务
setup_service() {
    cat << EOF > "$SYSTEMD_FILE"
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${INSTALL_DIR}/sing-box run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    echo -e "${GREEN}Systemd 系统服务已注册并配置为开机自启。${PLAIN}"
}

# 创建全局 sb 命令行管理工具
setup_cli() {
    cat << 'EOF' > "$CLI_LINK"
#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_FILE="/etc/sing-box/config.json"
SYSTEMD_FILE="/etc/systemd/system/sing-box.service"
SYSCTL_BBR_FILE="/etc/sysctl.d/99-network-bbr.conf"
LIMITS_FILE="/etc/security/limits.d/99-nofile.conf"

[[ $EUID -ne 0 ]] && echo -e "${RED}请以 root 权限运行此命令！${PLAIN}" && exit 1

detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) ARCH="linux-amd64" ;;
        aarch64|arm64) ARCH="linux-arm64" ;;
        armv7l|armv7) ARCH="linux-armv7" ;;
        s390x) ARCH="linux-s390x" ;;
        riscv64) ARCH="linux-riscv64" ;;
        *) echo -e "${RED}未知架构${PLAIN}"; exit 1 ;;
    esac
}

show_menu() {
    echo -e "
${GREEN}sing-box 服务管理工具 (sb)${PLAIN}
------------------------
 1. 启动服务 (start)
 2. 停止服务 (stop)
 3. 重启服务 (restart)
 4. 查看状态 (status)
 5. 查看实时日志 (log)
 6. 检查配置文件 (check)
 7. 编辑配置文件 (edit)
 8. 更新 sing-box (update)
 9. BBR状态与网络调优 (bbr)
10. 卸载 sing-box (uninstall)
 0. 退出
------------------------"
    read -rp "请输入选项 [0-10]: " choice
    case "$choice" in
        1) start_service ;;
        2) stop_service ;;
        3) restart_service ;;
        4) check_status ;;
        5) view_logs ;;
        6) test_config ;;
        7) edit_config ;;
        8) update_core ;;
        9) manage_bbr ;;
        10) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac
}

start_service() {
    systemctl start sing-box
    echo -e "${GREEN}sing-box 已尝试启动。${PLAIN}"
    check_status
}

stop_service() {
    systemctl stop sing-box
    echo -e "${YELLOW}sing-box 已停止。${PLAIN}"
}

restart_service() {
    systemctl restart sing-box
    echo -e "${GREEN}sing-box 已重启。${PLAIN}"
    check_status
}

check_status() {
    if systemctl is-active --quiet sing-box; then
        echo -e "运行状态: ${GREEN}运行中 (Active)${PLAIN}"
    else
        echo -e "运行状态: ${RED}未运行 (Inactive)${PLAIN}"
    fi
}

view_logs() {
    journalctl -u sing-box -f -o cat
}

test_config() {
    ${INSTALL_DIR}/sing-box check -c "$CONFIG_FILE"
}

edit_config() {
    local editor="nano"
    command -v nano >/dev/null 2>&1 || editor="vi"
    $editor "$CONFIG_FILE"
    echo -e "${YELLOW}已修改配置，正在自动检查语法...${PLAIN}"
    if ${INSTALL_DIR}/sing-box check -c "$CONFIG_FILE"; then
        read -rp "配置正确，是否重启 sing-box 使其生效？[y/N]: " reload_choice
        [[ "$reload_choice" =~ ^[Yy]$ ]] && restart_service
    else
        echo -e "${RED}配置文件存在语法错误，请手动修正！${PLAIN}"
    fi
}

update_core() {
    detect_arch
    echo -e "${YELLOW}正在检测最新版本...${PLAIN}"
    local tag=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    local cur_ver=$(${INSTALL_DIR}/sing-box version 2>/dev/null | awk 'NR==1{print $3}')
    
    if [[ "$cur_ver" == "${tag#v}" ]]; then
        echo -e "${GREEN}当前已是最新版本 (${cur_ver})，无需更新。${PLAIN}"
        return
    fi

    echo -e "${YELLOW}当前版本: ${cur_ver}，发现新版本: ${tag}，准备更新...${PLAIN}"
    local version="${tag#v}"
    local filename="sing-box-${version}-${ARCH}.tar.gz"
    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${filename}"
    
    local tmp_dir=$(mktemp -d)
    curl -L -o "${tmp_dir}/${filename}" "$url"
    tar -xzf "${tmp_dir}/${filename}" -C "$tmp_dir"
    systemctl stop sing-box
    mv "${tmp_dir}/sing-box-${version}-${ARCH}/sing-box" "${INSTALL_DIR}/sing-box"
    chmod +x "${INSTALL_DIR}/sing-box"
    rm -rf "$tmp_dir"
    systemctl start sing-box
    echo -e "${GREEN}更新成功，当前版本: $(${INSTALL_DIR}/sing-box version | awk 'NR==1{print $3}')${PLAIN}"
}

manage_bbr() {
    echo -e "=== ${GREEN}BBR 与网络参数状态${PLAIN} ==="
    echo -e "TCP 拥塞控制算法: ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${PLAIN}"
    echo -e "默认队列规则 (qdisc): ${GREEN}$(sysctl -n net.core.default_qdisc 2>/dev/null)${PLAIN}"
    echo -e "当前文件描述符限制: ${GREEN}$(ulimit -n)${PLAIN}"
    
    read -rp "是否重新应用/刷新 BBR 与高并发网络优化？[y/N]: " opt_choice
    if [[ "$opt_choice" =~ ^[Yy]$ ]]; then
        sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_BBR_FILE" >/dev/null 2>&1
        echo -e "${GREEN}网络参数已重新载入生效。${PLAIN}"
    fi
}

uninstall_all() {
    read -rp "确定要完全卸载 sing-box 吗？[y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0

    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_FILE"
    systemctl daemon-reload

    rm -f "${INSTALL_DIR}/sing-box"
    rm -f "/usr/local/bin/sb"

    read -rp "是否删除配置文件目录 (${CONFIG_FILE%/*})？[y/N]: " del_cfg
    [[ "$del_cfg" =~ ^[Yy]$ ]] && rm -rf "${CONFIG_FILE%/*}"

    read -rp "是否还原/删除 BBR 与网络优化配置文件？[y/N]: " del_bbr
    if [[ "$del_bbr" =~ ^[Yy]$ ]]; then
        rm -f "$SYSCTL_BBR_FILE" "$LIMITS_FILE"
        sysctl --system >/dev/null 2>&1 || true
        echo -e "${YELLOW}BBR 与网络配置文件已移除。${PLAIN}"
    fi

    echo -e "${GREEN}sing-box 及管理工具已完全卸载。${PLAIN}"
    exit 0
}

case "$1" in
    start) start_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    status) check_status ;;
    log) view_logs ;;
    check) test_config ;;
    edit) edit_config ;;
    update) update_core ;;
    bbr) manage_bbr ;;
    uninstall) uninstall_all ;;
    *) show_menu ;;
esac
EOF

    chmod +x "$CLI_LINK"
    echo -e "${GREEN}快捷管理命令 'sb' 已就绪。${PLAIN}"
}

main() {
    install_deps
    apply_bbr_and_optimization
    download_singbox
    setup_config
    setup_service
    setup_cli

    systemctl start sing-box
    echo -e "\n${GREEN}=================================================${PLAIN}"
    echo -e "${GREEN} sing-box 安装成功，BBR 与网络栈优化已生效！${PLAIN}"
    echo -e " 配置文件: ${CONFIG_FILE}"
    echo -e " 快速管理命令: ${YELLOW}sb${PLAIN} (可直接使用 sb start/stop/status/bbr 等)"
    echo -e "${GREEN}=================================================${PLAIN}"
}

main