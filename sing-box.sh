#!/bin/bash
# sing-box 一键安装脚本
# Author: yuehen7

plain='\033[0m'
red='\033[0;31m'
blue='\033[1;34m'
pink='\033[1;35m'
green='\033[0;32m'
yellow='\033[0;33m'

#os
OS_RELEASE=''

#arch
OS_ARCH=''

#sing-box version
SING_BOX_VERSION=''

#script version
SING_BOX_YES_VERSION='1.0.1'

#package download path
DOWNLAOD_PATH='/usr/local/sing-box'

#scritp install path
SCRIPT_FILE_PATH='/usr/local/sbin/sing-box'

#config install path
CONFIG_FILE_PATH='/usr/local/etc/sing-box'

#binary install path
BINARY_FILE_PATH='/usr/local/bin/sing-box'

#service install path
SERVICE_FILE_PATH='/etc/systemd/system/sing-box.service'

#log file save path
DEFAULT_LOG_FILE_SAVE_PATH='/usr/local/sing-box/sing-box.log'

#sing-box status define
declare -r SING_BOX_STATUS_RUNNING=1
declare -r SING_BOX_STATUS_NOT_RUNNING=0
declare -r SING_BOX_STATUS_NOT_INSTALL=255

#log file size which will trigger log clear
#here we set it as 25M
declare -r DEFAULT_LOG_FILE_DELETE_TRIGGER=25

#utils
function LOGE() {
  echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
  echo -e "${green}[INF] $* ${plain}"
}

function LOGD() {
  echo -e "${yellow}[DEG] $* ${plain}"
}

confirm() {
  if [[ $# > 1 ]]; then
    echo && read -p "$1 [默认$2]: " temp
    if [[ x"${temp}" == x"" ]]; then
      temp=$2
    fi
  else
    read -p "$1 [y/n]: " temp
  fi
  
  if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
    return 0
  else
    return 1
  fi
}

[[ $EUID -ne 0 ]] && LOGE "请使用root用户运行该脚本" && exit 1

os_check() {
  LOGI "检测当前系统中..."
  if [[ -f /etc/redhat-release ]]; then
    OS_RELEASE="centos"
  elif cat /etc/issue | grep -Eqi "debian"; then
    OS_RELEASE="debian"
  elif cat /etc/issue | grep -Eqi "ubuntu"; then
    OS_RELEASE="ubuntu"
  elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    OS_RELEASE="centos"
  elif cat /proc/version | grep -Eqi "debian"; then
    OS_RELEASE="debian"
  elif cat /proc/version | grep -Eqi "ubuntu"; then
    OS_RELEASE="ubuntu"
  elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    OS_RELEASE="centos"
  else
    LOGE "系统检测错误,请联系脚本作者!" && exit 1
  fi
  LOGI "系统检测完毕,当前系统为:${OS_RELEASE}"
}

arch_check() {
  LOGI "检测当前系统架构中..."
  OS_ARCH=$(arch)
  LOGI "当前系统架构为 ${OS_ARCH}"
  if [[ ${OS_ARCH} == "x86_64" || ${OS_ARCH} == "x64" || ${OS_ARCH} == "amd64" ]]; then
    OS_ARCH="amd64"
  elif [[ ${OS_ARCH} == "aarch64" || ${OS_ARCH} == "arm64" ]]; then
    OS_ARCH="arm64"
  else
    OS_ARCH="amd64"
    LOGE "检测系统架构失败，使用默认架构: ${OS_ARCH}"
  fi
  LOGI "系统架构检测完毕,当前系统架构为:${OS_ARCH}"
}

status_check() {
  if [[ ! -f "${SERVICE_FILE_PATH}" ]]; then
    return ${SING_BOX_STATUS_NOT_INSTALL}
  fi
  temp=$(systemctl status sing-box | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
  if [[ x"${temp}" == x"running" ]]; then
    return ${SING_BOX_STATUS_RUNNING}
  else
    return ${SING_BOX_STATUS_NOT_RUNNING}
  fi
}

config_check() {
  if [[ ! -f "${CONFIG_FILE_PATH}/config.json" ]]; then
    LOGE "${CONFIG_FILE_PATH}/config.json 不存在,配置检查失败"
    return
  else
    info=$(${BINARY_FILE_PATH} check -c ${CONFIG_FILE_PATH}/config.json)
    if [[ $? -ne 0 ]]; then
      LOGE "配置检查失败,请查看日志"
    else
      LOGI "恭喜:配置检查通过"
    fi
  fi
}

set_as_entrance() {
  sh_new_ver=$(wget --no-check-certificate -qO- -t1 -T3 "https://raw.githubusercontent.com/yuehen7/scripts/main/sing-box.sh"|grep 'SING_BOX_YES_VERSION="'|awk -F "=" '{print $NF}'|sed 's/\"//g'|head -1) && sh_new_type="github"
  if [[ ! -f "${SCRIPT_FILE_PATH}" || ! ${sh_new_ver} == ${SING_BOX_YES_VERSION} ]]; then
    wget --no-check-certificate -O ${SCRIPT_FILE_PATH} https://raw.githubusercontent.com/yuehen7/scripts/main/sing-box.sh
    chmod +x ${SCRIPT_FILE_PATH}
  fi
}

show_status() {
  status_check
  case $? in
  0)
    show_sing_box_version
    echo -e "[INF] sing-box状态: ${yellow}未运行${plain}"
    show_enable_status
    LOGI "配置文件路径:${CONFIG_FILE_PATH}/config.json"
    LOGI "可执行文件路径:${BINARY_FILE_PATH}"
    ;;
  1)
    show_sing_box_version
    echo -e "[INF] sing-box状态: ${green}已运行${plain}"
    show_enable_status
    show_running_status
    LOGI "配置文件路径:${CONFIG_FILE_PATH}/config.json"
    LOGI "可执行文件路径:${BINARY_FILE_PATH}"
    ;;
  255)
    echo -e "[INF] sing-box状态: ${red}未安装${plain}"
    ;;
  esac
}

