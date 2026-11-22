#!/usr/bin/env bash
# =========================================================
# WireProxy-WARP 一键安装与管理脚本
# 通过 WireProxy + wgcf 提供 WARP SOCKS5 代理
# 支持 systemd (Debian/Ubuntu/CentOS 等) 与 OpenRC (Alpine 等)
# 额外功能：轮换 Endpoint / 重新注册账户以切换 WARP 出口 IP
# =========================================================

# 允许通过 sh 调用：自动切换到 bash（此处必须使用 POSIX 语法）
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "错误：本脚本需要 bash，请先执行 apk add --no-cache bash（Alpine）或安装 bash 后重试。" >&2
    exit 1
fi

# 判断当前文件是否被 source 引入（用于兼容 curl | bash、bash < file 等执行方式）
is_sourced() {
    [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]
}

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 路径与常量
CONFIG_DIR="/etc/wireproxy"
SETTINGS_FILE="${CONFIG_DIR}/settings.conf"
ACCOUNT_FILE="${CONFIG_DIR}/wgcf-account.toml"
PROFILE_FILE="${CONFIG_DIR}/wgcf-profile.conf"
PROXY_CONF="${CONFIG_DIR}/wireproxy.conf"
WIREPROXY_BIN="/usr/local/bin/wireproxy"
WGCF_BIN="/usr/local/bin/wgcf"
CLI_TARGET="/usr/local/bin/warp"
SERVICE_NAME="wireproxy-warp"
SYSTEMD_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INITD_FILE="/etc/init.d/${SERVICE_NAME}"
SERVICE_LOG="/var/log/${SERVICE_NAME}.log"

DEFAULT_ENDPOINT="engage.cloudflareclient.com:2408"
DEFAULT_MTU="1280"
# 域名解析出口优先级：auto / ipv4 / ipv6
DEFAULT_RESOLVE_STRATEGY="auto"

# WireProxy 下载失败时使用的兜底版本
WIREPROXY_FALLBACK_TAGS=("v1.1.3" "v1.1.2")
WGCF_FALLBACK_TAGS=("v2.3.1" "v2.3.0")

# 默认值，load_settings 后会被覆盖
LISTEN_ADDR="127.0.0.1"
LISTEN_PORT=""
SOCKS_USER=""
SOCKS_PASS=""
WARP_ENDPOINT="$DEFAULT_ENDPOINT"
WARP_MTU="$DEFAULT_MTU"
RESOLVE_STRATEGY="$DEFAULT_RESOLVE_STRATEGY"

set -o pipefail

# 检查 root 权限（被 source 引入时不检查，便于本地测试）
if ! is_sourced && [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：请以 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

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
# 启动时立即检测，保证 warp start/stop/restart 等管理命令可用
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
        systemd) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
        openrc) rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
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

# 安装依赖
install_deps() {
    echo -e "${YELLOW}正在检查并安装基础依赖...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y curl wget tar ca-certificates iproute2 >/dev/null 2>&1 || \
            apt-get install -y curl wget tar ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget tar ca-certificates iproute >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar ca-certificates iproute >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl wget tar ca-certificates iproute2 >/dev/null 2>&1 || true
    elif command -v zypper >/dev/null 2>&1; then
        zypper -n install curl wget tar ca-certificates iproute2 >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash curl wget tar ca-certificates iproute2 openrc >/dev/null 2>&1 || \
            apk add --no-cache bash curl wget tar ca-certificates iproute2
    else
        echo -e "${YELLOW}未识别的包管理器，请确保已安装 bash、curl、wget、tar、iproute2。${PLAIN}"
    fi

    # 依赖安装完成后重新检测服务管理器（例如最小化 Alpine 环境）
    detect_init_system
}

# 检测 CPU 架构，分别得到 WireProxy / wgcf / 镜像 所需的架构名
detect_arch() {
    local arch
    arch=$(uname -m)
    WP_ARCH=""
    WGCF_ARCH=""
    REF_ARCH=""
    case "$arch" in
        x86_64|amd64)
            WP_ARCH="amd64"; WGCF_ARCH="amd64"; REF_ARCH="amd64" ;;
        aarch64|arm64)
            WP_ARCH="arm64"; WGCF_ARCH="arm64"; REF_ARCH="arm64" ;;
        armv7l|armv7|armv8l|arm)
            WP_ARCH="arm"; WGCF_ARCH="armv7"; REF_ARCH="" ;;
        armv6l|armv6)
            WP_ARCH="arm"; WGCF_ARCH="armv6"; REF_ARCH="" ;;
        i386|i486|i586|i686|x86)
            WP_ARCH="386"; WGCF_ARCH="386"; REF_ARCH="386" ;;
        s390x)
            WP_ARCH="s390x"; WGCF_ARCH="s390x"; REF_ARCH="s390x" ;;
        riscv64)
            WP_ARCH="riscv64"; WGCF_ARCH=""; REF_ARCH="" ;;
        mips)
            WP_ARCH="mips"; WGCF_ARCH=""; REF_ARCH="" ;;
        mipsel|mipsle)
            WP_ARCH="mipsle"; WGCF_ARCH=""; REF_ARCH="" ;;
        *)
            echo -e "${RED}不支持的 CPU 架构: ${arch}${PLAIN}"
            exit 1
            ;;
    esac

    if [[ -z "$WGCF_ARCH" ]]; then
        echo -e "${RED}wgcf 暂不提供 ${arch} 架构的官方二进制，无法完成 WARP 账户注册。${PLAIN}"
        exit 1
    fi
}

# 下载文件，优先 curl，失败后尝试 wget
download_file() {
    local url="$1" out="$2"
    curl -fL --retry 2 --connect-timeout 10 --max-time 180 -o "$out" "$url" >/dev/null 2>&1 && return 0
    wget -q -T 30 -O "$out" "$url" >/dev/null 2>&1 && return 0
    return 1
}

