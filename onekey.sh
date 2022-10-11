#!/bin/bash
# sing-box-onekey 一键安装脚本
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
SING_BOX_ONEKEY_VERSION='1.0.7'

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

clear_sing_box() {
  LOGD "开始清除sing-box..."
  create_or_delete_path 0 && rm -rf ${SERVICE_FILE_PATH} && rm -rf ${BINARY_FILE_PATH} && rm -rf ${SCRIPT_FILE_PATH}
  LOGD "清除sing-box完毕"
}

uninstall_Nginx() {
  LOGI "开始卸载nginx..."
  systemctl stop nginx
  sleep 2s
  if [[ ${OS_RELEASE} == "ubuntu" || ${OS_RELEASE} == "debian" ]]; then
    apt autoremove nginx-common -y
    apt autoremove nginx -y
  elif [[ ${OS_RELEASE} == "centos" ]]; then
    yum remove nginx -y
  fi

  rm -rf /etc/nginx/nginx.conf
  if [[ -f /etc/nginx/nginx.conf.bak ]]; then
    mv /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
  fi

  ~/.acme.sh/acme.sh --uninstall
  rm -rf /etc/nginx/conf.d/alone.conf && rm -rf /usr/share/nginx && rm -rf ~/.acme.sh
  LOGI "nginx及acme.sh卸载完成."
}

