#!/usr/bin/env bash
# =========================================================
# Realm 一键安装、端口转发规则管理与服务管理脚本
# 功能: 安装/更新 Realm、增删改转发规则、TCP+UDP 转发、负载均衡
# 支持 systemd (Debian/Ubuntu/CentOS 等) 与 OpenRC (Alpine 等)
# 快捷命令: 安装后输入 realm 打开管理菜单
# =========================================================

# 允许通过 sh 调用：自动切换到 bash（此处必须使用 POSIX 语法）
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "错误：本脚本需要 bash，请先执行 apk add --no-cache bash（Alpine）或安装 bash 后重试。" >&2
    exit 1
fi

# 判断当前文件是否被 source 引入（便于本地调试）
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
REALM_DIR="/etc/realm"
CONFIG_FILE="${REALM_DIR}/config.toml"
BACKUP_FILE="${CONFIG_FILE}.bak"
REALM_BIN="/usr/local/bin/realm-bin"
CLI_TARGET="/usr/local/bin/realm"
SERVICE_NAME="realm"
SYSTEMD_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INITD_FILE="/etc/init.d/${SERVICE_NAME}"
SERVICE_LOG="/var/log/realm.log"
SYSCTL_BBR_FILE="/etc/sysctl.d/99-network-bbr.conf"
LIMITS_FILE="/etc/security/limits.d/99-nofile.conf"
LOCAL_D_FILE="/etc/local.d/99-network-bbr.start"
SELF_URL="https://raw.githubusercontent.com/yuehen7/scripts/main/install_realm.sh"

# 规则解析结果（由 load_rule_blocks 填充）
HEADER_LINES=()
RULE_BLOCKS=()

set -o pipefail

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
detect_init_system

# =========================================================
# 服务控制封装，兼容 systemd 与 OpenRC
# =========================================================
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

service_configured() {
    case "$INIT_SYSTEM" in
        systemd) [[ -f "$SYSTEMD_FILE" ]] ;;
        openrc) [[ -f "$INITD_FILE" ]] ;;
        *) return 1 ;;
    esac
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
# 基础工具函数
# =========================================================
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_listen_host() {
    local host="$1"
    [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] ||
        [[ "$host" =~ ^\[[0-9A-Fa-f:]+\]$ ]] ||
        [[ "$host" =~ ^[0-9A-Fa-f:]+$ ]]
}

valid_remote_host() {
    local host="$1"
    [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$host" =~ ^\[[0-9A-Fa-f:]+\]$ ]]
}

# 把裸 IPv6 地址规范化为 [addr] 形式
normalize_host() {
    local host="$1"
    if [[ "$host" == \[*\] ]]; then
        printf '%s' "$host"
    elif [[ "$host" == *:* ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

join_host_port() {
    printf '%s:%s' "$(normalize_host "$1")" "$2"
}

# 拆分 host:port / [v6]:port，结果写入 SPLIT_HOST / SPLIT_PORT
split_host_port() {
    local addr="$1"
    SPLIT_HOST=""
    SPLIT_PORT=""
    if [[ "$addr" =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]+)$ ]]; then
        SPLIT_HOST="[${BASH_REMATCH[1]}]"
        SPLIT_PORT="${BASH_REMATCH[2]}"
    elif [[ "$addr" =~ ^(.+):([0-9]+)$ ]]; then
        SPLIT_HOST="${BASH_REMATCH[1]}"
        SPLIT_PORT="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    return 0
}

valid_balance() {
    [[ "$1" =~ ^(iphash|roundrobin)[[:space:]]*:[[:space:]]*[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*$ ]]
}

valid_through() {
    local value="$1"
    [[ "$value" =~ ^\[[0-9A-Fa-f:]+\](:[0-9]+)?$ ]] && return 0
    [[ "$value" =~ ^[0-9A-Fa-f:]+$ ]] && return 0
    if [[ "$value" =~ ^[A-Za-z0-9._-]+(:[0-9]+)?$ ]]; then
        if [[ "$value" == *:* ]]; then
            valid_port "${value##*:}" || return 1
        fi
        return 0
    fi
    return 1
}

valid_interface() {
    [[ "$1" =~ ^[A-Za-z0-9_.:-]+$ ]]
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lntu 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END{exit !found}'
        return $?
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END{exit !found}'
        return $?
    fi
    return 1
}

sanitize_name() {
    local name
    name=$(printf '%s' "$1" | tr -d '\r\n')
    name=$(trim "$name")
    printf '%s' "${name:0:60}"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) REALM_ARCH="x86_64" ;;
        aarch64|arm64) REALM_ARCH="aarch64" ;;
        armv7l|armv7|armv8l) REALM_ARCH="armv7" ;;
        armv6l|arm) REALM_ARCH="arm" ;;
        mips) REALM_ARCH="mips" ;;
        mipsel) REALM_ARCH="mipsel" ;;
        mips64) REALM_ARCH="mips64" ;;
        mips64el) REALM_ARCH="mips64el" ;;
        *)
            echo -e "${RED}不支持的 CPU 架构: ${arch}${PLAIN}" >&2
            echo -e "${YELLOW}Realm 官方未提供 riscv64 / s390x / i686 等架构的预编译包。${PLAIN}" >&2
            return 1
            ;;
    esac
    return 0
}

# 根据架构和 libc 生成 Realm Release 资源名
detect_release_asset() {
    detect_arch || return 1

    local gnu_triple musl_triple
    case "$REALM_ARCH" in
        x86_64) gnu_triple="x86_64-unknown-linux-gnu"; musl_triple="x86_64-unknown-linux-musl" ;;
        aarch64) gnu_triple="aarch64-unknown-linux-gnu"; musl_triple="aarch64-unknown-linux-musl" ;;
        armv7) gnu_triple="armv7-unknown-linux-gnueabihf"; musl_triple="armv7-unknown-linux-musleabihf" ;;
        arm) gnu_triple="arm-unknown-linux-gnueabihf"; musl_triple="arm-unknown-linux-musleabihf" ;;
        mips) gnu_triple="mips-unknown-linux-gnu"; musl_triple="mips-unknown-linux-musl" ;;
        mipsel) gnu_triple="mipsel-unknown-linux-gnu"; musl_triple="mipsel-unknown-linux-musl" ;;
        mips64) gnu_triple="mips64-unknown-linux-gnuabi64"; musl_triple="mips64-unknown-linux-muslabi64" ;;
        mips64el) gnu_triple="mips64el-unknown-linux-gnuabi64"; musl_triple="mips64el-unknown-linux-muslabi64" ;;
        *) return 1 ;;
    esac

    local is_musl=0
    if [[ -f /etc/alpine-release ]] ||
        { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
        is_musl=1
    fi

    if [[ $is_musl -eq 1 ]]; then
        RELEASE_ASSET="realm-${musl_triple}.tar.gz"
        LIBC_LABEL="musl"
        return 0
    fi

    # 默认 GNU 构建在 Ubuntu 22.04 (glibc 2.35) 上编译；
    # 2.28 ~ 2.34 使用官方 glibc2.28 兼容构建；更老的 glibc 回退到静态 musl 构建。
    local glibc_version major minor
    glibc_version=$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if [[ -n "$glibc_version" ]]; then
        major="${glibc_version%%.*}"
        minor="${glibc_version#*.}"
        if (( major > 2 || (major == 2 && minor >= 35) )); then
            RELEASE_ASSET="realm-${gnu_triple}.tar.gz"
            LIBC_LABEL="glibc ${glibc_version}"
        elif (( major > 2 || (major == 2 && minor >= 28) )); then
            RELEASE_ASSET="realm-${gnu_triple}-glibc2.28.tar.gz"
            LIBC_LABEL="glibc ${glibc_version} (glibc2.28 兼容构建)"
        else
            RELEASE_ASSET="realm-${musl_triple}.tar.gz"
            LIBC_LABEL="glibc ${glibc_version} (回退到 musl 静态构建)"
        fi
        return 0
    fi

    RELEASE_ASSET="realm-${gnu_triple}.tar.gz"
    LIBC_LABEL="glibc"
    return 0
}