# 从 GitHub API 获取最新 tag
github_latest_tag() {
    local repo="$1" tag
    tag=$(curl -sL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    printf '%s\n' "$tag"
}

# 下载并安装 WireProxy
download_wireproxy() {
    echo -e "${YELLOW}正在下载 WireProxy...${PLAIN}"
    local tmp tag url
    tmp=$(mktemp -d) || return 1

    tag=$(github_latest_tag "windtf/wireproxy")
    local tags=()
    [[ -n "$tag" ]] && tags+=("$tag")
    tags+=("${WIREPROXY_FALLBACK_TAGS[@]}")

    for tag in "${tags[@]}"; do
        url="https://github.com/windtf/wireproxy/releases/download/${tag}/wireproxy_linux_${WP_ARCH}.tar.gz"
        rm -f "${tmp}/wp.tar.gz"
        if download_file "$url" "${tmp}/wp.tar.gz"; then
            mkdir -p "${tmp}/extract"
            rm -rf "${tmp}/extract"/*
            if tar -xzf "${tmp}/wp.tar.gz" -C "${tmp}/extract" >/dev/null 2>&1; then
                local bin_path
                bin_path=$(find "${tmp}/extract" -type f -name wireproxy 2>/dev/null | head -n1)
                if [[ -n "$bin_path" ]]; then
                    install -m 0755 "$bin_path" "$WIREPROXY_BIN"
                    rm -rf "$tmp"
                    echo -e "${GREEN}WireProxy 安装完成: $("$WIREPROXY_BIN" -v 2>/dev/null | head -n1)${PLAIN}"
                    return 0
                fi
            fi
        fi
    done

    # 兜底：参考项目的镜像二进制
    if [[ -n "$REF_ARCH" ]]; then
        echo -e "${YELLOW}GitHub 下载失败，尝试镜像源...${PLAIN}"
        url="https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/wireproxy/wireproxy-latest-linux-${REF_ARCH}"
        if download_file "$url" "${tmp}/wireproxy"; then
            chmod +x "${tmp}/wireproxy"
            if "${tmp}/wireproxy" -v >/dev/null 2>&1; then
                install -m 0755 "${tmp}/wireproxy" "$WIREPROXY_BIN"
                rm -rf "$tmp"
                echo -e "${GREEN}WireProxy 安装完成（镜像源）。${PLAIN}"
                return 0
            fi
        fi
    fi

    rm -rf "$tmp"
    echo -e "${RED}WireProxy 下载失败，请检查服务器网络后重试。${PLAIN}"
    return 1
}

# 下载并安装 wgcf
download_wgcf() {
    echo -e "${YELLOW}正在下载 wgcf...${PLAIN}"
    local tmp tag ver url
    tmp=$(mktemp -d) || return 1

    tag=$(github_latest_tag "ViRb3/wgcf")
    local tags=()
    [[ -n "$tag" ]] && tags+=("$tag")
    tags+=("${WGCF_FALLBACK_TAGS[@]}")

    for tag in "${tags[@]}"; do
        ver="${tag#v}"
        url="https://github.com/ViRb3/wgcf/releases/download/${tag}/wgcf_${ver}_linux_${WGCF_ARCH}"
        rm -f "${tmp}/wgcf"
        if download_file "$url" "${tmp}/wgcf"; then
            chmod +x "${tmp}/wgcf"
            if "${tmp}/wgcf" --help >/dev/null 2>&1; then
                install -m 0755 "${tmp}/wgcf" "$WGCF_BIN"
                rm -rf "$tmp"
                echo -e "${GREEN}wgcf 安装完成（${tag}）。${PLAIN}"
                return 0
            fi
        fi
    done

    # 兜底：参考项目的镜像二进制
    if [[ -n "$REF_ARCH" ]]; then
        echo -e "${YELLOW}GitHub 下载失败，尝试镜像源...${PLAIN}"
        url="https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/wgcf/wgcf-latest-linux-${REF_ARCH}"
        if download_file "$url" "${tmp}/wgcf"; then
            chmod +x "${tmp}/wgcf"
            if "${tmp}/wgcf" --help >/dev/null 2>&1; then
                install -m 0755 "${tmp}/wgcf" "$WGCF_BIN"
                rm -rf "$tmp"
                echo -e "${GREEN}wgcf 安装完成（镜像源）。${PLAIN}"
                return 0
            fi
        fi
    fi

    rm -rf "$tmp"
    echo -e "${RED}wgcf 下载失败，请检查服务器网络后重试。${PLAIN}"
    return 1
}

# 读取/保存脚本设置
load_settings() {
    [[ -f "$SETTINGS_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$SETTINGS_FILE"
    LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1}"
    LISTEN_PORT="${LISTEN_PORT:-}"
    SOCKS_USER="${SOCKS_USER:-}"
    SOCKS_PASS="${SOCKS_PASS:-}"
    WARP_ENDPOINT="${WARP_ENDPOINT:-$DEFAULT_ENDPOINT}"
    WARP_MTU="${WARP_MTU:-$DEFAULT_MTU}"
    RESOLVE_STRATEGY="${RESOLVE_STRATEGY:-$DEFAULT_RESOLVE_STRATEGY}"
}

save_settings() {
    mkdir -p "$CONFIG_DIR"
    {
        printf 'LISTEN_ADDR=%q\n' "$LISTEN_ADDR"
        printf 'LISTEN_PORT=%q\n' "$LISTEN_PORT"
        printf 'SOCKS_USER=%q\n' "$SOCKS_USER"
        printf 'SOCKS_PASS=%q\n' "$SOCKS_PASS"
        printf 'WARP_ENDPOINT=%q\n' "$WARP_ENDPOINT"
        printf 'WARP_MTU=%q\n' "$WARP_MTU"
        printf 'RESOLVE_STRATEGY=%q\n' "$RESOLVE_STRATEGY"
    } > "$SETTINGS_FILE"
    chmod 600 "$SETTINGS_FILE"
}

# 从 wgcf-profile.conf 生成 WireProxy 配置
generate_proxy_config() {
    if [[ ! -s "$PROFILE_FILE" ]]; then
        echo -e "${RED}未找到 WARP 配置文件: ${PROFILE_FILE}${PLAIN}"
        return 1
    fi

    local private_key public_key addresses
    private_key=$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$PROFILE_FILE" | tr -d '\r' | head -n1)
    public_key=$(sed -n 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*//p' "$PROFILE_FILE" | tr -d '\r' | head -n1)
    # 兼容单行/多行 Address；过滤掉 wgcf 在缺少 IPv6 时生成的空地址（如 "/128"）
    addresses=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$PROFILE_FILE" | tr -d '\r' \
        | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | awk 'NF && $0 !~ /^\// { if (a) a = a ", " $0; else a = $0 } END { print a }')
    [[ -z "$addresses" ]] && addresses="172.16.0.2/32"

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        echo -e "${RED}WARP 配置文件内容不完整，无法生成 WireProxy 配置。${PLAIN}"
        return 1
    fi

    mkdir -p "$CONFIG_DIR"
    {
        cat << EOF
# 由 install_warp.sh 自动生成
[Interface]
Address = ${addresses}
PrivateKey = ${private_key}
DNS = 1.1.1.1, 1.0.0.1
MTU = ${WARP_MTU}

[Peer]
PublicKey = ${public_key}
Endpoint = ${WARP_ENDPOINT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25

[Socks5]
BindAddress = ${LISTEN_ADDR}:${LISTEN_PORT}
EOF
        if [[ -n "$SOCKS_USER" ]]; then
            cat << EOF
Username = ${SOCKS_USER}
Password = ${SOCKS_PASS}
EOF
        fi
    } > "$PROXY_CONF"

    # 域名解析出口优先级：auto / ipv4 / ipv6
    cat >> "$PROXY_CONF" << EOF

[Resolve]
ResolveStrategy = ${RESOLVE_STRATEGY:-auto}
EOF
    chmod 600 "$PROXY_CONF"
}

# 校验配置文件语法
test_config() {
    if [[ ! -x "$WIREPROXY_BIN" ]]; then
        echo -e "${RED}未找到 wireproxy 可执行文件：${WIREPROXY_BIN}${PLAIN}"
        return 1
    fi
    if [[ ! -f "$PROXY_CONF" ]]; then
        echo -e "${RED}未找到配置文件：${PROXY_CONF}${PLAIN}"
        return 1
    fi
    echo -e "${YELLOW}正在检查 WireProxy 配置...${PLAIN}"
    "$WIREPROXY_BIN" -n -c "$PROXY_CONF"
}

# 端口/地址校验
valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

random_port() {
    echo $(( (RANDOM % 50000) + 10000 ))
}

valid_endpoint() {
    local ep="$1"
    [[ "$ep" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] || \
        [[ "$ep" =~ ^\[[0-9A-Fa-f:]+\]:[0-9]{1,5}$ ]] || return 1
    valid_port "${ep##*:}"
}

# 交互配置（全新安装时使用）
configure_settings() {
    local input rand
    rand=$(random_port)

    while true; do
        read -rp "请输入 SOCKS5 端口 [默认随机 ${rand}]（直接回车使用随机端口）: " input </dev/tty || input=""
        input=$(printf '%s' "$input" | tr -d '[:space:]')
        [[ -z "$input" ]] && input="$rand"
        if ! valid_port "$input"; then
            echo -e "${RED}端口无效，请输入 1-65535 之间的数字。${PLAIN}"
            continue
        fi
        if port_in_use "$input"; then
            echo -e "${RED}端口 ${input} 已被占用，请更换。${PLAIN}"
            rand=$(random_port)
            continue
        fi
        LISTEN_PORT="$input"
        break
    done

    while true; do
        read -rp "请输入监听地址 [默认 127.0.0.1]（对外提供服务请输入 0.0.0.0）: " input </dev/tty || input=""
        input=$(printf '%s' "$input" | tr -d '[:space:]')
        [[ -z "$input" ]] && input="127.0.0.1"
        case "$input" in
            127.0.0.1|0.0.0.0)
                LISTEN_ADDR="$input"
                break
                ;;
            *)
                echo -e "${RED}仅支持 127.0.0.1（仅本机）或 0.0.0.0（对外）。${PLAIN}"
                ;;
        esac
    done

    SOCKS_USER=""
    SOCKS_PASS=""
    if [[ "$LISTEN_ADDR" == "0.0.0.0" ]]; then
        echo -e "${YELLOW}警告：SOCKS5 监听在 0.0.0.0 时，任何能访问该端口的人都可以使用你的 WARP 出口，建议启用用户名/密码认证。${PLAIN}"
        while true; do
            read -rp "请输入 SOCKS5 用户名（留空表示不启用认证）: " input </dev/tty || input=""
            input=$(printf '%s' "$input" | tr -d '[:space:]')
            if [[ -z "$input" ]]; then
                echo -e "${YELLOW}已选择不启用认证，请务必通过防火墙限制来源 IP。${PLAIN}"
                break
            fi
            if [[ ! "$input" =~ ^[A-Za-z0-9._-]+$ ]]; then
                echo -e "${RED}用户名仅支持字母、数字、点、下划线和中划线。${PLAIN}"
                continue
            fi
            SOCKS_USER="$input"
            break
        done

        if [[ -n "$SOCKS_USER" ]]; then
            while true; do
                read -rsp "请输入 SOCKS5 密码（不能包含空格）: " input </dev/tty || input=""
                echo ""
                if [[ -z "$input" ]]; then
                    echo -e "${RED}密码不能为空。${PLAIN}"
                    continue
                fi
                if [[ "$input" =~ [[:space:]] ]]; then
                    echo -e "${RED}密码不能包含空格。${PLAIN}"
                    continue
                fi
                SOCKS_PASS="$input"
                break
            done
        fi
    fi

    WARP_ENDPOINT="$DEFAULT_ENDPOINT"
    WARP_MTU="$DEFAULT_MTU"

    echo -e "${GREEN}配置确认：${PLAIN}"
    echo -e "  SOCKS5 地址: ${LISTEN_ADDR}:${LISTEN_PORT}"
    [[ -n "$SOCKS_USER" ]] && echo -e "  SOCKS5 认证: 已启用（用户名 ${SOCKS_USER}）" || echo -e "  SOCKS5 认证: 未启用"
    echo -e "  Endpoint: ${WARP_ENDPOINT}"
}

# 向 CloudFlare 注册新的 WARP 账户
register_account() {
    if [[ ! -x "$WGCF_BIN" ]]; then
        echo -e "${RED}未找到 wgcf: ${WGCF_BIN}${PLAIN}"
        return 1
    fi

    local tmp i ok=0
    tmp=$(mktemp -d) || return 1
    echo -e "${YELLOW}正在向 CloudFlare WARP 注册账户...${PLAIN}"

    for i in 1 2 3 4 5; do
        rm -f "${tmp}/wgcf-account.toml" "${tmp}/wgcf-profile.conf"
        if (cd "$tmp" && "$WGCF_BIN" register --accept-tos >"${tmp}/register.log" 2>&1) \
            && [[ -s "${tmp}/wgcf-account.toml" ]]; then
            ok=1
            break
        fi
        echo -e "${YELLOW}注册失败（可能触发 429 限流），第 ${i}/5 次，稍后重试...${PLAIN}"
        tail -n 3 "${tmp}/register.log" 2>/dev/null | sed 's/^/    /'
        sleep $((i * 5))
    done

    if [[ $ok -ne 1 ]]; then
        rm -rf "$tmp"
        echo -e "${RED}WARP 账户注册失败，请稍后重试。${PLAIN}"
        echo -e "${YELLOW}提示：香港、美西等部分区域可能被 CloudFlare 限制注册，可更换 VPS 区域后重试。${PLAIN}"
        return 1
    fi

    if ! (cd "$tmp" && "$WGCF_BIN" generate >"${tmp}/generate.log" 2>&1) \
        || [[ ! -s "${tmp}/wgcf-profile.conf" ]]; then
        tail -n 3 "${tmp}/generate.log" 2>/dev/null | sed 's/^/    /'
        rm -rf "$tmp"
        echo -e "${RED}生成 WARP WireGuard 配置失败。${PLAIN}"
        return 1
    fi

    mkdir -p "$CONFIG_DIR"
    install -m 600 "${tmp}/wgcf-account.toml" "$ACCOUNT_FILE"
    install -m 600 "${tmp}/wgcf-profile.conf" "$PROFILE_FILE"
    rm -rf "$tmp"
    echo -e "${GREEN}WARP 账户注册成功。${PLAIN}"
    return 0
}

# 重新注册账户（切换 IP 时使用）
re_register_account() {
    if [[ ! -x "$WGCF_BIN" ]]; then
        echo -e "${RED}未找到 wgcf: ${WGCF_BIN}${PLAIN}"
        return 1
    fi

    local tmp i ok=0 license=""
    tmp=$(mktemp -d) || return 1

    # 记录原账户的 WARP+ 许可证，注册成功后尝试重新绑定
    if [[ -s "$ACCOUNT_FILE" ]]; then
        license=$(sed -n 's/^license_key[[:space:]]*=[[:space:]]*//p' "$ACCOUNT_FILE" | head -n1 | tr -d "\"'")
    fi

    echo -e "${YELLOW}正在重新注册 WARP 账户...${PLAIN}"
    for i in 1 2 3 4 5; do
        rm -f "${tmp}/wgcf-account.toml" "${tmp}/wgcf-profile.conf"
        if (cd "$tmp" && "$WGCF_BIN" register --accept-tos >"${tmp}/register.log" 2>&1) \
            && [[ -s "${tmp}/wgcf-account.toml" ]]; then
            ok=1
            break
        fi
        echo -e "${YELLOW}注册失败（可能触发 429 限流），第 ${i}/5 次，稍后重试...${PLAIN}"
        tail -n 3 "${tmp}/register.log" 2>/dev/null | sed 's/^/    /'
        sleep $((i * 5))
    done

    if [[ $ok -ne 1 ]]; then
        rm -rf "$tmp"
        echo -e "${RED}重新注册账户失败，保留原账户。${PLAIN}"
        return 1
    fi

    # 新账户重新绑定原 WARP+ 许可证（失败则继续使用免费 WARP）
    if [[ -n "$license" ]]; then
        echo -e "${YELLOW}正在尝试重新绑定 WARP+ 许可证...${PLAIN}"
        if (cd "$tmp" && "$WGCF_BIN" update --license-key "$license" >"${tmp}/update.log" 2>&1); then
            echo -e "${GREEN}WARP+ 许可证已重新绑定。${PLAIN}"
        else
            echo -e "${YELLOW}WARP+ 许可证重新绑定失败，新账户将使用免费 WARP。${PLAIN}"
        fi
    fi

    if ! (cd "$tmp" && "$WGCF_BIN" generate >"${tmp}/generate.log" 2>&1) \
        || [[ ! -s "${tmp}/wgcf-profile.conf" ]]; then
        tail -n 3 "${tmp}/generate.log" 2>/dev/null | sed 's/^/    /'
        rm -rf "$tmp"
        echo -e "${RED}生成新的 WARP 配置失败，保留原账户。${PLAIN}"
        return 1
    fi

    install -m 600 "${tmp}/wgcf-account.toml" "$ACCOUNT_FILE"
    install -m 600 "${tmp}/wgcf-profile.conf" "$PROFILE_FILE"
    rm -rf "$tmp"
    generate_proxy_config || return 1
    echo -e "${GREEN}WARP 账户已重新注册。${PLAIN}"
    return 0
}

# 测试代理时所连接的本地地址
local_proxy_host() {
    if [[ "$LISTEN_ADDR" == "0.0.0.0" ]]; then
        echo "127.0.0.1"
    else
        echo "$LISTEN_ADDR"
    fi
}

# 通过 SOCKS5 获取 CloudFlare trace
get_proxy_trace() {
    local host url
    host=$(local_proxy_host)
    url="socks5h://${host}:${LISTEN_PORT}"
    if [[ -n "$SOCKS_USER" ]]; then
        curl -s --max-time 10 --connect-timeout 6 -x "$url" \
            --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null
    else
        curl -s --max-time 10 --connect-timeout 6 -x "$url" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null
    fi
}

get_proxy_ip() {
    get_proxy_trace | tr -d '\r' | sed -n 's/^ip=//p' | head -n1
}

get_proxy_warp() {
    get_proxy_trace | tr -d '\r' | sed -n 's/^warp=//p' | head -n1
}

# 等待代理真正可用（WARP 状态为 on/plus）
wait_proxy_ready() {
    local tries="${1:-10}" i status
    for ((i = 1; i <= tries; i++)); do
        status=$(get_proxy_warp)
        [[ "$status" == "on" || "$status" == "plus" ]] && return 0
        sleep 2
    done
    return 1
}

# 检测 VPS 出站栈，用于选择 IPv4 / IPv6 Endpoint
detect_stack() {
    [[ -n "${STACK:-}" ]] && return

    # 优先验证真实连通性，避免“有 IPv4 路由但实际不通”的机器选错协议栈
    if curl -s4m5 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null; then
        STACK="v4"
        return
    fi
    if curl -s6m5 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null; then
        STACK="v6"
        return
    fi

    if command -v ip >/dev/null 2>&1; then
        if ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
            STACK="v4"
            return
        fi
        if ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
            STACK="v6"
            return
        fi
    fi
    STACK="v4"
}

# 随机生成一个 CloudFlare WARP Endpoint
random_endpoint() {
    detect_stack
    if [[ "$STACK" == "v6" ]]; then
        local v6eps=(
            "[2606:4700:d0::a29f:c001]:2408"
            "[2606:4700:d0::a29f:c101]:2408"
            "[2606:4700:d1::a29f:c001]:2408"
            "[2606:4700:d1::a29f:c101]:2408"
        )
        echo "${v6eps[$((RANDOM % ${#v6eps[@]}))]}"
        return
    fi

    local prefixes=(
        "162.159.192"
        "162.159.193"
        "162.159.195"
        "162.159.204"
        "188.114.96"
        "188.114.97"
        "188.114.98"
        "188.114.99"
    )
    local prefix="${prefixes[$((RANDOM % ${#prefixes[@]}))]}"
    local last=$(( (RANDOM % 254) + 1 ))
    echo "${prefix}.${last}:2408"
}

# 应用 Endpoint 并生成配置（不负责重启）
apply_endpoint() {
    WARP_ENDPOINT="$1"
    save_settings
    generate_proxy_config
}

# 依次尝试随机 Endpoint，直到代理可用
auto_probe_endpoint() {
    local original="$WARP_ENDPOINT" ep i
    for i in 1 2 3 4 5 6; do
        ep=$(random_endpoint)
        [[ "$ep" == "$original" ]] && continue
        echo -e "${YELLOW}尝试 Endpoint: ${ep}${PLAIN}"
        apply_endpoint "$ep" || return 1
        service_restart >/dev/null 2>&1
        if wait_proxy_ready 6; then
            echo -e "${GREEN}Endpoint ${ep} 可用。${PLAIN}"
            return 0
        fi
    done

    # 全部失败时恢复原配置
    WARP_ENDPOINT="$original"
    save_settings
    generate_proxy_config
    service_restart >/dev/null 2>&1
    return 1
}

# 注册系统服务（systemd / OpenRC）
setup_service() {
    case "$INIT_SYSTEM" in
        systemd)
            cat << EOF > "$SYSTEMD_FILE"
[Unit]
Description=WireProxy WARP Socks5 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WIREPROXY_BIN} -c ${PROXY_CONF}
Restart=always
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload || return 1
            if ! systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
                echo -e "${RED}设置开机自启失败，请手动执行 systemctl enable ${SERVICE_NAME} 排查。${PLAIN}"
                return 1
            fi
            echo -e "${GREEN}systemd 服务已注册并配置为开机自启。${PLAIN}"
            ;;
        openrc)
            cat << EOF > "$INITD_FILE"
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="WireProxy WARP Socks5 Proxy"