show_running_status() {
  status_check
  if [[ $? == ${SING_BOX_STATUS_RUNNING} ]]; then
    local pid=$(pidof sing-box)
    local runTime=$(systemctl status sing-box | grep Active | awk '{for (i=5;i<=NF;i++)printf("%s ", $i);print ""}')
    local memCheck=$(cat /proc/${pid}/status | grep -i vmrss | awk '{print $2,$3}')
    LOGI "#####################"
    LOGI "进程ID:${pid}"
    LOGI "运行时长：${runTime}"
    LOGI "内存占用:${memCheck}"
    LOGI "#####################"
  else
    LOGE "sing-box未运行"
  fi
}

show_sing_box_version() {
  LOGI "版本信息:$(${BINARY_FILE_PATH} version)"
}

show_enable_status() {
  local temp=$(systemctl is-enabled sing-box)
  if [[ x"${temp}" == x"enabled" ]]; then
    echo -e "[INF] sing-box是否开机自启: ${green}是${plain}"
  else
    echo -e "[INF] sing-box是否开机自启: ${red}否${plain}"
  fi
}

create_or_delete_path() {
  if [[ $# -ne 1 ]]; then
    LOGE "invalid input,should be one paremete,and can be 0 or 1"
    exit 1
  fi
  if [[ "$1" == "1" ]]; then
    LOGI "Will create ${DOWNLAOD_PATH} and ${CONFIG_FILE_PATH} for sing-box..."
    rm -rf ${DOWNLAOD_PATH} ${CONFIG_FILE_PATH}
    mkdir -p ${DOWNLAOD_PATH} ${CONFIG_FILE_PATH}
    if [[ $? -ne 0 ]]; then
      LOGE "create ${DOWNLAOD_PATH} and ${CONFIG_FILE_PATH} for sing-box failed"
      exit 1
    else
      LOGI "create ${DOWNLAOD_PATH} adn ${CONFIG_FILE_PATH} for sing-box success"
    fi
  elif [[ "$1" == "0" ]]; then
    LOGI "Will delete ${DOWNLAOD_PATH} and ${CONFIG_FILE_PATH}..."
    rm -rf ${DOWNLAOD_PATH} ${CONFIG_FILE_PATH}
    if [[ $? -ne 0 ]]; then
      LOGE "delete ${DOWNLAOD_PATH} and ${CONFIG_FILE_PATH} failed"
      exit 1
    else
      LOGI "delete ${DOWNLAOD_PATH} and ${CONFIG_FILE_PATH} success"
    fi
  fi
}

install_base() {
  if [[ ${OS_RELEASE} == "ubuntu" || ${OS_RELEASE} == "debian" ]]; then
    apt clean all
    apt update -y
    apt install wget tar unzip vim gcc openssl -y
    apt install net-tools -y 
    apt install libssl-dev g++ -y
  elif [[ ${OS_RELEASE} == "centos" ]]; then
    yum install wget tar unzip vim gcc openssl -y
    yum install net-tools -y 
  fi

  res=`which unzip 2>/dev/null`
  if [[ $? -ne 0 ]]; then
    LOGE " unzip安装失败，请检查网络${plain}"
    exit 1
  fi
}

download_sing-box() {
  LOGD "开始下载sing-box..."
  os_check && arch_check && install_base

  local SING_BOX_VERSION_TEMP=$(curl -Ls "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  SING_BOX_VERSION=${SING_BOX_VERSION_TEMP:1}

  LOGI "将选择使用版本:${SING_BOX_VERSION}"
  local DOWANLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SING_BOX_VERSION_TEMP}/sing-box-${SING_BOX_VERSION}-linux-${OS_ARCH}.tar.gz"

  #here we need create directory for sing-box
  create_or_delete_path 1
  wget -N --no-check-certificate -O ${DOWNLAOD_PATH}/sing-box-${SING_BOX_VERSION}-linux-${OS_ARCH}.tar.gz ${DOWANLOAD_URL}

  if [[ $? -ne 0 ]]; then
    LOGE "Download sing-box failed,plz be sure that your network work properly and can access github"
    create_or_delete_path 0
    exit 1
  else
    LOGI "下载sing-box成功"
  fi
}

install_sing-box() {
  set_as_entrance
  LOGD "开始安装sing-box..."
  if [[ $# -ne 0 ]]; then
    download_sing-box $1
  else
    download_sing-box
  fi

  config_sing-box
  setFirewall

  if [[ ! -f "${DOWNLAOD_PATH}/sing-box-${SING_BOX_VERSION}-linux-${OS_ARCH}.tar.gz" ]]; then
    clear_sing_box
    LOGE "could not find sing-box packages,plz check dowanload sing-box whether suceess"
    exit 1
  fi
  cd ${DOWNLAOD_PATH}

  tar -xvf sing-box-${SING_BOX_VERSION}-linux-${OS_ARCH}.tar.gz && cd sing-box-${SING_BOX_VERSION}-linux-${OS_ARCH}

  if [[ $? -ne 0 ]]; then
    clear_sing_box
    OGE "解压sing-box安装包失败,脚本退出"
    exit 1
  else
    LOGI "解压sing-box安装包成功"
  fi

  install -m 755 sing-box ${BINARY_FILE_PATH}

  if [[ $? -ne 0 ]]; then
    LOGE "install sing-box failed,exit"
    exit 1
  else
    LOGI "install sing-box suceess"
  fi
  install_systemd_service && enable_sing-box && start_sing-box
  LOGI "安装sing-box成功,已启动成功"
}

update_sing-box() {
  LOGD "开始更新sing-box..."
  if [[ ! -f "${SERVICE_FILE_PATH}" ]]; then
    LOGE "system did not install sing-box,please install it firstly"
    show_menu
  fi
  download_sing-box && install_sing-box
  if ! systemctl restart sing-box; then
    LOGE "update sing-box failed,please check logs"
    show_menu
  else
    LOGI "update sing-box success"
  fi
}

clear_sing_box() {
  LOGD "开始清除sing-box..."
  create_or_delete_path 0 && rm -rf ${SERVICE_FILE_PATH} && rm -rf ${BINARY_FILE_PATH} && rm -rf ${SCRIPT_FILE_PATH}
  LOGD "清除sing-box完毕"
}

uninstall_sing-box() {
  echo ""
  line1=`grep -n 'inbounds' ${CONFIG_FILE_PATH}/config.json  | head -n1 | cut -d: -f1`
  line11=`expr $line1 + 2`
  local type=`sed -n "${line11}p" ${CONFIG_FILE_PATH}/config.json | cut -d: -f2 | tr -d \",' '`
  if [[ ${type} == "trojan" ]]; then
    LOGI "配置类型为trojan，开始卸载nginx..."
    systemctl stop nginx
    systemctl disable nginx
    if [[ ${OS_RELEASE} == "ubuntu" || ${OS_RELEASE} == "debian" ]]; then
      apt remove nginx
      apt remove nginx-common
    elif [[ ${OS_RELEASE} == "centos" ]]; then
      yum remove nginx
    fi
    rm -rf /etc/nginx
    rm -rf /usr/share/nginx
    ~/.acme.sh/acme.sh --uninstall
    rm -rf ~/.acme.sh
    LOGI "nginx及acme.sh卸载完成."
  fi

  LOGD "开始卸载sing-box..."
  pidOfsing_box=$(pidof sing-box)
  if [ -n ${pidOfsing_box} ]; then
        stop_sing-box
  fi
  clear_sing_box

  if [ $? -ne 0 ]; then
    LOGE "卸载sing-box失败,请检查日志"
    exit 1
  else
    LOGI "卸载sing-box成功"
  fi
}

install_systemd_service() {
  LOGD "开始安装sing-box systemd服务..."
  if [ -f "${SERVICE_FILE_PATH}" ]; then
    rm -rf ${SERVICE_FILE_PATH}
  fi
  #create service file
  touch ${SERVICE_FILE_PATH}
  if [ $? -ne 0 ]; then
    LOGE "create service file failed,exit"
    exit 1
  else
    LOGI "create service file success..."
  fi
  cat >${SERVICE_FILE_PATH} <<EOF
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target
Wants=network.target
[Service]
Type=simple
ExecStart=${BINARY_FILE_PATH} run -c ${CONFIG_FILE_PATH}/config.json
Restart=on-failure
RestartSec=30s
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF
  chmod 644 ${SERVICE_FILE_PATH}
  systemctl daemon-reload
  LOGD "安装sing-box systemd服务成功"
}

start_sing-box() {
  if [ -f "${SERVICE_FILE_PATH}" ]; then
    systemctl start sing-box
    sleep 1s
    status_check
    if [ $? == ${SING_BOX_STATUS_NOT_RUNNING} ]; then
      LOGE "start sing-box service failed,exit"
      exit 1
    elif [ $? == ${SING_BOX_STATUS_RUNNING} ]; then
      LOGI "start sing-box service success"
    fi
  else
    LOGE "${SERVICE_FILE_PATH} does not exist,can not start service"
    exit 1
  fi
}

#restart sing-box
restart_sing-box() {
  if [ -f "${SERVICE_FILE_PATH}" ]; then
    systemctl restart sing-box
    sleep 1s
    status_check
    if [ $? == 0 ]; then
      LOGE "restart sing-box service failed,exit"
      exit 1
    elif [ $? == 1 ]; then
      LOGI "restart sing-box service success"
    fi
  else
    LOGE "${SERVICE_FILE_PATH} does not exist,can not restart service"
    exit 1
  fi
}

#stop sing-box
stop_sing-box() {
  LOGD "开始停止sing-box服务..."
  status_check
  if [ $? == ${SING_BOX_STATUS_NOT_INSTALL} ]; then
    LOGE "sing-box did not install,can not stop it"
    exit 1
  elif [ $? == ${SING_BOX_STATUS_NOT_RUNNING} ]; then
    LOGI "sing-box already stoped,no need to stop it again"
    exit 1
  elif [ $? == ${SING_BOX_STATUS_RUNNING} ]; then
    if ! systemctl stop sing-box; then
      LOGE "stop sing-box service failed,plz check logs"
      exit 1
    fi
  fi
  LOGD "停止sing-box服务成功"
}

#enable sing-box will set sing-box auto start on system boot
enable_sing-box() {
  systemctl enable sing-box
  if [[ $? == 0 ]]; then
    LOGI "设置sing-box开机自启成功"
  else
    LOGE "设置sing-box开机自启失败"
  fi
}

#disable sing-box
disable_sing-box() {
  systemctl disable sing-box
  if [[ $? == 0 ]]; then
    LOGI "取消sing-box开机自启成功"
  else
    LOGE "取消sing-box开机自启失败"
  fi
}

#show logs
show_log() {
  confirm "确认是否已在配置中开启日志记录,默认开启" "y"
  if [[ $? -ne 0 ]]; then
    LOGI "将从console中读取日志:"
    journalctl -u sing-box.service -e --no-pager -f
  else
    local tempLog=''
    read -p "将从日志文件中读取日志,请输入日志文件路径,直接回车将使用默认路径": tempLog
    if [[ -n ${tempLog} ]]; then
      LOGI "日志文件路径:${tempLog}"
      if [[ -f ${tempLog} ]]; then
        tail -f ${tempLog} -s 3
      else
        LOGE "${tempLog}不存在,请确认配置"
      fi
    else
      LOGI "日志文件路径:${DEFAULT_LOG_FILE_SAVE_PATH}"
      tail -f ${DEFAULT_LOG_FILE_SAVE_PATH} -s 3
    fi
  fi
}

#clear log,the paremter is log file path
clear_log() {
  local filePath=''
  if [[ $# -gt 0 ]]; then
    filePath=$1
  else
    read -p "请输入日志文件路径": filePath
    if [[ ! -n ${filePath} ]]; then
      LOGI "输入的日志文件路径无效,将使用默认的文件路径"
      filePath=${DEFAULT_LOG_FILE_SAVE_PATH}
    fi
  fi
  LOGI "日志路径为:${filePath}"
  if [[ ! -f ${filePath} ]]; then
    LOGE "清除sing-box 日志文件失败,${filePath}不存在,请确认"
    exit 1
  fi
  fileSize=$(ls -la ${filePath} --block-size=M | awk '{print $5}' | awk -F 'M' '{print$1}')
  if [[ ${fileSize} -gt ${DEFAULT_LOG_FILE_DELETE_TRIGGER} ]]; then
    rm $1 && systemctl restart sing-box
    if [[ $? -ne 0 ]]; then
      LOGE "清除sing-box 日志文件失败"
    else
      LOGI "清除sing-box 日志文件成功"
    fi
  else
    LOGI "当前日志大小为${fileSize}M,小于${DEFAULT_LOG_FILE_DELETE_TRIGGER}M,将不会清除"
  fi
}

config_Shadowsocks(){
  echo ""
  read -p " 请输入Shadowsocks端口[100-65535的一个数字，默认54321]：" port
  [[ -z "${port}" ]] && port=54321
  if [[ "${port:0:1}" = "0" ]]; then
    LOGE "端口不能以0开头"
    exit 1
  fi
  LOGI "  Shadowsocks端口：$port"

  echo ""
  echo "数据加密方式："
  echo -e " ${red}1. 2022-blake3-aes-128-gcm${plain}"
  echo -e " ${red}2. chacha20-ietf-poly1305${plain}"      
  echo ""
  
  read -p "请加密类型，默认为1：" method_type
  [[ -z "${method_type}" ]] && method_type=1

  case $method_type in
  1)
    method="2022-blake3-aes-128-gcm"
    password=`openssl rand -base64 16`
    ;;
  2)
    method="chacha20-ietf-poly1305"
    password=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1`
    ;;
  *)
    LOGE " 请输入正确的选项！"
    exit 1
  esac

  LOGI "加密类型：$method"
  LOGI "密码：$password"

  echo ""
  LOGD "开始配置config.json..."
  cat > ${CONFIG_FILE_PATH}/config.json <<-EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "/usr/local/sing-box/sing-box.log",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "google-tls",
        "address": "local",
        "address_strategy": "prefer_ipv4",
        "strategy": "ipv4_only",
        "detour": "direct"
      },
      {
        "tag": "google-udp",
        "address": "8.8.4.4",
        "address_strategy": "prefer_ipv4",
        "strategy": "prefer_ipv4",
        "detour": "direct"
      }
    ],
    "strategy": "prefer_ipv4",
    "disable_cache": false,
    "disable_expire": false
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "0.0.0.0",
      "listen_port": ${port},
      "method": "${method}",
      "password": "${password}",
      "network": "tcp",
      "domain_strategy": "prefer_ipv4",
      "tcp_fast_open": true,
      "sniff": true,
      "proxy_protocol": false
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "inbound": ["ss-in"],
        "network": "tcp",
        "outbound": "direct"
      },
      {
        "geosite": "category-ads-all",
        "outbound": "block"
      },
      {
        "geosite": "cn",
        "geoip": "cn",
        "outbound": "block"
      }
    ],
    "geoip": {
      "path": "geoip.db",
      "download_url": "https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db",
      "download_detour": "direct"
    },
    "geosite": {
      "path": "geosite.db",
      "download_url": "https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db",
      "download_detour": "direct"
    },
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF

}

config_ShadowTLS(){
  echo ""
  read -p " 请输入ShadowTLS端口[100-65535的一个数字，默认443]：" port
  [[ -z "${port}" ]] && port=443
  if [[ "${port:0:1}" = "0" ]]; then
    LOGE "端口不能以0开头"
    exit 1
  fi
  LOGI "  ShadowTLS端口：$port"

  echo ""
  echo "数据加密方式："
  echo -e " ${red}1. 2022-blake3-aes-128-gcm${plain}"
  echo -e " ${red}2. chacha20-ietf-poly1305${plain}"      
  echo ""
  
  read -p "请加密类型，默认为1：" method_type
  [[ -z "${method_type}" ]] && method_type=1

  case $method_type in
  1)
    method="2022-blake3-aes-128-gcm"
    password=`openssl rand -base64 16`
    ;;
  2)
    method="chacha20-ietf-poly1305"
    password=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1`
    ;;
  *)
    LOGE " 请输入正确的选项！"
    exit 1
  esac

  LOGI "加密类型：$method"
  LOGI "密码：$password"

  echo ""
  read -p " 请输入handshake域名[默认为：www.bing.com]：" handshake_server
  [[ -z "${handshake_server}" ]] && handshake_server="www.bing.com"
  echo ""

  echo ""
  read -p " 请输入handshake端口[默认为：443]：" handshake_port
  [[ -z "${handshake_port}" ]] && handshake_port=443
  echo ""

  LOGI "handshake域名：$handshake_server"
  LOGI "handshake端口：$handshake_port"

  echo ""
  LOGD "开始配置config.json..."
  cat > ${CONFIG_FILE_PATH}/config.json <<-EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "/usr/local/sing-box/sing-box.log",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "google-tls",
        "address": "local",
        "address_strategy": "prefer_ipv4",
        "strategy": "ipv4_only",
        "detour": "direct"
      },
      {
        "tag": "google-udp",
        "address": "8.8.4.4",
        "address_strategy": "prefer_ipv4",
        "strategy": "prefer_ipv4",
        "detour": "direct"
      }
    ],
    "strategy": "prefer_ipv4",
    "disable_cache": false,
    "disable_expire": false
  },
  "inbounds": [
    {
      "type": "shadowtls",
      "tag": "shadowtls-in",
      "listen": "::",
      "listen_port": ${port},
      "handshake": {
        "server": "${handshake_server}",
        "server_port": ${handshake_port} 
      },
      "detour": "ss-in"
    },
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "127.0.0.1",
      "method": "${method}",
      "password": "${password}"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "inbound": ["shadowtls-in"],
      "network": "tcp",
      "outbound": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "geosite": "category-ads-all",
        "outbound": "block"
      },
      {
        "geosite": "cn",
        "geoip": "cn",
        "outbound": "block"
      }
    ],
    "geoip": {
      "path": "geoip.db",
      "download_url": "https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db",
      "download_detour": "direct"
    },
    "geosite": {
      "path": "geosite.db",
      "download_url": "https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db",
      "download_detour": "direct"
    },
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
}