# =========================================================
# 配置读取、解析与写回
# 以 config.toml 为唯一事实来源；脚本依赖 [[endpoints]] 分块
# =========================================================
load_rule_blocks() {
    HEADER_LINES=()
    RULE_BLOCKS=()

    [[ -f "$CONFIG_FILE" ]] || return 1

    local line block="" p in_rule=0
    local pending=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*\[\[endpoints\]\][[:space:]]*(#.*)?$ ]]; then
            if [[ $in_rule -eq 1 ]]; then
                RULE_BLOCKS+=("$block")
            fi
            # 紧邻 [[endpoints]] 的注释属于新规则（例如 "# rule: 名称"）
            block=""
            if [[ ${#pending[@]} -gt 0 ]]; then
                for p in "${pending[@]}"; do
                    block+="$p"$'\n'
                done
                pending=()
            fi
            block+="$line"$'\n'
            in_rule=1
        elif [[ $in_rule -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*# ]]; then
                # 先挂起，等下一行确认它属于当前规则还是下一条规则
                pending+=("$line")
            else
                if [[ ${#pending[@]} -gt 0 ]]; then
                    for p in "${pending[@]}"; do
                        block+="$p"$'\n'
                    done
                    pending=()
                fi
                block+="$line"$'\n'
            fi
        elif [[ "$line" =~ ^[[:space:]]*# ]]; then
            pending+=("$line")
        else
            if [[ ${#pending[@]} -gt 0 ]]; then
                for p in "${pending[@]}"; do
                    HEADER_LINES+=("$p")
                done
                pending=()
            fi
            # endpoints = [] 是空规则占位符，写回时按需重新生成
            if [[ "$line" =~ ^[[:space:]]*endpoints[[:space:]]*=[[:space:]]*\[\][[:space:]]*(#.*)?$ ]]; then
                continue
            fi
            HEADER_LINES+=("$line")
        fi
    done < "$CONFIG_FILE"

    if [[ ${#pending[@]} -gt 0 ]]; then
        if [[ $in_rule -eq 1 ]]; then
            for p in "${pending[@]}"; do
                block+="$p"$'\n'
            done
        else
            for p in "${pending[@]}"; do
                HEADER_LINES+=("$p")
            done
        fi
    fi
    if [[ $in_rule -eq 1 ]]; then
        RULE_BLOCKS+=("$block")
    fi
    return 0
}

strip_trailing_newlines() {
    local value="$1"
    while [[ "$value" == *$'\n' ]]; do
        value="${value%$'\n'}"
    done
    printf '%s' "$value"
}

save_rules() {
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || return 1

    # 去掉 header 末尾的空行，避免每次保存都累积空行
    local header_count=${#HEADER_LINES[@]}
    while (( header_count > 0 )); do
        local last="${HEADER_LINES[header_count-1]}"
        [[ -z "${last//[[:space:]]/}" ]] || break
        unset 'HEADER_LINES[header_count-1]'
        ((header_count--))
    done

    {
        if [[ ${#RULE_BLOCKS[@]} -eq 0 ]]; then
            printf 'endpoints = []\n\n'
        fi
        if [[ ${#HEADER_LINES[@]} -gt 0 ]]; then
            printf '%s\n' "${HEADER_LINES[@]}"
        fi
        if [[ ${#RULE_BLOCKS[@]} -gt 0 ]]; then
            printf '\n'
            local first=1 b
            for b in "${RULE_BLOCKS[@]}"; do
                [[ $first -eq 0 ]] && printf '\n'
                printf '%s\n' "$(strip_trailing_newlines "$b")"
                first=0
            done
        fi
    } > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    chmod 600 "$tmp"
    if [[ -f "$CONFIG_FILE" ]]; then
        cp -f "$CONFIG_FILE" "$BACKUP_FILE" 2>/dev/null || true
    fi
    mv -f "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    return 0
}

rule_count() {
    printf '%s' "${#RULE_BLOCKS[@]}"
}

# 读取块内形如 key = "value" 的字段
rule_field() {
    local block="$1" key="$2"
    printf '%s' "$block" |
        sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\"[[:space:]]*$/\1/p" |
        head -n1
}

# 读取块内原始值（用于 extra_remotes / balance 等）
rule_raw_value() {
    local block="$1" key="$2"
    printf '%s' "$block" |
        sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" |
        head -n1
}

rule_name() {
    local block="$1"
    printf '%s' "$block" | sed -n 's/^# rule:[[:space:]]*//p' | head -n1
}

rule_mode() {
    local block="$1"
    if printf '%s' "$block" | grep -qE '^[[:space:]]*no_tcp[[:space:]]*=[[:space:]]*true'; then
        printf 'UDP'
    elif printf '%s' "$block" | grep -qE '^[[:space:]]*use_udp[[:space:]]*=[[:space:]]*false'; then
        printf 'TCP'
    else
        printf 'TCP+UDP'
    fi
}

rule_listen_port() {
    local block="$1" listen
    listen=$(rule_field "$block" "listen")
    split_host_port "$listen" || return 1
    printf '%s' "$SPLIT_PORT"
}

build_rule_block() {
    local name="$1" listen="$2" remote="$3" mode="$4"
    local through="$5" iface="$6" extra_toml="$7" balance="$8"
    local block=""

    if [[ -n "$name" ]]; then
        block+="# rule: ${name}"$'\n'
    fi
    block+="[[endpoints]]"$'\n'
    block+="listen = \"${listen}\""$'\n'
    block+="remote = \"${remote}\""$'\n'
    if [[ -n "$extra_toml" ]]; then
        block+="extra_remotes = ${extra_toml}"$'\n'
    fi
    if [[ -n "$balance" ]]; then
        block+="balance = \"${balance}\""$'\n'
    fi
    if [[ -n "$through" ]]; then
        block+="through = \"${through}\""$'\n'
    fi
    if [[ -n "$iface" ]]; then
        block+="interface = \"${iface}\""$'\n'
    fi

    case "$mode" in
        tcp)
            block+=$'\n[endpoints.network]\nuse_udp = false\n'
            ;;
        udp)
            block+=$'\n[endpoints.network]\nno_tcp = true\n'
            ;;
    esac

    printf '%s' "$block"
}

write_base_config() {
    mkdir -p "$REALM_DIR"
    cat > "$CONFIG_FILE" << 'EOF'
# Realm 配置由 install_realm.sh / realm 菜单维护
# 建议使用 "realm list / realm add / realm edit / realm del" 管理规则
# 手动编辑后请执行 "realm check" 做结构检查

endpoints = []

[log]
level = "warn"
output = "stdout"

[network]
no_tcp = false
use_udp = true
EOF
    chmod 600 "$CONFIG_FILE"
}

# =========================================================
# 规则展示与校验
# =========================================================
list_rules() {
    load_rule_blocks || {
        echo -e "${RED}未找到配置文件：${CONFIG_FILE}${PLAIN}"
        return 1
    }

    if [[ ${#RULE_BLOCKS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}当前没有转发规则，执行 'realm add' 添加。${PLAIN}"
        return 0
    fi

    printf '%-4s %-18s %-28s %-9s %s\n' "ID" "名称" "监听 -> 落地" "模式" "备注"
    printf '%-4s %-18s %-28s %-9s %s\n' "----" "------------------" "----------------------------" "---------" "----"

    local i=0 block name listen remote mode notes
    for block in "${RULE_BLOCKS[@]}"; do
        ((i++))
        name=$(rule_name "$block")
        [[ -z "$name" ]] && name="-"
        listen=$(rule_field "$block" "listen")
        remote=$(rule_field "$block" "remote")
        mode=$(rule_mode "$block")

        notes=""
        local extra_toml through iface balance
        extra_toml=$(rule_raw_value "$block" "extra_remotes")
        through=$(rule_field "$block" "through")
        iface=$(rule_field "$block" "interface")
        balance=$(rule_field "$block" "balance")
        [[ -n "$extra_toml" ]] && notes+="extra=${extra_toml} "
        [[ -n "$balance" ]] && notes+="balance=${balance} "
        [[ -n "$through" ]] && notes+="through=${through} "
        [[ -n "$iface" ]] && notes+="if=${iface} "

        printf '%-4s %-18s %-28s %-9s %s\n' "$i" "$name" "${listen} -> ${remote}" "$mode" "$notes"
    done
}

test_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}未找到配置文件：${CONFIG_FILE}${PLAIN}"
        return 1
    fi

    echo -e "${YELLOW}正在检查 Realm 配置结构（Realm 本身没有 --test 参数）...${PLAIN}"
    load_rule_blocks || return 1

    local errors=0 i=0 seen=" " block listen remote
    for block in "${RULE_BLOCKS[@]}"; do
        ((i++))
        listen=$(rule_field "$block" "listen")
        remote=$(rule_field "$block" "remote")

        if [[ -z "$listen" ]]; then
            echo -e "${RED}规则 ${i}: 缺少 listen${PLAIN}"
            ((errors++))
        elif ! split_host_port "$listen"; then
            echo -e "${RED}规则 ${i}: listen 格式无效 -> ${listen}${PLAIN}"
            ((errors++))
        else
            if ! valid_listen_host "$SPLIT_HOST" && [[ "$SPLIT_HOST" != \[*\] ]]; then
                echo -e "${RED}规则 ${i}: 监听地址无效 -> ${SPLIT_HOST}${PLAIN}"
                ((errors++))
            fi
            if ! valid_port "$SPLIT_PORT"; then
                echo -e "${RED}规则 ${i}: 监听端口无效 -> ${SPLIT_PORT}${PLAIN}"
                ((errors++))
            elif [[ "$seen" == *" ${SPLIT_PORT} "* ]]; then
                echo -e "${RED}规则 ${i}: 监听端口 ${SPLIT_PORT} 与其他规则重复${PLAIN}"
                ((errors++))
            else
                seen+="${SPLIT_PORT} "
            fi
        fi

        if [[ -z "$remote" ]]; then
            echo -e "${RED}规则 ${i}: 缺少 remote${PLAIN}"
            ((errors++))
        elif ! split_host_port "$remote"; then
            echo -e "${RED}规则 ${i}: remote 格式无效 -> ${remote}${PLAIN}"
            ((errors++))
        else
            if ! valid_remote_host "$SPLIT_HOST" && [[ "$SPLIT_HOST" != \[*\] ]]; then
                echo -e "${RED}规则 ${i}: 落地地址无效 -> ${SPLIT_HOST}${PLAIN}"
                ((errors++))
            fi
            if ! valid_port "$SPLIT_PORT"; then
                echo -e "${RED}规则 ${i}: 落地端口无效 -> ${SPLIT_PORT}${PLAIN}"
                ((errors++))
            fi
        fi
    done

    # endpoints = [] 与 [[endpoints]] 同时存在时 TOML 会报重复键
    if grep -qE '^[[:space:]]*endpoints[[:space:]]*=[[:space:]]*\[\][[:space:]]*(#.*)?$' "$CONFIG_FILE" &&
        grep -qE '^[[:space:]]*\[\[endpoints\]\][[:space:]]*(#.*)?$' "$CONFIG_FILE"; then
        echo -e "${RED}配置错误: endpoints = [] 与 [[endpoints]] 同时存在${PLAIN}"
        ((errors++))
    fi

    if [[ $errors -gt 0 ]]; then
        echo -e "${RED}检查完成，发现 ${errors} 个问题。${PLAIN}"
        return 1
    fi

    echo -e "${GREEN}配置结构检查通过，共 ${#RULE_BLOCKS[@]} 条转发规则。${PLAIN}"
    if [[ -f "$REALM_BIN" ]]; then
        echo -e "内核版本: $("$REALM_BIN" -v 2>&1 | head -n1)"
    fi
    return 0
}

# =========================================================
# 防火墙提示与放行
# =========================================================
firewall_active() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        printf 'ufw'
        return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        printf 'firewalld'
        return 0
    fi
    return 1
}

firewall_hint() {
    local port="$1" fw
    [[ -z "$port" ]] && return 0
    if fw=$(firewall_active); then
        echo -e "${YELLOW}检测到 ${fw} 已启用，如需对外放行 ${port}/tcp 和 ${port}/udp，可执行：realm fw ${port}${PLAIN}"
    else
        echo -e "${YELLOW}请确保本机防火墙与云安全组已放行 TCP+UDP ${port} 端口。${PLAIN}"
    fi
}

firewall_open() {
    local port="$1" fw
    valid_port "$port" || {
        echo -e "${RED}端口无效：${port}${PLAIN}"
        return 1
    }
    if ! fw=$(firewall_active); then
        echo -e "${YELLOW}未检测到已启用的 ufw / firewalld。${PLAIN}"
        echo -e "请手动放行 TCP+UDP ${port}，并在云厂商安全组中放行相同端口。"
        return 1
    fi

    local ok=1
    case "$fw" in
        ufw)
            ufw allow "${port}/tcp" && ufw allow "${port}/udp" || ok=0
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${port}/tcp" &&
                firewall-cmd --permanent --add-port="${port}/udp" &&
                firewall-cmd --reload || ok=0
            ;;
    esac

    if [[ $ok -eq 1 ]]; then
        echo -e "${GREEN}已放行 TCP+UDP ${port}（${fw}）。${PLAIN}"
    else
        echo -e "${RED}放行端口失败，请手动检查 ${fw} 配置。${PLAIN}"
        return 1
    fi
    return 0
}

# =========================================================
# BBR 与网络优化
# =========================================================
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

manage_bbr() {
    echo -e "=== ${GREEN}BBR 与网络参数状态${PLAIN} ==="
    echo -e "TCP 拥塞控制算法: ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${PLAIN}"
    echo -e "默认队列规则 (qdisc): ${GREEN}$(sysctl -n net.core.default_qdisc 2>/dev/null)${PLAIN}"
    echo -e "当前文件描述符限制: ${GREEN}$(ulimit -n)${PLAIN}"

    local choice
    read -rp "是否重新应用/刷新 BBR 与高并发网络优化？[y/N]: " choice </dev/tty
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        apply_bbr_and_optimization
    fi
}

# =========================================================
# 安装依赖与下载 Realm
# =========================================================
install_deps() {
    echo -e "${YELLOW}正在检查并安装基础依赖...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y curl ca-certificates tar iproute2
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates tar iproute
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates tar iproute
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl ca-certificates tar iproute2
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y curl ca-certificates tar iproute2
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash curl ca-certificates tar iproute2 openrc
    else
        echo -e "${YELLOW}未识别的包管理器，请确保已安装 curl、ca-certificates、tar、iproute2。${PLAIN}"
    fi

    detect_init_system
}

download_realm() {
    detect_release_asset || return 1

    local url="https://github.com/zhboner/realm/releases/latest/download/${RELEASE_ASSET}"
    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1

    echo -e "${GREEN}正在下载 Realm 最新版 (${REALM_ARCH}, ${LIBC_LABEL})...${PLAIN}"
    if ! curl -fL --retry 3 --connect-timeout 15 -o "${tmp_dir}/realm.tar.gz" "$url"; then
        echo -e "${RED}下载 Realm 失败，请检查网络或代理设置。${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! tar -xzf "${tmp_dir}/realm.tar.gz" -C "$tmp_dir" || [[ ! -f "${tmp_dir}/realm" ]]; then
        echo -e "${RED}Realm 安装包无效或不包含 realm 可执行文件。${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$(dirname "$REALM_BIN")"
    local new_bin="${REALM_BIN}.new.$$"
    if ! cp -f "${tmp_dir}/realm" "$new_bin" || ! chmod 0755 "$new_bin"; then
        echo -e "${RED}安装 Realm 二进制失败：${REALM_BIN}${PLAIN}"
        rm -f "$new_bin"
        rm -rf "$tmp_dir"
        return 1
    fi
    # 先验证新二进制可执行，失败时保留旧版本
    if ! "$new_bin" -v >/dev/null 2>&1; then
        echo -e "${RED}下载的 Realm 二进制无法在本机运行（可能是架构或 libc 不匹配）。${PLAIN}"
        rm -f "$new_bin"
        rm -rf "$tmp_dir"
        return 1
    fi
    mv -f "$new_bin" "$REALM_BIN"
    rm -rf "$tmp_dir"

    echo -e "${GREEN}Realm 二进制已就绪: ${REALM_BIN}${PLAIN}"
    echo -e "版本: $("$REALM_BIN" -v 2>&1 | head -n1)"
    return 0
}

# =========================================================
# 服务注册
# =========================================================
setup_service() {
    case "$INIT_SYSTEM" in
        systemd)
            cat << EOF > "$SYSTEMD_FILE"
[Unit]
Description=Realm Relay Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=1000000
ExecStart=${REALM_BIN} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload || return 1
            systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || {
                echo -e "${RED}无法启用 realm 服务。${PLAIN}"
                return 1
            }
            echo -e "${GREEN}systemd 服务已注册并配置为开机自启。${PLAIN}"
            ;;
        openrc)
            cat << EOF > "$INITD_FILE"
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="Realm Relay Service"

supervisor="supervise-daemon"
command="${REALM_BIN}"
command_args="-c ${CONFIG_FILE}"
pidfile="/run/${SERVICE_NAME}.pid"
respawn_delay=3
respawn_max=0
output_log="${SERVICE_LOG}"
error_log="${SERVICE_LOG}"
rc_ulimit="-n 1000000"

depend() {
    need net
    after firewall
}
EOF
            chmod 0755 "$INITD_FILE"
            rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || {
                echo -e "${RED}无法将 realm 加入 OpenRC 默认运行级别。${PLAIN}"
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

fetch_cli_from_repo() {
    local tmp
    tmp=$(mktemp) || return 1
    if curl -fsSL "$SELF_URL" -o "$tmp" &&
        [[ -s "$tmp" ]] &&
        bash -n "$tmp" >/dev/null 2>&1; then
        chmod 0755 "$tmp"
        mv -f "$tmp" "$CLI_TARGET"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

install_cli() {
    # 通过快捷命令执行 "realm install" 时，$0 已经是目标文件，需从仓库重新拉取
    if [[ "$0" == "$CLI_TARGET" ]]; then
        # 已经在使用快捷命令时，更新失败不影响现有命令
        fetch_cli_from_repo ||
            echo -e "${YELLOW}无法从仓库更新 realm 命令，继续使用当前版本。${PLAIN}"
    elif [[ -f "$0" && -r "$0" ]]; then
        cp -f "$0" "$CLI_TARGET" || {
            echo -e "${RED}无法安装 realm 快捷命令。${PLAIN}"
            return 1
        }
    else
        fetch_cli_from_repo || {
            echo -e "${RED}无法安装 realm 快捷命令。${PLAIN}"
            return 1
        }
    fi
    chmod 0755 "$CLI_TARGET"
    echo -e "${GREEN}快捷管理命令 'realm' 部署完成。${PLAIN}"
}

# =========================================================
# 规则增删改
# =========================================================
require_installed() {
    if [[ ! -x "$REALM_BIN" ]]; then
        echo -e "${RED}Realm 尚未安装，请先执行 'realm install' 或重新运行安装脚本。${PLAIN}"
        return 1
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}未找到配置文件：${CONFIG_FILE}${PLAIN}"
        return 1
    fi
    return 0
}

# 将逗号分隔的额外落地地址转换为 TOML 数组，结果写入 EXTRA_TOML
build_extra_remotes() {
    local input="$1" out="" item
    local -a items=()
    EXTRA_TOML=""

    IFS=',' read -r -a items <<< "$input"
    for item in "${items[@]}"; do
        item=$(trim "$item")
        [[ -z "$item" ]] && continue
        if ! split_host_port "$item"; then
            echo -e "${RED}额外落地地址格式无效：${item}（应为 host:port）${PLAIN}" >&2
            return 1
        fi
        if ! valid_remote_host "$SPLIT_HOST" && [[ "$SPLIT_HOST" != \[*\] ]]; then
            echo -e "${RED}额外落地地址无效：${item}${PLAIN}" >&2
            return 1
        fi
        if ! valid_port "$SPLIT_PORT"; then
            echo -e "${RED}额外落地端口无效：${item}${PLAIN}" >&2
            return 1
        fi
        out+="${out:+, }\"${item}\""
    done

    [[ -n "$out" ]] && EXTRA_TOML="[${out}]"
    return 0
}

# 检查待添加端口是否已被其他规则占用
listen_port_duplicate() {
    local port="$1" exclude_index="${2:-0}" i=0 block existing
    for block in "${RULE_BLOCKS[@]}"; do
        ((i++))
        [[ $i -eq $exclude_index ]] && continue
        existing=$(rule_listen_port "$block" 2>/dev/null || true)
        [[ "$existing" == "$port" ]] && return 0
    done
    return 1
}

restart_after_change() {
    if service_configured; then
        if service_is_active; then
            service_restart >/dev/null 2>&1 && echo -e "${GREEN}Realm 服务已重启，规则已生效。${PLAIN}"
        elif [[ ${#RULE_BLOCKS[@]} -gt 0 ]]; then
            service_start >/dev/null 2>&1 && echo -e "${GREEN}Realm 服务已启动，规则已生效。${PLAIN}"
        fi
    fi
}

prompt_listen_address() {
    local default_host="$1" default_port="$2" prompt_host prompt_port
    while :; do
        if [[ -n "$default_host" ]]; then
            read -rp "本机监听地址 [${default_host}]: " prompt_host </dev/tty
            prompt_host=${prompt_host:-$default_host}
        else
            read -rp "本机监听地址 [0.0.0.0]: " prompt_host </dev/tty
            prompt_host=${prompt_host:-0.0.0.0}
        fi

        if ! valid_listen_host "$prompt_host"; then
            echo -e "${RED}监听地址无效，请输入 IPv4、IPv6 或主机名。${PLAIN}"
            continue
        fi

        while :; do
            if [[ -n "$default_port" ]]; then
                read -rp "本机监听端口 [${default_port}]: " prompt_port </dev/tty
                prompt_port=${prompt_port:-$default_port}
            else
                read -rp "本机监听端口 (1-65535): " prompt_port </dev/tty
            fi

            if ! valid_port "$prompt_port"; then
                echo -e "${RED}端口无效，请输入 1-65535。${PLAIN}"
                continue
            fi
            if [[ "$prompt_port" != "$default_port" ]] &&
                listen_port_duplicate "$prompt_port" "${3:-0}"; then
                echo -e "${RED}监听端口 ${prompt_port} 已被其他规则占用。${PLAIN}"
                continue
            fi
            if [[ "$prompt_port" != "$default_port" ]] && port_in_use "$prompt_port"; then
                echo -e "${RED}监听端口 ${prompt_port} 当前已被其他进程占用。${PLAIN}"
                continue
            fi
            break
        done

        PROMPT_LISTEN="$(join_host_port "$prompt_host" "$prompt_port")"
        return 0
    done
}

prompt_remote_address() {
    local default_host="$1" default_port="$2" prompt_host prompt_port
    while :; do
        if [[ -n "$default_host" ]]; then
            read -rp "落地地址 [${default_host}]: " prompt_host </dev/tty
            prompt_host=${prompt_host:-$default_host}
        else
            read -rp "落地地址（IP / 域名，IPv6 用 [addr] 形式）: " prompt_host </dev/tty
        fi

        if ! valid_remote_host "$prompt_host"; then
            echo -e "${RED}落地地址无效。IPv6 请使用 [2001:db8::1] 形式。${PLAIN}"
            continue
        fi

        while :; do
            if [[ -n "$default_port" ]]; then
                read -rp "落地端口 [${default_port}]: " prompt_port </dev/tty
                prompt_port=${prompt_port:-$default_port}
            else
                read -rp "落地端口 (1-65535): " prompt_port </dev/tty
            fi
            valid_port "$prompt_port" && break
            echo -e "${RED}端口无效，请输入 1-65535。${PLAIN}"
        done

        PROMPT_REMOTE="$(join_host_port "$prompt_host" "$prompt_port")"
        return 0
    done
}

# 交互收集单条规则，结果写入 NEW_RULE_BLOCK
prompt_rule_fields() {
    local default_name="$1" default_listen="$2" default_remote="$3"
    local default_mode="$4" keep_advanced="$5"
    local cur_listen_host="" cur_listen_port="" cur_remote_host="" cur_remote_port=""
    local name prompt_mode mode through iface extra_input balance
    local extra_toml="" through_val="" iface_val="" balance_val=""

    if [[ -n "$default_listen" ]] && split_host_port "$default_listen"; then
        cur_listen_host="$SPLIT_HOST"
        cur_listen_port="$SPLIT_PORT"
    fi
    if [[ -n "$default_remote" ]] && split_host_port "$default_remote"; then
        cur_remote_host="$SPLIT_HOST"
        cur_remote_port="$SPLIT_PORT"
    fi

    read -rp "规则名称（可选，例如 hy2-relay）${default_name:+ [$default_name]}: " name </dev/tty
    name=${name:-$default_name}
    name=$(sanitize_name "$name")

    prompt_listen_address "$cur_listen_host" "$cur_listen_port" "${6:-0}"
    local listen="$PROMPT_LISTEN"

    prompt_remote_address "$cur_remote_host" "$cur_remote_port"
    local remote="$PROMPT_REMOTE"

    while :; do
        echo "转发模式: 1) TCP+UDP  2) 仅 TCP  3) 仅 UDP"
        read -rp "请选择 [1-3]${default_mode:+，当前 ${default_mode}}: " prompt_mode </dev/tty
        case "${prompt_mode:-$default_mode}" in
            1|both|tcp+udp|TCP+UDP) mode="both"; break ;;
            2|tcp|TCP) mode="tcp"; break ;;
            3|udp|UDP) mode="udp"; break ;;
            "") echo -e "${RED}请选择 1、2 或 3。${PLAIN}" ;;
            *) echo -e "${RED}输入无效。${PLAIN}" ;;
        esac
    done

    local advanced="n"
    if [[ "$keep_advanced" == "1" ]]; then
        read -rp "是否重新配置高级选项（through / interface / 负载均衡）？[y/N]: " advanced </dev/tty
    else
        read -rp "是否配置高级选项（through / interface / 负载均衡）？[y/N]: " advanced </dev/tty
    fi

    if [[ "$advanced" =~ ^[Yy]$ ]]; then
        while :; do
            read -rp "固定出口 IP 或地址（through，留空跳过）: " through </dev/tty
            through=$(trim "$through")
            [[ -z "$through" ]] && break
            valid_through "$through" && break
            echo -e "${RED}through 格式无效。${PLAIN}"
        done

        while :; do
            read -rp "出口网卡（interface，例如 eth0，留空跳过）: " iface </dev/tty
            iface=$(trim "$iface")
            [[ -z "$iface" ]] && break
            valid_interface "$iface" && break
            echo -e "${RED}网卡名无效。${PLAIN}"
        done

        while :; do
            read -rp "额外落地地址，逗号分隔 host:port（留空跳过）: " extra_input </dev/tty
            extra_input=$(trim "$extra_input")
            if [[ -z "$extra_input" ]]; then
                extra_toml=""
                break
            fi
            if build_extra_remotes "$extra_input"; then
                extra_toml="$EXTRA_TOML"
                break
            fi
        done

        if [[ -n "$extra_toml" ]]; then
            while :; do
                read -rp "负载均衡策略，如 roundrobin: 1, 1（留空使用默认）: " balance </dev/tty
                balance=$(trim "$balance")
                [[ -z "$balance" ]] && break
                valid_balance "$balance" && break
                echo -e "${RED}策略格式无效，可选 iphash / roundrobin。${PLAIN}"
            done
        fi

        through_val="$through"
        iface_val="$iface"
        balance_val="$balance"
    else
        # 复用原有高级字段
        if [[ "$keep_advanced" == "1" ]]; then
            through_val=$(rule_field "$7" "through")
            iface_val=$(rule_field "$7" "interface")
            balance_val=$(rule_field "$7" "balance")
            extra_toml=$(rule_raw_value "$7" "extra_remotes")
        fi
    fi

    NEW_RULE_BLOCK=$(build_rule_block "$name" "$listen" "$remote" "$mode" \
        "$through_val" "$iface_val" "$extra_toml" "$balance_val")
    return 0
}

add_rule() {
    if ! require_installed; then
        return 1
    fi
    load_rule_blocks || return 1

    local name="" listen_port="" remote_host="" remote_port="" mode="both"

    if [[ $# -ge 3 ]]; then
        # 非交互: realm add <监听端口> <落地地址> <落地端口> [名称] [both|tcp|udp]
        listen_port="$1"
        remote_host="$2"
        remote_port="$3"
        name=$(sanitize_name "${4:-}")
        mode="${5:-both}"

        if ! valid_port "$listen_port"; then
            echo -e "${RED}监听端口无效：${listen_port}${PLAIN}"
            return 1
        fi
        if ! valid_remote_host "$remote_host"; then
            echo -e "${RED}落地地址无效：${remote_host}（IPv6 请使用 [addr] 形式）${PLAIN}"
            return 1
        fi
        if ! valid_port "$remote_port"; then
            echo -e "${RED}落地端口无效：${remote_port}${PLAIN}"
            return 1
        fi
        case "$mode" in
            both|tcp|udp|1|2|3) ;;
            *)
                echo -e "${RED}模式无效：${mode}（可选 both / tcp / udp）${PLAIN}"
                return 1
                ;;
        esac
        case "$mode" in
            1) mode="both" ;;
            2) mode="tcp" ;;
            3) mode="udp" ;;
        esac

        local listen
        listen=$(join_host_port "0.0.0.0" "$listen_port")
        local remote
        remote=$(join_host_port "$remote_host" "$remote_port")

        if listen_port_duplicate "$listen_port" 0; then
            echo -e "${RED}监听端口 ${listen_port} 已被其他规则占用。${PLAIN}"
            return 1
        fi
        if port_in_use "$listen_port"; then
            echo -e "${RED}监听端口 ${listen_port} 当前已被其他进程占用。${PLAIN}"
            return 1
        fi

        RULE_BLOCKS+=("$(build_rule_block "$name" "$listen" "$remote" "$mode" "" "" "" "")")
    else
        echo -e "${GREEN}=== 添加转发规则 ===${PLAIN}"
        prompt_rule_fields "" "" "" "" 0 0 || return 1
        RULE_BLOCKS+=("$NEW_RULE_BLOCK")
    fi

    save_rules || {
        echo -e "${RED}写入配置文件失败。${PLAIN}"
        return 1
    }

    echo -e "${GREEN}规则添加成功，当前共 ${#RULE_BLOCKS[@]} 条规则。${PLAIN}"
    restart_after_change
    local last_block="${RULE_BLOCKS[${#RULE_BLOCKS[@]}-1]}"
    firewall_hint "$(rule_listen_port "$last_block" 2>/dev/null || true)"
    return 0
}

edit_rule() {
    if ! require_installed; then
        return 1
    fi
    load_rule_blocks || return 1

    if [[ ${#RULE_BLOCKS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}当前没有可修改的规则。${PLAIN}"
        return 1
    fi

    list_rules
    local index="${1:-}" block
    if [[ -z "$index" ]]; then
        read -rp "请输入要修改的规则 ID: " index </dev/tty
    fi
    if ! [[ "$index" =~ ^[0-9]+$ ]] || (( index < 1 || index > ${#RULE_BLOCKS[@]} )); then
        echo -e "${RED}规则 ID 无效。${PLAIN}"
        return 1
    fi

    block="${RULE_BLOCKS[index-1]}"
    local cur_name cur_listen cur_remote cur_mode cur_extra cur_through cur_iface cur_balance
    cur_name=$(rule_name "$block")
    cur_listen=$(rule_field "$block" "listen")
    cur_remote=$(rule_field "$block" "remote")
    cur_mode=$(rule_mode "$block")
    cur_extra=$(rule_raw_value "$block" "extra_remotes")
    cur_through=$(rule_field "$block" "through")
    cur_iface=$(rule_field "$block" "interface")
    cur_balance=$(rule_field "$block" "balance")

    local advanced_hint
    if [[ -n "$cur_extra$cur_through$cur_iface$cur_balance" ]]; then
        advanced_hint="1"
    else
        advanced_hint="0"
    fi

    echo -e "${YELLOW}直接回车保留当前值。${PLAIN}"
    # 传入原块以便在“不重新配置高级选项”时复用字段
    prompt_rule_fields "$cur_name" "$cur_listen" "$cur_remote" "$cur_mode" "$advanced_hint" "$index" "$block" || return 1

    RULE_BLOCKS[index-1]="$NEW_RULE_BLOCK"
    save_rules || {
        echo -e "${RED}写入配置文件失败。${PLAIN}"
        return 1
    }

    echo -e "${GREEN}规则 ${index} 已更新。${PLAIN}"
    restart_after_change
    return 0
}

delete_rule() {
    if ! require_installed; then
        return 1
    fi
    load_rule_blocks || return 1

    if [[ ${#RULE_BLOCKS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}当前没有可删除的规则。${PLAIN}"
        return 1
    fi

    list_rules
    local index="${1:-}" confirm
    if [[ -z "$index" ]]; then
        read -rp "请输入要删除的规则 ID: " index </dev/tty
    fi
    if ! [[ "$index" =~ ^[0-9]+$ ]] || (( index < 1 || index > ${#RULE_BLOCKS[@]} )); then
        echo -e "${RED}规则 ID 无效。${PLAIN}"
        return 1
    fi

    if [[ ! -t 0 ]]; then
        read -rp "确认删除规则 ${index}？[y/N]: " confirm </dev/tty
    else
        read -rp "确认删除规则 ${index}？[y/N]: " confirm
    fi
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0

    local -a new_blocks=()
    local i=0 block
    for block in "${RULE_BLOCKS[@]}"; do
        ((i++))
        [[ $i -eq $index ]] && continue
        new_blocks+=("$block")
    done
    RULE_BLOCKS=("${new_blocks[@]}")

    save_rules || {
        echo -e "${RED}写入配置文件失败。${PLAIN}"
        return 1
    }

    echo -e "${GREEN}规则 ${index} 已删除。${PLAIN}"
    if [[ ${#RULE_BLOCKS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}已无转发规则，正在停止 Realm 服务。${PLAIN}"
        service_stop
    else
        restart_after_change
    fi
    return 0
}

# =========================================================
# 服务操作
# =========================================================
show_start_failure() {
    echo -e "${RED}Realm 启动失败。以下是最近的日志：${PLAIN}"
    service_logs_recent
    echo -e "${YELLOW}可依次执行：realm check、realm log、ss -lntu | grep -E ':(<监听端口>)'${PLAIN}"
}

start_service() {
    require_installed || return 1
    load_rule_blocks || return 1

    if [[ ${#RULE_BLOCKS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}当前没有转发规则，Realm 不会保持运行。请先执行 'realm add'。${PLAIN}"
        return 1
    fi

    if service_start; then
        echo -e "${GREEN}Realm 服务已启动。${PLAIN}"
        check_status
    else
        show_start_failure
        return 1
    fi
}

stop_service() {
    if service_stop; then
        echo -e "${YELLOW}Realm 服务已停止。${PLAIN}"
    else
        echo -e "${YELLOW}未检测到可用的服务管理器。${PLAIN}"
    fi
}

restart_service() {
    require_installed || return 1
    load_rule_blocks || return 1

    if [[ ${#RULE_BLOCKS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}当前没有转发规则，已停止 Realm 服务。${PLAIN}"
        service_stop
        return 1
    fi

    if service_restart; then
        echo -e "${GREEN}Realm 服务已重启。${PLAIN}"
        check_status
    else
        show_start_failure
        return 1
    fi
}

check_status() {
    if [[ ! -x "$REALM_BIN" ]]; then
        echo -e "运行状态: ${RED}未安装${PLAIN}"
        return 1
    fi

    echo -e "内核版本: ${GREEN}$("$REALM_BIN" -v 2>&1 | head -n1)${PLAIN}"
    if service_is_active; then
        echo -e "运行状态: ${GREEN}运行中 (Active)${PLAIN}"
    else
        echo -e "运行状态: ${RED}未运行 (Inactive)${PLAIN}"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        load_rule_blocks
        echo -e "转发规则: ${GREEN}${#RULE_BLOCKS[@]}${PLAIN} 条"
        echo -e "配置文件: ${CONFIG_FILE}"
    fi
}

view_logs() {
    service_logs_follow
}

view_info() {
    require_installed || return 1
    check_status
    echo ""
    list_rules
    echo ""
    echo -e "${CYAN}修改规则后会自动重启服务；手动编辑配置后执行 'realm restart'。${PLAIN}"
}

edit_config() {
    require_installed || return 1
    local editor="nano"
    command -v nano >/dev/null 2>&1 || editor="vi"
    $editor "$CONFIG_FILE"
    echo -e "${YELLOW}正在做配置结构检查...${PLAIN}"
    if test_config; then
        local choice
        read -rp "是否重启 Realm 使配置生效？[y/N]: " choice </dev/tty
        [[ "$choice" =~ ^[Yy]$ ]] && restart_service
    else
        echo -e "${RED}配置存在结构问题，请修正后再重启。${PLAIN}"
    fi
}

update_realm() {
    require_installed || return 1
    local old_version
    old_version=$("$REALM_BIN" -v 2>&1 | head -n1)

    download_realm || return 1

    local new_version
    new_version=$("$REALM_BIN" -v 2>&1 | head -n1)
    echo -e "版本变化: ${YELLOW}${old_version}${PLAIN} -> ${GREEN}${new_version}${PLAIN}"

    if service_configured; then
        load_rule_blocks
        if [[ ${#RULE_BLOCKS[@]} -gt 0 ]]; then
            service_restart >/dev/null 2>&1 && echo -e "${GREEN}服务已重启。${PLAIN}"
        fi
    fi
    return 0
}

# =========================================================
# 安装与卸载
# =========================================================
is_installed() {
    [[ -x "$REALM_BIN" ]]
}

install_all() {
    install_deps || return 1
    detect_init_system

    mkdir -p "$REALM_DIR"

    local had_install=0
    if is_installed || [[ -f "$CONFIG_FILE" ]]; then
        had_install=1
    fi

    # 先下载并验证新内核，避免下载失败时已经重置了现有配置
    download_realm || return 1
    apply_bbr_and_optimization

    local keep=0
    if [[ $had_install -eq 1 ]]; then
        echo -e "${YELLOW}检测到已安装 Realm 或已有配置。${PLAIN}"
        local answer
        read -rp "是否保留现有转发规则并只更新内核？[Y/n]: " answer </dev/tty
        if [[ ! "$answer" =~ ^[Nn]$ ]]; then
            keep=1
        else
            if [[ -f "$CONFIG_FILE" ]]; then
                cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
                echo -e "${YELLOW}已备份原配置，将重新生成基础配置。${PLAIN}"
            fi
            write_base_config
        fi
    else
        write_base_config
    fi

    # 二进制存在但配置文件被删除时，补一份基础配置
    if [[ ! -f "$CONFIG_FILE" ]]; then
        write_base_config
    fi

    setup_service || return 1
    install_cli || return 1

    load_rule_blocks || true

    if [[ $keep -eq 0 ]]; then
        local add_choice
        read -rp "是否现在添加第一条转发规则？[Y/n]: " add_choice </dev/tty
        if [[ ! "$add_choice" =~ ^[Nn]$ ]]; then
            add_rule || true
            load_rule_blocks || true
        fi
    fi

    if [[ ${#RULE_BLOCKS[@]} -gt 0 ]]; then
        if service_is_active; then
            service_restart >/dev/null 2>&1 || true
        else
            service_start >/dev/null 2>&1 || true
        fi

        if service_is_active; then
            echo -e "${GREEN}Realm 服务运行正常。${PLAIN}"
        else
            echo -e "${RED}Realm 已安装，但服务未能启动；请执行 'realm check' 和 'realm log' 排查。${PLAIN}"
        fi
    else
        # 重装时选择了不保留规则，或用户暂未添加规则：停掉可能仍在运行的旧服务
        service_stop >/dev/null 2>&1 || true
        echo -e "${YELLOW}当前没有转发规则，服务暂未启动。执行 'realm add' 添加规则后会自动启动。${PLAIN}"
    fi

    echo ""
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e " Realm 安装完成！"
    echo -e " 管理命令:   ${YELLOW}realm${PLAIN}"
    echo -e " 查看规则:   ${YELLOW}realm list${PLAIN}"
    echo -e " 添加规则:   ${YELLOW}realm add${PLAIN}"
    echo -e " 配置文件:   ${CONFIG_FILE}"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        echo -e " 服务日志:   ${YELLOW}realm log${PLAIN} (journalctl -u realm)"
    else
        echo -e " 服务日志:   ${YELLOW}realm log${PLAIN} (${SERVICE_LOG})"
    fi
    echo -e " 放行端口:   ${YELLOW}realm fw <端口>${PLAIN}（支持 ufw / firewalld）"
    echo -e "${GREEN}=================================================${PLAIN}"
}

uninstall_all() {
    local confirm
    read -rp "确定要完全卸载 Realm 吗？[y/N]: " confirm </dev/tty
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0

    service_remove

    rm -f "$REALM_BIN" "$CLI_TARGET" "$SERVICE_LOG"

    local del_cfg
    read -rp "是否删除配置与备份目录 (${REALM_DIR})？[y/N]: " del_cfg </dev/tty
    [[ "$del_cfg" =~ ^[Yy]$ ]] && rm -rf "$REALM_DIR"

    local del_bbr
    read -rp "是否删除 BBR 与网络优化配置文件？（若其他脚本也在使用请选 N）[y/N]: " del_bbr </dev/tty
    if [[ "$del_bbr" =~ ^[Yy]$ ]]; then
        rm -f "$SYSCTL_BBR_FILE" "$LIMITS_FILE" "$LOCAL_D_FILE"
        reload_sysctl
        echo -e "${YELLOW}BBR 与网络配置文件已移除。${PLAIN}"
    fi

    echo -e "${GREEN}Realm 及快捷管理命令已完全卸载。${PLAIN}"
}

# =========================================================
# 菜单与命令分发
# =========================================================
show_menu() {
    echo -e "
${GREEN}Realm 端口转发管理工具 (realm)${PLAIN}
------------------------
 1. 启动服务 (start)
 2. 停止服务 (stop)
 3. 重启服务 (restart)
 4. 查看运行状态 (status)
 5. 查看实时日志 (log)
 6. 查看转发规则 (list)
 7. 添加转发规则 (add)
 8. 修改转发规则 (edit)
 9. 删除转发规则 (del)
10. 检查配置结构 (check)
11. 编辑配置文件 (config)
12. 更新 Realm 内核 (update)
13. BBR 状态与网络调优 (bbr)
14. 放行防火墙端口 (fw)
15. 卸载 Realm (uninstall)
 0. 退出
------------------------"
    read -rp "请输入选项 [0-15]: " choice </dev/tty
    case "$choice" in
        1) start_service ;;
        2) stop_service ;;
        3) restart_service ;;
        4) check_status ;;
        5) view_logs ;;
        6) list_rules ;;
        7) add_rule ;;
        8) edit_rule ;;
        9) delete_rule ;;
        10) test_config ;;
        11) edit_config ;;
        12) update_realm ;;
        13) manage_bbr ;;
        14)
            read -rp "请输入要放行的端口: " fw_port </dev/tty
            firewall_open "$fw_port"
            ;;
        15) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac
}

show_help() {
    cat << 'EOF'
Realm 端口转发管理工具

用法:
  realm                    打开交互菜单
  realm install            安装/更新 Realm（保留现有规则）
  realm start|stop|restart 服务控制
  realm status             查看运行状态
  realm info               查看运行状态与转发规则
  realm log                查看实时日志
  realm list               查看转发规则
  realm add                交互添加规则
  realm add <监听端口> <落地地址> <落地端口> [名称] [both|tcp|udp]
                           非交互添加规则
  realm edit [ID]          修改规则
  realm del [ID]           删除规则
  realm check              检查配置结构
  realm config             编辑配置文件
  realm update             更新 Realm 内核到最新版
  realm bbr                查看/重新应用 BBR 优化
  realm fw <端口>          用 ufw / firewalld 放行 TCP+UDP 端口
  realm uninstall          完全卸载
  realm help               显示本帮助

示例:
  realm add 6666 1.2.3.4 443 hy2-relay
  realm add 8443 "[2001:db8::1]" 443 hy2-relay udp
  realm del 2

说明:
  - 规则保存在 /etc/realm/config.toml，脚本依赖 [[endpoints]] 分块管理。
  - 默认全局开启 TCP+UDP 转发；单条规则可选择仅 TCP 或仅 UDP。
  - Realm 没有 --test 参数，realm check 只做配置结构检查。
  - 修改规则后脚本会自动重启服务；手动编辑配置后请执行 realm restart。
EOF
}

main() {
    case "$1" in
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) check_status ;;
        log) view_logs ;;
        info) view_info ;;
        list|ls) list_rules ;;
        add) shift; add_rule "$@" ;;
        edit) shift; edit_rule "$@" ;;
        del|delete|remove|rm) shift; delete_rule "$@" ;;
        check|test) test_config ;;
        config|edit-config) edit_config ;;
        update|upgrade) update_realm ;;
        install|reinstall) install_all ;;
        bbr) manage_bbr ;;
        fw|firewall) shift; firewall_open "${1:-}" ;;
        uninstall) uninstall_all ;;
        menu) show_menu ;;
        help|-h|--help) show_help ;;
        "")
            if [[ "$(basename "$0")" == "realm" && -x "$REALM_BIN" ]]; then
                show_menu
            else
                install_all
            fi
            ;;
        *)
            echo -e "${RED}未知子命令: $1${PLAIN}"
            show_help
            ;;
    esac
}

if ! is_sourced; then
    main "$@"
fi