supervisor="supervise-daemon"
command="${WIREPROXY_BIN}"
command_args="-c ${PROXY_CONF}"
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
EOF
            chmod 0755 "$INITD_FILE"
            if ! rc-update add "$SERVICE_NAME" default >/dev/null 2>&1; then
                echo -e "${RED}无法将 ${SERVICE_NAME} 加入 OpenRC 默认运行级别。${PLAIN}"
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

# 部署全局 warp 命令
install_cli() {
    local src="$0"
    if [[ "$src" == /dev/fd/* || "$src" == /proc/*/fd/* || ! -r "$src" ]]; then
        curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_warp.sh -o "$CLI_TARGET" || {
            echo -e "${RED}无法安装 warp 快捷命令，请稍后重试。${PLAIN}"
            return 1
        }
    else
        cp "$src" "$CLI_TARGET"
    fi
    chmod 0755 "$CLI_TARGET"
    echo -e "${GREEN}快捷命令 'warp' 部署完成。${PLAIN}"
}

require_installed() {
    if [[ ! -x "$WIREPROXY_BIN" || ! -f "$PROXY_CONF" ]]; then
        echo -e "${RED}尚未安装 WireProxy-WARP，请先执行安装脚本。${PLAIN}"
        return 1
    fi
    load_settings || true
    return 0
}

# 显示服务状态
check_status() {
    require_installed || return 1
    if service_is_active; then
        echo -e "运行状态: ${GREEN}运行中 (Active)${PLAIN}"
    else
        echo -e "运行状态: ${RED}未运行 (Inactive)${PLAIN}"
        echo -e "${YELLOW}提示：可运行 'warp log' 查看具体日志。${PLAIN}"
    fi
}

# 显示 WARP 详细信息
show_info() {
    require_installed || return 1

    local trace ip warp loc auth_desc listen_desc
    trace=$(get_proxy_trace | tr -d '\r')
    ip=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -n1)
    warp=$(printf '%s\n' "$trace" | sed -n 's/^warp=//p' | head -n1)
    loc=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p' | head -n1)

    if [[ -n "$SOCKS_USER" ]]; then
        auth_desc="已启用（用户名 ${SOCKS_USER}）"
    else
        auth_desc="未启用"
    fi
    if [[ "$LISTEN_ADDR" == "127.0.0.1" ]]; then
        listen_desc="仅本机"
    else
        listen_desc="对外监听"
    fi

    echo -e "${CYAN}================ WireProxy-WARP 信息 ================${PLAIN}"
    if service_is_active; then
        echo -e "服务状态    : ${GREEN}运行中${PLAIN}"
    else
        echo -e "服务状态    : ${RED}未运行${PLAIN}"
    fi
    echo -e "SOCKS5 地址 : ${GREEN}${LISTEN_ADDR}:${LISTEN_PORT}${PLAIN} (${listen_desc})"
    echo -e "SOCKS5 认证 : ${auth_desc}"
    echo -e "Endpoint    : ${WARP_ENDPOINT}"
    echo -e "MTU         : ${WARP_MTU}"
    echo -e "域名出口    : ${RESOLVE_STRATEGY}（$(describe_resolve_strategy "$RESOLVE_STRATEGY")）"
    echo -e "配置文件    : ${PROXY_CONF}"
    if [[ -n "$ip" ]]; then
        case "$warp" in
            plus) echo -e "WARP 状态   : ${GREEN}WARP+${PLAIN}" ;;
            on)   echo -e "WARP 状态   : ${GREEN}WARP${PLAIN}" ;;
            *)    echo -e "WARP 状态   : ${RED}${warp:-未知}${PLAIN}" ;;
        esac
        echo -e "出口 IP     : ${GREEN}${ip}${PLAIN}"
        [[ -n "$loc" ]] && echo -e "出口地区    : ${loc}"
    else
        echo -e "出口 IP     : ${RED}获取失败（代理不可用或服务未启动）${PLAIN}"
    fi
    echo -e "${CYAN}====================================================${PLAIN}"
}

# 代理连通性测试
test_proxy() {
    require_installed || return 1
    echo -e "${YELLOW}正在通过 SOCKS5 测试 WARP 连通性...${PLAIN}"
    local trace ip warp loc
    trace=$(get_proxy_trace | tr -d '\r')
    if [[ -z "$trace" ]]; then
        echo -e "${RED}代理不可用，请运行 'warp log' 查看日志。${PLAIN}"
        return 1
    fi
    ip=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -n1)
    warp=$(printf '%s\n' "$trace" | sed -n 's/^warp=//p' | head -n1)
    loc=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p' | head -n1)
    echo -e "出口 IP  : ${GREEN}${ip:-未知}${PLAIN}"
    echo -e "WARP     : ${GREEN}${warp:-未知}${PLAIN}"
    [[ -n "$loc" ]] && echo -e "地区     : ${loc}"
    [[ "$warp" == "on" || "$warp" == "plus" ]] || {
        echo -e "${RED}流量没有经过 WARP，请检查 Endpoint 或服务状态。${PLAIN}"
        return 1
    }
}

# 启动/停止/重启
start_service() {
    require_installed || return 1
    test_config || return 1
    if service_start && wait_proxy_ready 10; then
        echo -e "${GREEN}WireProxy-WARP 已启动。${PLAIN}"
        show_info
    else
        echo -e "${RED}启动失败，最近的日志：${PLAIN}"
        service_logs_recent
        return 1
    fi
}

stop_service() {
    require_installed || return 1
    service_stop
    echo -e "${YELLOW}WireProxy-WARP 已停止。${PLAIN}"
}

restart_service() {
    require_installed || return 1
    test_config || return 1
    if service_restart && wait_proxy_ready 10; then
        echo -e "${GREEN}WireProxy-WARP 已重启。${PLAIN}"
        show_info
    else
        echo -e "${RED}重启失败，最近的日志：${PLAIN}"
        service_logs_recent
        return 1
    fi
}

view_logs() {
    service_logs_follow
}

# 编辑配置文件
edit_config() {
    require_installed || return 1
    local editor="nano"
    command -v nano >/dev/null 2>&1 || editor="vi"
    "$editor" "$PROXY_CONF"
    echo -e "${YELLOW}正在检查配置文件语法...${PLAIN}"
    if test_config; then
        read -rp "配置正确，是否重启 WireProxy-WARP 使其生效？[y/N]: " reload_choice </dev/tty
        [[ "$reload_choice" =~ ^[Yy]$ ]] && restart_service
    else
        echo -e "${RED}配置文件存在语法错误，请手动修正！${PLAIN}"
    fi
}

# 切换 WARP 出口 IP
switch_warp_ip() {
    require_installed || return 1

    local old_ip old_endpoint new_ip ep i
    old_ip=$(get_proxy_ip)
    old_endpoint="$WARP_ENDPOINT"

    echo -e "${YELLOW}当前出口 IP: ${old_ip:-未知}${PLAIN}"
    echo -e "${YELLOW}当前 Endpoint: ${old_endpoint}${PLAIN}"

    # 第一阶段：轮换 Endpoint（不会消耗注册配额）
    for i in 1 2 3 4 5 6 7; do
        ep=$(random_endpoint)
        echo -e "${YELLOW}[Endpoint ${i}/7] 尝试 ${ep}${PLAIN}"
        apply_endpoint "$ep" || continue
        service_restart >/dev/null 2>&1
        if ! wait_proxy_ready 6; then
            echo -e "${RED}该 Endpoint 不可用，继续尝试。${PLAIN}"
            continue
        fi
        new_ip=$(get_proxy_ip)
        if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
            echo -e "${GREEN}切换成功：${old_ip:-未知} -> ${new_ip}${PLAIN}"
            show_info
            return 0
        fi
        echo -e "${YELLOW}出口 IP 未变化（${new_ip:-未知}），继续尝试。${PLAIN}"
    done

    # 第二阶段：重新注册账户后再轮换几次
    echo -e "${YELLOW}Endpoint 轮换未能改变出口 IP，尝试重新注册 WARP 账户...${PLAIN}"
    if re_register_account; then
        service_restart >/dev/null 2>&1
        if wait_proxy_ready 10; then
            new_ip=$(get_proxy_ip)
            if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
                echo -e "${GREEN}切换成功：${old_ip:-未知} -> ${new_ip}${PLAIN}"
                show_info
                return 0
            fi
        fi

        for i in 1 2 3 4; do
            ep=$(random_endpoint)
            echo -e "${YELLOW}[新账户 Endpoint ${i}/4] 尝试 ${ep}${PLAIN}"
            apply_endpoint "$ep" || continue
            service_restart >/dev/null 2>&1
            if ! wait_proxy_ready 6; then
                continue
            fi
            new_ip=$(get_proxy_ip)
            if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
                echo -e "${GREEN}切换成功：${old_ip:-未知} -> ${new_ip}${PLAIN}"
                show_info
                return 0
            fi
        done
    fi

    # 失败：恢复原 Endpoint，避免停留在不可用/较差节点
    echo -e "${YELLOW}未能获取新的出口 IP，正在恢复原 Endpoint...${PLAIN}"
    apply_endpoint "$old_endpoint" >/dev/null 2>&1
    service_restart >/dev/null 2>&1
    wait_proxy_ready 6 || true
    echo -e "${RED}切换失败，当前出口 IP: $(get_proxy_ip || echo 未知)${PLAIN}"
    echo -e "${YELLOW}说明：部分网络环境下 CloudFlare 会固定出口 IP，轮换 Endpoint 或重新注册也可能无法改变。${PLAIN}"
    return 1
}

# 更换 Endpoint
change_endpoint() {
    require_installed || return 1

    local old_endpoint input ep
    old_endpoint="$WARP_ENDPOINT"

    echo -e "当前 Endpoint: ${GREEN}${old_endpoint}${PLAIN}"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 自动随机切换（直到代理可用）"
    echo -e " ${GREEN}2.${PLAIN} 手动输入 Endpoint"
    echo -e " ${GREEN}3.${PLAIN} 恢复默认 Endpoint"
    echo ""
    read -rp "请输入选项 [1-3]: " input </dev/tty || return 1

    case "$input" in
        1)
            if auto_probe_endpoint; then
                show_info
            else
                echo -e "${RED}未找到可用 Endpoint，已恢复原配置。${PLAIN}"
                return 1
            fi
            ;;
        2)
            while true; do
                read -rp "请输入 Endpoint (host:port，例如 162.159.192.1:2408): " ep </dev/tty || return 1
                ep=$(printf '%s' "$ep" | tr -d '[:space:]')
                valid_endpoint "$ep" && break
                echo -e "${RED}Endpoint 格式无效，请重新输入。${PLAIN}"
            done
            apply_endpoint "$ep" || return 1
            if test_config && service_restart >/dev/null 2>&1 && wait_proxy_ready 8; then
                echo -e "${GREEN}Endpoint 已更新为 ${ep}${PLAIN}"
                show_info
            else
                echo -e "${RED}新 Endpoint 不可用，正在恢复原 Endpoint...${PLAIN}"
                apply_endpoint "$old_endpoint" >/dev/null 2>&1
                service_restart >/dev/null 2>&1
                wait_proxy_ready 6 || true
                return 1
            fi
            ;;
        3)
            apply_endpoint "$DEFAULT_ENDPOINT" || return 1
            if test_config && service_restart >/dev/null 2>&1 && wait_proxy_ready 8; then
                echo -e "${GREEN}已恢复默认 Endpoint: ${DEFAULT_ENDPOINT}${PLAIN}"
                show_info
            else
                echo -e "${RED}默认 Endpoint 当前不可用，正在恢复原 Endpoint...${PLAIN}"
                apply_endpoint "$old_endpoint" >/dev/null 2>&1
                service_restart >/dev/null 2>&1
                wait_proxy_ready 6 || true
                return 1
            fi
            ;;
        *)
            echo -e "${RED}输入无效。${PLAIN}"
            return 1
            ;;
    esac
}

# 修改 SOCKS5 端口
change_port() {
    require_installed || return 1

    local old_port old_addr old_user old_pass input
    old_port="$LISTEN_PORT"
    old_addr="$LISTEN_ADDR"
    old_user="$SOCKS_USER"
    old_pass="$SOCKS_PASS"

    while true; do
        read -rp "请输入新的 SOCKS5 端口 [当前 ${old_port}]（直接回车保持不变）: " input </dev/tty || input=""
        input=$(printf '%s' "$input" | tr -d '[:space:]')
        if [[ -z "$input" ]]; then
            echo -e "${YELLOW}端口未修改。${PLAIN}"
            return 0
        fi
        if ! valid_port "$input"; then
            echo -e "${RED}端口无效，请输入 1-65535 之间的数字。${PLAIN}"
            continue
        fi
        if [[ "$input" != "$old_port" ]] && port_in_use "$input"; then
            echo -e "${RED}端口 ${input} 已被占用，请更换。${PLAIN}"
            continue
        fi
        LISTEN_PORT="$input"
        break
    done

    save_settings
    generate_proxy_config || return 1
    if test_config && service_restart >/dev/null 2>&1 && wait_proxy_ready 8; then
        echo -e "${GREEN}SOCKS5 端口已修改为 ${LISTEN_PORT}。${PLAIN}"
        show_info
    else
        echo -e "${RED}新端口启动失败，正在恢复原配置...${PLAIN}"
        LISTEN_PORT="$old_port"
        LISTEN_ADDR="$old_addr"
        SOCKS_USER="$old_user"
        SOCKS_PASS="$old_pass"
        save_settings
        generate_proxy_config
        service_restart >/dev/null 2>&1
        wait_proxy_ready 6 || true
        return 1
    fi
}

# 规范化出口优先级参数
normalize_resolve_strategy() {
    local value
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        auto) echo "auto" ;;
        v4|4|ipv4) echo "ipv4" ;;
        v6|6|ipv6) echo "ipv6" ;;
        *) return 1 ;;
    esac
}

# 出口优先级说明
describe_resolve_strategy() {
    case "$1" in
        ipv4) echo "IPv4 优先" ;;
        ipv6) echo "IPv6 优先" ;;
        *) echo "双栈时优先 IPv6" ;;
    esac
}

# 设置域名出口优先级：auto / ipv4 / ipv6
change_stack() {
    require_installed || return 1

    local target="$1" input old_strategy old_ip new_ip
    old_strategy="$RESOLVE_STRATEGY"

    if [[ -z "$target" ]]; then
        echo -e "当前域名出口优先级: ${GREEN}${RESOLVE_STRATEGY}${PLAIN}（$(describe_resolve_strategy "$RESOLVE_STRATEGY")）"
        echo ""
        echo -e " ${GREEN}1.${PLAIN} auto  ${YELLOW}(默认，双栈时优先 IPv6)${PLAIN}"
        echo -e " ${GREEN}2.${PLAIN} v4    ${YELLOW}(优先使用 IPv4 出口)${PLAIN}"
        echo -e " ${GREEN}3.${PLAIN} v6    ${YELLOW}(优先使用 IPv6 出口)${PLAIN}"
        echo ""
        read -rp "请选择 [1-3]（直接回车取消）: " input </dev/tty || input=""
        case "$input" in
            1) target="auto" ;;
            2) target="v4" ;;
            3) target="v6" ;;
            "") return 0 ;;
            *)
                echo -e "${RED}输入无效。${PLAIN}"
                return 1
                ;;
        esac
    fi

    target=$(normalize_resolve_strategy "$target") || {
        echo -e "${RED}无效的出口优先级: $1（可选 auto / v4 / v6）${PLAIN}"
        return 1
    }

    if [[ "$target" == "$old_strategy" ]]; then
        echo -e "${YELLOW}当前已经是 ${target}（$(describe_resolve_strategy "$target")），无需修改。${PLAIN}"
        return 0
    fi

    old_ip=$(get_proxy_ip)

    RESOLVE_STRATEGY="$target"
    save_settings
    if ! generate_proxy_config; then
        RESOLVE_STRATEGY="$old_strategy"
        save_settings
        generate_proxy_config
        return 1
    fi

    if test_config && service_restart >/dev/null 2>&1 && wait_proxy_ready 10; then
        new_ip=$(get_proxy_ip)
        echo -e "${GREEN}出口优先级已切换为: ${target}（$(describe_resolve_strategy "$target")）${PLAIN}"
        if [[ -n "$old_ip" || -n "$new_ip" ]]; then
            echo -e "出口 IP: ${old_ip:-未知} -> ${new_ip:-未知}"
        fi
        show_info
    else
        echo -e "${RED}切换后代理不可用，正在恢复原优先级...${PLAIN}"
        RESOLVE_STRATEGY="$old_strategy"
        save_settings
        generate_proxy_config
        service_restart >/dev/null 2>&1
        wait_proxy_ready 6 || true
        return 1
    fi
}

# 绑定 WARP+ 许可证
apply_license() {
    require_installed || return 1
    if [[ ! -s "$ACCOUNT_FILE" ]]; then
        echo -e "${RED}未找到账户文件：${ACCOUNT_FILE}${PLAIN}"
        return 1
    fi

    local license tmp
    echo -e "${YELLOW}获取 WARP+ 许可证密钥的方法：${PLAIN}"
    echo -e "  电脑：1.1.1.1 客户端 → 设置 → 偏好设置 → 账户 → 复制密钥"
    echo -e "  手机：1.1.1.1 APP → 菜单 → 账户 → 复制密钥"
    echo -e "${YELLOW}请确保 1.1.1.1 客户端的账户状态已经是 WARP+。${PLAIN}"
    echo ""
    while true; do
        read -rp "请输入 WARP+ 许可证密钥 (26 个字符): " license </dev/tty || return 1
        license=$(printf '%s' "$license" | tr -d '[:space:]')
        [[ "$license" =~ ^[A-Za-z0-9]{8}-[A-Za-z0-9]{8}-[A-Za-z0-9]{8}$ ]] && break
        echo -e "${RED}密钥格式错误，请重新输入。${PLAIN}"
    done

    tmp=$(mktemp -d) || return 1
    cp "$ACCOUNT_FILE" "${tmp}/wgcf-account.toml"
    sed -i "s|^license_key[[:space:]]*=.*|license_key = \"${license}\"|" "${tmp}/wgcf-account.toml"

    service_stop
    if ! (cd "$tmp" && "$WGCF_BIN" update >"${tmp}/update.log" 2>&1); then
        tail -n 5 "${tmp}/update.log" 2>/dev/null | sed 's/^/    /'
        rm -rf "$tmp"
        echo -e "${RED}WARP+ 许可证绑定失败，当前账户保持不变。${PLAIN}"
        service_start >/dev/null 2>&1
        return 1
    fi
    if ! (cd "$tmp" && "$WGCF_BIN" generate >"${tmp}/generate.log" 2>&1) \
        || [[ ! -s "${tmp}/wgcf-profile.conf" ]]; then
        tail -n 5 "${tmp}/generate.log" 2>/dev/null | sed 's/^/    /'
        rm -rf "$tmp"
        echo -e "${RED}生成新配置失败，当前账户保持不变。${PLAIN}"
        service_start >/dev/null 2>&1
        return 1
    fi

    install -m 600 "${tmp}/wgcf-account.toml" "$ACCOUNT_FILE"
    install -m 600 "${tmp}/wgcf-profile.conf" "$PROFILE_FILE"
    rm -rf "$tmp"
    generate_proxy_config
    service_restart >/dev/null 2>&1

    if wait_proxy_ready 10; then
        if [[ "$(get_proxy_warp)" == "plus" ]]; then
            echo -e "${GREEN}WARP+ 许可证绑定成功！${PLAIN}"
        else
            echo -e "${YELLOW}许可证已提交，但当前显示仍为普通 WARP，请稍后运行 'warp info' 确认。${PLAIN}"
        fi
        show_info
    else
        echo -e "${RED}服务重启后代理不可用，请运行 'warp log' 排查。${PLAIN}"
        return 1
    fi
}

# 卸载
uninstall_all() {
    local confirm del_cfg
    read -rp "确定要完全卸载 WireProxy-WARP 吗？[y/N]: " confirm </dev/tty
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0

    service_remove

    rm -f "$WIREPROXY_BIN" "$CLI_TARGET"
    # 若系统中还存在其他 WGCF 配置，保留 wgcf 二进制
    if [[ -f /etc/wireguard/wgcf.conf || -f /etc/wireguard/wgcf-profile.conf ]]; then
        echo -e "${YELLOW}检测到其他 WGCF 配置，保留 ${WGCF_BIN}。${PLAIN}"
    else
        rm -f "$WGCF_BIN"
    fi
    rm -f "$SERVICE_LOG"

    read -rp "是否删除账户、配置与设置目录 (${CONFIG_DIR})？[y/N]: " del_cfg </dev/tty
    [[ "$del_cfg" =~ ^[Yy]$ ]] && rm -rf "$CONFIG_DIR"

    echo -e "${GREEN}WireProxy-WARP 已完全卸载。${PLAIN}"
}

# 全新安装流程
install_all() {
    install_deps
    detect_init_system
    detect_arch
    mkdir -p /usr/local/bin

    local keep=0 answer
    if [[ -s "$SETTINGS_FILE" && -s "$PROFILE_FILE" ]]; then
        echo -e "${YELLOW}检测到已安装 WireProxy-WARP。${PLAIN}"
        read -rp "是否保留现有账户和端口设置并更新程序？[Y/n]: " answer </dev/tty
        if [[ ! "$answer" =~ ^[Nn]$ ]]; then
            keep=1
            load_settings
        fi
    fi

    download_wireproxy || exit 1
    download_wgcf || exit 1

    mkdir -p "$CONFIG_DIR"

    if [[ $keep -eq 1 ]]; then
        if [[ -z "$LISTEN_PORT" ]] || ! valid_port "$LISTEN_PORT"; then
            echo -e "${YELLOW}现有设置中缺少有效端口，请重新配置。${PLAIN}"
            configure_settings || exit 1
            save_settings
        fi
        echo -e "${GREEN}已保留现有账户与设置，正在更新配置...${PLAIN}"
        generate_proxy_config || exit 1
    else
        service_remove
        rm -rf "$CONFIG_DIR"
        mkdir -p "$CONFIG_DIR"

        configure_settings || exit 1
        save_settings
        register_account || exit 1
        generate_proxy_config || exit 1
    fi

    if ! test_config; then
        echo -e "${YELLOW}默认 Endpoint 配置检查失败，尝试改用 IP Endpoint...${PLAIN}"
        WARP_ENDPOINT="162.159.192.1:2408"
        save_settings
        generate_proxy_config || exit 1
        test_config || exit 1
    fi

    setup_service || exit 1
    install_cli || exit 1

    echo -e "${YELLOW}正在启动服务并验证 WARP 连通性...${PLAIN}"
    # 使用 restart：重新安装/更新时确保旧进程加载新配置和新二进制
    service_restart >/dev/null 2>&1 || true
    if wait_proxy_ready 10; then
        echo -e "${GREEN}WireProxy-WARP 启动成功！${PLAIN}"
    else
        echo -e "${RED}默认 Endpoint 启动失败，正在尝试自动更换 Endpoint...${PLAIN}"
        if auto_probe_endpoint; then
            echo -e "${GREEN}WireProxy-WARP 启动成功！${PLAIN}"
        else
            echo -e "${RED}安装完成，但 WARP 代理未能正常连通。${PLAIN}"
            echo -e "${YELLOW}最近的日志：${PLAIN}"
            service_logs_recent
            echo -e "${YELLOW}可运行 'warp log' 查看日志，或运行 'warp endpoint' 更换 Endpoint。${PLAIN}"
            exit 1
        fi
    fi

    show_info
    echo ""
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e " 安装完成！"
    echo -e " 管理命令: ${YELLOW}warp${PLAIN}"
    echo -e " 切换出口 IP: ${YELLOW}warp ip${PLAIN}"
    echo -e " 设置出口优先级: ${YELLOW}warp stack${PLAIN}"
    echo -e " 查看信息: ${YELLOW}warp info${PLAIN}"
    echo -e " 配置文件: ${PROXY_CONF}"
    if [[ "$LISTEN_ADDR" == "0.0.0.0" ]]; then
        echo -e " ${YELLOW}注意：请放行 TCP ${LISTEN_PORT}，并限制来源 IP。${PLAIN}"
    fi
    echo -e "${GREEN}=================================================${PLAIN}"
}

# 交互主菜单
show_menu() {
    echo -e "
${GREEN}WireProxy-WARP 服务管理工具 (warp)${PLAIN}
------------------------
 1. 启动服务 (start)
 2. 停止服务 (stop)
 3. 重启服务 (restart)
 4. 查看运行状态 (status)
 5. 查看实时日志 (log)
 6. 查看 WARP 信息 / 出口 IP (info)
 7. 切换 WARP 出口 IP (ip)
 8. 更换 Endpoint (endpoint)
 9. 修改 SOCKS5 端口 (port)
10. 设置出口优先级 (stack)
11. 重新注册 WARP 账户 (reg)
12. 绑定 WARP+ 许可证 (plus)
13. 编辑配置文件 (edit)
14. 卸载 WireProxy-WARP (uninstall)
 0. 退出
------------------------"
    read -rp "请输入选项 [0-14]: " choice </dev/tty
    case "$choice" in
        1) start_service ;;
        2) stop_service ;;
        3) restart_service ;;
        4) check_status ;;
        5) view_logs ;;
        6) show_info ;;
        7) switch_warp_ip ;;
        8) change_endpoint ;;
        9) change_port ;;
        10) change_stack ;;
        11) reg_command ;;
        12) apply_license ;;
        13) edit_config ;;
        14) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac
}

# 重新注册账户命令
reg_command() {
    require_installed || return 1
    service_stop
    if re_register_account; then
        service_start >/dev/null 2>&1 || true
        if wait_proxy_ready 10; then
            echo -e "${GREEN}账户已重新注册，代理运行正常。${PLAIN}"
        else
            echo -e "${YELLOW}账户已重新注册，但代理暂未连通，正在尝试更换 Endpoint...${PLAIN}"
            auto_probe_endpoint || true
        fi
        show_info
    else
        service_start >/dev/null 2>&1 || true
        return 1
    fi
}

# 主入口分发逻辑
main() {
    case "$1" in
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) check_status ;;
        log) view_logs ;;
        info) show_info ;;
        check|configtest) require_installed && test_config ;;
        test) test_proxy ;;
        ip|change-ip|switch) switch_warp_ip ;;
        endpoint|ep) change_endpoint ;;
        port) change_port ;;
        stack) change_stack "$2" ;;
        reg|register) reg_command ;;
        plus|license) apply_license ;;
        edit) edit_config ;;
        uninstall) uninstall_all ;;
        menu) show_menu ;;
        "")
            if [[ "$(basename "$0")" == "warp" ]]; then
                show_menu
            else
                install_all
            fi
            ;;
        *)
            echo -e "${RED}未知子命令: $1${PLAIN}"
            show_menu
            ;;
    esac
}

if ! is_sourced; then
    main "$@"
fi