SITES=(
http://www.ddxsku.com/
http://www.biqu6.com/
http://www.55shuba.com/
https://www.23xsw.cc/
http://www.bequgexs.com/
http://www.tjwl.com/
)

config_Trojan(){
  echo ""
  ip=`curl -sL -4 ip.sb`
  if [[ "$?" != "0" ]]; then
    LOGE "暂不支持IPv6服务器！"
    exit 1
  fi

  echo ""
  echo " 使用trojan请检查是否满足以下条件："
  echo -e " ${red}1.一个伪装域名${plain}"
  echo -e " ${red}2.伪装域名DNS解析指向当前服务器ip（${ip}）${plain}"
  echo ""
  read -p " 确认满足按y，按其他退出脚本：" answer
  if [[ "${answer,,}" != "y" ]]; then
    exit 0
  fi

  echo ""
  while true
  do
    read -p " 请输入伪装域名：" domain
    if [[ -z "${domain}" ]]; then
      LOGE "伪装域名输入错误，请重新输入！${plain}"
    else
      break
    fi
  done
  LOGI "伪装域名(host)：$domain"

  echo ""
  domain=${domain,,}
  resolve=`curl -sL https://lefu.men/hostip.php?d=${domain}`
  res=`echo -n ${resolve} | grep ${ip}`
  if [[ -z "${res}" ]]; then
    echo " ${domain} 解析结果：${resolve}"
    LOGE "伪装域名未解析到当前服务器IP(${ip})!${plain}"
    exit 1
  fi

  echo ""
  read -p " 请设置trojan密码（不输则随机生成）:" password
  [[ -z "$password" ]] && password=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1`
  LOGI " trojan密码：$password"

  echo ""
  read -p " 请输入trojan端口[100-65535的一个数字，默认443]：" port
  [[ -z "${port}" ]] && port=443
  if [[ "${port:0:1}" = "0" ]]; then
    LOGE "端口不能以0开头${plain}"
    exit 1
  fi
  LOGI " trojan端口：$port"

  echo ""
  while true
  do
    read -p " 请输入伪装路径，以/开头(不懂请直接回车)：" wspath
    if [[ -z "${wspath}" ]]; then
      len=`shuf -i5-12 -n1`
      ws=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $len | head -n 1`
      wspath="/$ws"
      break
    elif [[ "${wspath:0:1}" != "/" ]]; then
      echo "伪装路径必须以/开头！"
    elif [[ "${wspath}" = "/" ]]; then
      echo  "不能使用根路径！"
    else
      break
    fi
  done
  echo ""
  LOGI " ws路径：$wspath"

  echo ""
  echo "  请选择伪装站类型:"
  echo "  1) 静态网站(位于/usr/share/nginx/html)"
  echo "  2) 小说站(随机选择)"
  echo "  3) Bing(http://www.bing.com)"  
  echo "  4) 自定义反代站点(需以http或者https开头)"
  read -p " 请选择伪装网站类型[默认:Bing]" answer
  if [[ -z "$answer" ]]; then
    proxy_url="https://www.baidu.com"
  else
    case $answer in
    1)
      proxy_url=""
      ;;
    2)
      len=${#SITES[@]}
      ((len--))
      while true
      do
        index=`shuf -i0-${len} -n1`
        proxy_url=${SITES[$index]}
        host=`echo ${proxy_url} | cut -d/ -f3`
        temp_ip=`curl -sL https://lefu.men/hostip.php?d=${host}`
        res=`echo -n ${temp_ip} | grep ${host}`
        if [[ "${res}" = "" ]]; then
          echo "$temp_ip $host" >> /etc/hosts
          break
        fi
      done
      ;;  
    3)
      proxy_url="https://www.bing.com"
      ;;
    4)
      read -p " 请输入反代站点(以http或者https开头)：" proxy_url
      if [[ -z "$proxy_url" ]]; then
        LOGE " 请输入反代网站！"
        exit 1
      elif [[ "${proxy_url:0:4}" != "http" ]]; then
        LOGE " 反代网站必须以http或https开头！"
        exit 1
      fi
      ;;
    *)
      LOGE " 请输入正确的选项！"
      exit 1
    esac
  fi
  remote_host=`echo ${proxy_url} | cut -d/ -f3`
  echo ""
  LOGI " 伪装网站：$proxy_url"

  echo ""
  LOGI " 开始安装nginx..."
  if [[ ${OS_RELEASE} == "ubuntu" || ${OS_RELEASE} == "debian" ]]; then
    apt install nginx -y
    if [[ "$?" != "0" ]]; then
      LOGE " Nginx安装失败！"
      exit 1
    fi
  elif [[ ${OS_RELEASE} == "centos" ]]; then
    yum install epel-release -y
    if [[ "$?" != "0" ]]; then
      echo '[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true' > /etc/yum.repos.d/nginx.repo
    fi
    yum install nginx -y
    if [[ "$?" != "0" ]]; then
      LOGE " Nginx安装失败！"
      exit 1
    fi
  fi
  systemctl enable nginx

  getCert
  config_Nginx

  LOGD "开始配置config.json..."
  if [[ ! -f /usr/local/etc/sing-box/config.json.bak ]]; then
    mv /usr/local/etc/sing-box/config.json /usr/local/etc/sing-box/config.json.bak
  fi
  cat > /usr/local/etc/sing-box/config.json <<-EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "/usr/local/sing-box/sing-box.log",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "google-tls",
        "address": "local",
        "address_strategy": "prefer_ipv4",
        "strategy": "ipv4_only",
        "detour": "direct"
      },
      {
        "tag": "google-udp",
        "address": "8.8.4.4",
        "address_strategy": "prefer_ipv4",
        "strategy": "prefer_ipv4",
        "detour": "direct"
      }
    ],
    "strategy": "prefer_ipv4",
    "disable_cache": false,
    "disable_expire": false
  },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "0.0.0.0",
      "listen_port": ${port},
      "domain_strategy": "prefer_ipv4",
      "users": [
        {
          "name": "truser",
          "password": "$password"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      },
      "fallback": {
        "server": "127.0.0.1",
        "server_port": 80
      },
      "fallback_for_alpn": {
        "http/1.1": {
          "server": "127.0.0.1",
          "server_port": 80
        },
        "http/2": {
          "server": "127.0.0.1",
          "server_port": 80
        },
      },
      "transport": {
        "type": "ws",
	      "path": "${wspath}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "inbound": ["trojan-in"],
        "network": "tcp",
        "outbound": "direct"
      },
      {
        "geosite": "category-ads-all",
        "outbound": "block"
      },
      {
        "geosite": "cn",
        "geoip": "cn",
        "outbound": "block"
      }
    ],
    "geoip": {
      "path": "geoip.db",
      "download_url": "https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db",
      "download_detour": "direct"
    },
    "geosite": {
      "path": "geosite.db",
      "download_url": "https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db",
      "download_detour": "direct"
    },
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
}