uninstall_sing-box() {
  uninstall_Nginx
  echo ""
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

install_sing-box() {
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

enable_sing-box() {
  systemctl enable sing-box
  if [[ $? == 0 ]]; then
    LOGI "设置sing-box开机自启成功"
  else
    LOGE "设置sing-box开机自启失败"
  fi
}

create_Cert() {
  LOGD "开始获取证书..."
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
  ~/.acme.sh/acme.sh --install-cert -d $domain --ecc \
    --key-file       $KEY_FILE  \
    --fullchain-file $CERT_FILE \
    --reloadcmd     "service nginx force-reload"
  [[ -f $CERT_FILE && -f $KEY_FILE ]] || {
    LOGE "获取证书失败!"
    exit 1
  }
}

install_Nginx() {
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
}

config_Nginx() {
  LOGD "开始配置nginx..."
  systemctl stop nginx

  LOGD "配置伪装站..."
  rm -rf /usr/share/nginx/html
  mkdir -p /usr/share/nginx/html
  wget -c -P /usr/share/nginx "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/fodder/blog/unable/html8.zip" >/dev/null
  unzip -o "/usr/share/nginx/html8.zip" -d /usr/share/nginx/html >/dev/null
  rm -f "/usr/share/nginx/html8.zip*"

  echo 'User-Agent: *' > /usr/share/nginx/html/robots.txt
  echo 'Disallow: /' >> /usr/share/nginx/html/robots.txt
  ROBOT_CONFIG="    location = /robots.txt {}"

  if [[ ! -f /etc/nginx/nginx.conf.bak ]]; then
    mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
  fi
  
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

  mkdir -p /etc/nginx/conf.d

  if [[ "${tlsFlag}" == "y" ]]; then
    cat > /etc/nginx/conf.d/alone.conf <<-EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${domain};
  rewrite ^(.*)$ https://${domain}:${port}$1 permanent;
}

server {
  listen ${port} ssl;
  server_name ${domain};

  ssl_certificate ${CERT_FILE};
  ssl_certificate_key ${KEY_FILE};
  ssl_session_timeout 15m;
  ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE:ECDH:AES:HIGH:!NULL:!aNULL:!MD5:!ADH:!RC4;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers on;

  root /usr/share/nginx/html;

  location /vmess {
    proxy_redirect off;
    proxy_pass http://127.0.0.1:33210;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$http_host;
    proxy_read_timeout 300s;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }

  location /trojan {
    proxy_redirect off;
    proxy_pass http://127.0.0.1:33211;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$http_host;
    proxy_read_timeout 300s;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
EOF
  else
    cat > /etc/nginx/conf.d/alone.conf <<-EOF
server {
  listen ${port};
  listen [::]:${port};
  server_name ${domain};
  root /usr/share/nginx/html;

  location /vmess {
    proxy_redirect off;
    proxy_pass http://127.0.0.1:33210;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$http_host;
    proxy_read_timeout 300s;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }

  location /trojan {
    proxy_redirect off;
    proxy_pass http://127.0.0.1:33211;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$http_host;
    proxy_read_timeout 300s;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
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
  ip=`curl -sL -4 ip.sb`
  if [[ "$?" != "0" ]]; then
    LOGE "暂不支持IPv6服务器！"
    exit 1
  fi

  echo ""
  read -p " 是否启用TLS(y/n)[默认为:y]：" tlsFlag
  [[ -z "${tlsFlag}" ]] && tlsFlag="y"
  LOGI " 开启tls：$tlsFlag"

  if [[ "${tlsFlag}" == "y" ]]; then
    echo ""
    echo " 请检查是否满足以下条件："
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
  fi

  echo ""
  read -p " 请输入nginx端口[100-65535的一个数字，默认443]：" port
  [[ -z "${port}" ]] && port=443
  if [[ "${port:0:1}" = "0" ]]; then
    LOGE "端口不能以0开头${plain}"
    exit 1
  fi
  LOGI " 使用端口：$port"

  echo ""
  read -r -p "是否自定义UUID ？[y/n]:" customUUIDStatus
  if [[ "${customUUIDStatus}" == "y" ]]; then
		read -r -p "请输入合法的UUID:" currentCustomUUID
		if [[ -n "${currentCustomUUID}" ]]; then
			uuid=${currentCustomUUID}
		fi
  else
    uuid=`cat /proc/sys/kernel/random/uuid`
	fi
  LOGI " UUID：$uuid"

  echo ""
  read -p " 请输入Shadowsocks端口[30000-65535的一个数字，默认34210]：" port_ss
  [[ -z "${port_ss}" ]] && port=34210
  if [[ "${port_ss:0:1}" = "0" ]]; then
    LOGE "端口不能以0开头"
    exit 1
  fi
  LOGI " Shadowsocks端口：$port_ss"

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

  if [[ "${tlsFlag}" == "y" ]]; then
    create_Cert
  fi

  install_Nginx
  config_Nginx

  LOGD "开始配置config.json..."
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
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "0.0.0.0",
      "listen_port": ${port_ss},
      "method": "${method}",
      "password": "${password}",
      "network": "tcp",
      "domain_strategy": "prefer_ipv4",
      "tcp_fast_open": true,
      "sniff": true,
      "proxy_protocol": false
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": 33210,
      "tcp_fast_open": false,
      "sniff": true,
      "sniff_override_destination": false,
      "domain_strategy": "prefer_ipv4",
      "proxy_protocol": false,
      "users": [
        {
          "name": "franzkafka",
          "uuid": "${uuid}",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vmess"
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "127.0.0.1",
      "listen_port": 33211,
      "domain_strategy": "prefer_ipv4",
      "users": [
        {
          "name": "truser",
          "password": "${uuid}"
        }
      ],
      "transport": {
        "type": "ws",
	      "path": "/trojan"
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
        "inbound": ["vmess-in","trojan-in"],
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

setFirewall() {
  LOGD "开始配置防火墙..."
  res=`which firewall-cmd 2>/dev/null`
  if [[ $? -eq 0 ]]; then
    systemctl status firewalld > /dev/null 2>&1
    if [[ $? -eq 0 ]];then
      firewall-cmd --permanent --add-service=http
      firewall-cmd --permanent --add-service=https
      firewall-cmd --permanent --add-port=${port_ss}/tcp
      if [[ "$port" != "443" ]]; then
        firewall-cmd --permanent --add-port=${port}/tcp
      fi
      firewall-cmd --reload
    else
      nl=`iptables -nL | nl | grep FORWARD | awk '{print $1}'`
      if [[ "$nl" != "3" ]]; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT
        iptables -I INPUT -p tcp --dport ${port_ss} -j ACCEPT
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
        iptables -I INPUT -p tcp --dport ${port_ss} -j ACCEPT
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
          ufw allow ${port_ss}/tcp
          if [[ "$port" != "443" ]]; then
            ufw allow ${port}/tcp
          fi
        fi
      fi
    fi
  fi
  echo ""
}

showInfo() {
  if [[ -f ${CONFIG_FILE_PATH}/config.json && -f /etc/nginx/conf.d/alone.conf ]]; then
    line1=`grep -n 'server_name' /etc/nginx/conf.d/alone.conf | head -n1 | cut -d: -f1`
    domain=`sed -n "${line1}p" /etc/nginx/conf.d/alone.conf | cut -d: -f2 | sed s/[[:space:]]//g `
    domain=${domain/server_name/''}
    domain=${domain/;/''}

    port=`grep "listen.*ssl" /etc/nginx/conf.d/alone.conf | sed s/[[:space:]]//g `
    port=${port/listen/''}
    port=${port/ssl;/''}

    uuid=`grep password ${CONFIG_FILE_PATH}/config.json | cut -d\" -f4`
    
    base64Str=$(echo -n "{\"port\":${port},\"ps\":\"${domain}_vmess\",\"tls\":\"tls\",\"id\":\"${uuid}\",\"aid\":0,\"v\":2,\"host\":\"${domain}\",\"type\":\"none\",\"path\":\"/vmess\",\"net\":\"ws\",\"add\":\"${domain}\",\"allowInsecure\":0,\"peer\":\"${domain}\",\"sni\":\"\"}" | base64 -w 0)
    base64Str="${base64Str// /}"

    echo ""
    echo -e "${blue}vmess+ws+tls：${plain}"
    echo -e ""
    echo -e "vmess://${base64Str}\n"
    echo -e ""
    echo -e "${blue}trojan+ws+tls：${plain}"
    echo -e ""
    echo -e "trojan://${uuid}@${domain}:${port}?security=tls&type=ws&host=${domain}&path=%2Ftrojan#${domain}_trojan\n"
    echo ""
  else
    LOGE "没有读取配置文件失败."
    exit 1    
  fi
}

show_menu() {
  echo -e "
  ${green}sing-box-ongkey:v${SING_BOX_ONEKEY_VERSION} 管理脚本${plain}
  ${green}0.${plain} 退出脚本
  ${green}1.${plain} 安装 sing-box 服务
  ${green}2.${plain} 卸载 sing-box 服务
  ${green}3.${plain} 启动 sing-box 服务
  ${green}4.${plain} 停止 sing-box 服务
  ${green}5.${plain} 重启 sing-box 服务
  ${green}6.${plain} 检查 sing-box 配置
  ${green}7.${plain} 查看 sing-box 配置
 "
  show_status
  echo && read -p "请输入选择[0-7]:" num

  case "${num}" in
  0)
    exit 0
    ;;
  1)
    install_sing-box && showInfo
    ;;
  2)
    uninstall_sing-box && show_menu
    ;;
  3)
    start_sing-box && show_menu
    ;;
  4)
    stop_sing-box && show_menu
    ;;
  5)
    restart_sing-box && show_menu
    ;;
  6)
    config_check && show_menu
    ;;    
  7)
    showInfo
    ;;     
  *)
    LOGE "请输入正确的选项 [0-7]"
    ;;
  esac
}

start_to_run() {
  clear
  show_menu
}

start_to_run
