#!/bin/bash
# sing-box-onekey 一键安装脚本
# Author: yuehen7

plain='\033[0m'
red='\033[0;31m'
blue='\033[1;34m'
pink='\033[1;35m'
green='\033[0;32m'
yellow='\033[0;33m'

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

[[ $EUID -ne 0 ]] && LOGE "请使用root用户运行该脚本" && exit 1


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

kill -9 $(ps -ef | grep sing-box | grep -v grep | awk '{print $2}')
kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $2}')

clear
read -p "请选择sing-box协议(默认1.vmess,2.trojan):" mode
if [ -z "$mode" ]
then
	mode=1
fi
if [ $mode != 1 ] && [ $mode != 2 ]
then
	LOGI "请输入正确的sing-box模式"
	exit 1
fi
read -p "请选择argo连接模式IPV4或者IPV6(输入4或6,默认4):" ips
if [ -z "$ips" ]
then
	ips=4
fi
if [ $ips != 4 ] && [ $ips != 6 ]
then
	LOGI "请输入正确的argo连接模式"
	exit 1
fi

OS_ARCH=''
SING_BOX_VERSION_TEMP=$(curl -Ls "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
SING_BOX_VERSION=${SING_BOX_VERSION_TEMP:1}

case "$(uname -m)" in
	x86_64 | x64 | amd64 )
	wget https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz -O sing-box.tar.gz
	wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O cloudflared-linux
  OS_ARCH="amd64"
	;;
	armv8 | arm64 | aarch64 )
	echo arm64
	wget https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-${SING_BOX_VERSION}-linux-arm64.tar.gz -O sing-box.tar.gz
	wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -O cloudflared-linux
  OS_ARCH="arm64"
	;;
	arm71 )
	wget https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-${SING_BOX_VERSION}-linux-armv7.tar.gz -O sing-box.tar.gz
	wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -O cloudflared-linux
  OS_ARCH="armv7"
	;;
	* )
	echo 当前架构$(uname -m)没有适配
	exit
	;;
esac

chmod +x cloudflared-linux
rm -rf sing-box
tar -xzvf sing-box.tar.gz
mv sing-box-${SING_BOX_VERSION}-linux-${OS_ARCH} sing-box
chmod +x ./sing-box/sing-box

uuid=$(cat /proc/sys/kernel/random/uuid)
urlpath=$(echo $uuid | awk -F- '{print $1}')
port=$[$RANDOM+10000]

if [ $mode == 1 ]
then
cat>sing-box/config.json<<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "sing-box.log",
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
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": ${port},
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
        "path": "/${urlpath}"
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
        "inbound": ["vmess-in"],
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
fi

if [ $mode == 2 ]
then
cat>sing-box/config.json<<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "sing-box.log",
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
      "listen": "127.0.0.1",
      "listen_port": ${port},
      "domain_strategy": "prefer_ipv4",
      "users": [
        {
          "name": "truser",
          "password": "${uuid}"
        }
      ],
      "transport": {
        "type": "ws",
	      "path": "/${urlpath}"
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
      "path": "./geoip.db",
      "download_url": "https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db",
      "download_detour": "direct"
    },
    "geosite": {
      "path": "./geosite.db",
      "download_url": "https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db",
      "download_detour": "direct"
    },
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
fi
pushd ./sing-box
./sing-box run -c config.json>/dev/null 2>&1 &
popd
./cloudflared-linux tunnel --url http://localhost:$port --no-autoupdate --edge-ip-version $ips --protocol h2mux>argo.log 2>&1 &

sleep 2
clear
echo 等待cloudflare argo生成地址
sleep 5
argo=$(cat argo.log | grep trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
clear
rm -rf singbox.txt
if [ $mode == 1 ]
then
	echo -e vmess链接已经生成, speed.cloudflare.com 可替换为CF优选IP'\n' > singbox.txt
	echo 'vmess://'$(echo '{"add":"speed.cloudflare.com","aid":"0","host":"'$argo'","id":"'$uuid'","net":"ws","path":"'/$urlpath'","port":"443","ps":"vmess_tls","tls":"tls","type":"none","v":"2"}' | base64 -w 0) >> singbox.txt
	echo -e '\n'端口 443 可改为 2053 2083 2087 2096 8443'\n' >> singbox.txt
	echo 'vmess://'$(echo '{"add":"speed.cloudflare.com","aid":"0","host":"'$argo'","id":"'$uuid'","net":"ws","path":"'/$urlpath'","port":"80","ps":"vmess","tls":"","type":"none","v":"2"}' | base64 -w 0) >> singbox.txt
	echo -e '\n'端口 80 可改为 8080 8880 2052 2082 2086 2095 >> singbox.txt
fi
if [ $mode == 2 ]
then
	echo -e vless链接已经生成, speed.cloudflare.com 可替换为CF优选IP'\n' > singbox.txt
	echo 'trojan://'$uuid'@speed.cloudflare.com:443?encryption=none&security=tls&type=ws&host='$argo'&path=%2F'${urlpath}'#trojan_tls' >> singbox.txt
	echo -e '\n'端口 443 可改为 2053 2083 2087 2096 8443'\n' >> singbox.txt
	echo 'trojan://'$uuid'@speed.cloudflare.com:80?encryption=none&security=none&type=ws&host='$argo'&path=%2F'${urlpath}'#trojan' >> singbox.txt
	echo -e '\n'端口 80 可改为 8080 8880 2052 2082 2086 2095 >> singbox.txt
fi
rm -rf argo.log
cat singbox.txt
echo -e '\n'信息已经保存在 singbox.txt,再次查看请运行 cat singbox.txt