getCert() {
  LOGD "开始获取证书..."
  systemctl stop nginx
  sleep 2s

  res=`ss -ntlp| grep -E ':80 |:443 '`
  if [[ "${res}" != "" ]]; then
    LOGE "其他进程占用了80或443端口，请先关闭再运行一键脚本${plain}"
    LOGE "端口占用信息如下："
    LOGE ${res}
    exit 1
  fi

  if [[ ${OS_RELEASE} == "ubuntu" || ${OS_RELEASE} == "debian" ]]; then
    apt install -y socat openssl cron
    systemctl start cron
    systemctl enable cron
  elif [[ ${OS_RELEASE} == "centos" ]]; then
    yum install -y socat openssl cronie
    systemctl start crond
    systemctl enable crond
  fi

  curl -sL https://get.acme.sh | sh -s email=hijk.pw@protonmail.ch
  source ~/.bashrc
  ~/.acme.sh/acme.sh --upgrade  --auto-upgrade
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  ~/.acme.sh/acme.sh --force --issue -d $domain --keylength ec-256 --pre-hook "systemctl stop nginx" --post-hook "systemctl restart nginx"  --standalone

  [[ -f ~/.acme.sh/${domain}_ecc/ca.cer ]] || {
    LOGE " 获取证书失败!"
    exit 1
  }

  CERT_FILE="${CONFIG_FILE_PATH}/${domain}.pem"
  KEY_FILE="${CONFIG_FILE_PATH}/${domain}.key"
  ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
    --key-file       $KEY_FILE  \
    --fullchain-file $CERT_FILE \
    --reloadcmd     "service nginx force-reload"
  [[ -f $CERT_FILE && -f $KEY_FILE ]] || {
    LOGE "获取证书失败!"
    exit 1
  }
}

config_Nginx() {
  echo ""
  LOGD "开始配置nginx..."
  
  systemctl stop nginx
  NGINX_CONF_PATH="/etc/nginx/conf.d/"
  mkdir -p /usr/share/nginx/html

  echo 'User-Agent: *' > /usr/share/nginx/html/robots.txt
  echo 'Disallow: /' >> /usr/share/nginx/html/robots.txt
  ROBOT_CONFIG="    location = /robots.txt {}"

  res=`id nginx 2>/dev/null`
  if [[ "$?" != "0" ]]; then
    user="www-data"
  else
    user="nginx"
  fi
  cat > /etc/nginx/nginx.conf<<-EOF
user $user;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
# Load dynamic modules. See /usr/share/doc/nginx/README.dynamic.
include /usr/share/nginx/modules/*.conf;
events {
    worker_connections 1024;
}
http {
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    server_tokens off;
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;
    gzip                on;
    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;
    # Load modular configuration files from the /etc/nginx/conf.d directory.
    # See http://nginx.org/en/docs/ngx_core_module.html#include
    # for more information.
    include /etc/nginx/conf.d/*.conf;
}
EOF
    
    mkdir -p $NGINX_CONF_PATH
    if [[ "$proxy_url" = "" ]]; then
        cat > $NGINX_CONF_PATH${domain}.conf<<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name 127.0.0.1;
    root /usr/share/nginx/html;
    $ROBOT_CONFIG
}
EOF
    else
        cat > $NGINX_CONF_PATH${domain}.conf<<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name 127.0.0.1;
    root /usr/share/nginx/html;
    location / {
        proxy_ssl_server_name on;
        proxy_pass $proxy_url;
        proxy_set_header Accept-Encoding '';
        sub_filter "$remote_host" "$domain";
        sub_filter_once off;
    }
    $ROBOT_CONFIG
}
EOF
    fi
    LOGD "nginx配置完成..."
    systemctl restart nginx
}

config_sing-box(){
  LOGD "开始进行sing-box配置..."

  if [[ -f "${CONFIG_FILE_PATH}/config.json" ]]; then
    mv -f ${CONFIG_FILE_PATH}/config.json ${CONFIG_FILE_PATH}/config.json.bak
  fi
  
  echo ""
  echo "可配置类型："
  echo -e " ${red}1. Shadowsocks${plain}"
  echo -e " ${red}2. ShadowTLS${plain}"
  echo -e " ${red}3. Trojan${plain}"
  echo ""
  
  read -p "请选择配置类型，默认为1：" BOX_TYPE
  [[ -z "${BOX_TYPE}" ]] && BOX_TYPE=1
  LOGI "类型为：$BOX_TYPE"

  case $BOX_TYPE in
  1)
    config_Shadowsocks
    ;;
  2)
    config_ShadowTLS
    ;;
  3)
    config_Trojan
    ;;
  *)
    LOGE " 请输入正确的选项！"
    exit 1
  esac
  echo ""
}

setFirewall() {
  LOGD "开始配置防火墙..."
  res=`which firewall-cmd 2>/dev/null`
  if [[ $? -eq 0 ]]; then
    systemctl status firewalld > /dev/null 2>&1
    if [[ $? -eq 0 ]];then
      firewall-cmd --permanent --add-service=http
      firewall-cmd --permanent --add-service=https
      if [[ "$port" != "443" ]]; then
        firewall-cmd --permanent --add-port=${port}/tcp
      fi
      firewall-cmd --reload
    else
      nl=`iptables -nL | nl | grep FORWARD | awk '{print $1}'`
      if [[ "$nl" != "3" ]]; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT
        if [[ "$port" != "443" ]]; then
          iptables -I INPUT -p tcp --dport ${port} -j ACCEPT
        fi
      fi
    fi
  else
    res=`which iptables 2>/dev/null`
    if [[ $? -eq 0 ]]; then
      nl=`iptables -nL | nl | grep FORWARD | awk '{print $1}'`
      if [[ "$nl" != "3" ]]; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT
        if [[ "$port" != "443" ]]; then
          iptables -I INPUT -p tcp --dport ${port} -j ACCEPT
        fi
      fi
    else
      res=`which ufw 2>/dev/null`
      if [[ $? -eq 0 ]]; then
        res=`ufw status | grep -i inactive`
        if [[ "$res" = "" ]]; then
          ufw allow http/tcp
          ufw allow https/tcp
          if [[ "$port" != "443" ]]; then
            ufw allow ${port}/tcp
          fi
        fi
      fi
    fi
  fi
  echo ""
}

reconfig_sing-box(){
  LOGD "重新配置sing-box..."
  if [[ ! -f "${SERVICE_FILE_PATH}" ]]; then
    LOGE " sing-box未安装，请先安装！"
    return
  fi

  stop_sing-box
  config_sing-box
  restart_sing-box
}

showInfo() {
  if [[ -f ${CONFIG_FILE_PATH}/config.json ]]; then
      ip=`curl -sL -4 ip.sb`
      port=`grep listen_port ${CONFIG_FILE_PATH}/config.json | cut -d: -f2 | tr -d \",' '`
      password=`grep password ${CONFIG_FILE_PATH}/config.json | cut -d\" -f4`
      
      line1=`grep -n 'inbounds' ${CONFIG_FILE_PATH}/config.json  | head -n1 | cut -d: -f1`
      line11=`expr $line1 + 2`
      local type=`sed -n "${line11}p" ${CONFIG_FILE_PATH}/config.json | cut -d: -f2 | tr -d \",' '`
      if [[ ${type} == "shadowsocks" || ${type} == "shadowtls" ]]; then
        method=`grep method ${CONFIG_FILE_PATH}/config.json | cut -d\" -f4`
        if [[ ${type} == "shadowtls" ]]; then
          line1=`grep -n 'handshake' ${CONFIG_FILE_PATH}/config.json  | head -n1 | cut -d: -f1`
          line11=`expr $line1 + 1`
          handshake_server=`sed -n "${line11}p" ${CONFIG_FILE_PATH}/config.json | cut -d: -f2 | tr -d \",' '`
          line11=`expr $line1 + 2`
          handshake_port=`sed -n "${line11}p" ${CONFIG_FILE_PATH}/config.json | cut -d: -f2 | tr -d \",' '`
        fi
        echo ""
        echo -e "   ${blue}${type}配置信息：${plain}"
        echo -e "   IP：${red}$ip${plain}"
        echo -e "   端口(port)：${red}$port${plain}"
        echo -e "   加密方式(method)：${red}$method${plain}"
        echo -e "   密码(password)：${red}$password${plain}"
        echo -e "   SIN地址：${red}$handshake_server${plain}"
        echo -e "   SIN端口：${red}$handshake_port${plain}"
        echo ""
      elif [[ ${type} == "trojan" ]]; then
        domain=`grep server_name ${CONFIG_FILE_PATH}/config.json | cut -d\" -f4`
        line1=`grep -n 'transport' ${CONFIG_FILE_PATH}/config.json  | head -n1 | cut -d: -f1`
        line11=`expr $line1 + 2`
        ws=`sed -n "${line11}p" ${CONFIG_FILE_PATH}/config.json | cut -d: -f2 | tr -d \",' '`
        echo ""
        echo -e "   ${blue}trojan配置信息：${plain}"
        echo -e "   IP：${red}$ip${plain}"
        echo -e "   域名：${red}$domain${plain}"
        echo -e "   端口(port)：${red}$port${plain}"
        echo -e "   密码(password)：${red}$password${plain}"
        echo -e "   websocket：${red}true${plain}"
        echo -e "   ws路径：${red}${ws}${plain}"
        echo ""
      fi
  else
    LOGE "没有读取到有效的配置文件：${CONFIG_FILE_PATH}/config.json"
    exit 1    
  fi
}

show_menu() {
  echo -e "
  ${green}sing-box-v${SING_BOX_YES_VERSION} 管理脚本${plain}
  ${green}0.${plain} 退出脚本
————————————————
  ${green}1.${plain} 安装 sing-box 服务
  ${green}2.${plain} 更新 sing-box 服务
  ${green}3.${plain} 卸载 sing-box 服务
  ${green}4.${plain} 启动 sing-box 服务
  ${green}5.${plain} 停止 sing-box 服务
  ${green}6.${plain} 重启 sing-box 服务
  ${green}7.${plain} 修改 sing-box 配置
  ${green}8.${plain} 查看 sing-box 状态
  ${green}9.${plain} 查看 sing-box 日志
  ${green}A.${plain} 清除 sing-box 日志
  ${green}B.${plain} 检查 sing-box 配置
  ${green}C.${plain} 设置 sing-box 开机自启
  ${green}D.${plain} 取消 sing-box 开机自启
  ${green}E.${plain} 查看 sing-box 配置
 "
  show_status
  echo && read -p "请输入选择[0-E]:" num

  case "${num}" in
  0)
    exit 0
    ;;
  1)
    install_sing-box && show_menu
    ;;
  2)
    update_sing-box && show_menu
    ;;
  3)
    uninstall_sing-box && show_menu
    ;;
  4)
    start_sing-box && show_menu
    ;;
  5)
    stop_sing-box && show_menu
    ;;
  6)
    restart_sing-box && show_menu
    ;;
  7)
    reconfig_sing-box && show_menu
    ;;    
  8)
    show_menu
    ;;
  9)
    show_log && show_menu
    ;;
  A)
    clear_log && show_menu
    ;;
  B)
    config_check && show_menu
    ;;
  C)
    enable_sing-box && show_menu
    ;;
  D)
    disable_sing-box && show_menu
    ;;   
  E)
    showInfo
    ;;        
  *)
    LOGE "请输入正确的选项 [0-G]"
    ;;
  esac
}

start_to_run() {
  set_as_entrance
  clear
  show_menu
}

start_to_run
