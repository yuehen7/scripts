#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

sh_ver="1.0.1"

#0升级脚本
update_shell(){
	sh_new_ver=$(wget --no-check-certificate -qO- -t1 -T3 "https://raw.githubusercontent.com/yuehen7/scripts/main/main.sh"|grep 'sh_ver="'|awk -F "=" '{print $NF}'|sed 's/\"//g'|head -1) && sh_new_type="github"
	[[ -z ${sh_new_ver} ]] && echo -e "${Error} 无法链接到 Github !" && exit 0
	wget -N --no-check-certificate "https://raw.githubusercontent.com/yuehen7/scripts/main/main.sh" && chmod +x main.sh
	echo -e "脚本已更新为最新版本[ ${sh_new_ver} ] !(注意：因为更新方式为直接覆盖当前运行的脚本，所以可能下面会提示一些报错，无视即可)" && exit 0
}

timezone(){
	cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && hwclock -w && echo $(curl -sSL "https://github.com/yuehen7/scripts/raw/main/time") >> ~/.bashrc 
}

bbr(){
	bash <(curl -Lso- https://git.io/kernel.sh)
}

warp(){
  bash <(curl -sSL "https://raw.githubusercontent.com/fscarmen/warp/main/menu.sh")
}

trojan-go(){
  bash <(curl -sSL "https://raw.githubusercontent.com/yuehen7/scripts/main/trojan-go.sh")	
}

sing-box(){
  bash <(curl -sSL "https://raw.githubusercontent.com/yuehen7/scripts/main/sing-box.sh")	
}

media(){
  bash <(curl -L -s https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh)
}

huicheng(){
	bash <(curl -sSL "https://raw.githubusercontent.com/zhucaidan/mtr_trace/main/mtr_trace.sh")
}

speedTest(){
  bash <(curl -Lso- https://git.io/superspeed_uxh)
}

result=$(id | awk '{print $1}')
if [[ $result != "uid=0(root)" ]]; then
  echo -e "请以root身份执行该脚本"
  exit 0
fi

echo && echo -e " 
+-------------------------------------------------------------+
|                          懒人专用                           |                     
|                     一键在手小鸡无忧                         |
+-------------------------------------------------------------+
 
 ${Green_font_prefix} 0.${Font_color_suffix} 升级脚本
 —————————系统类—————————
 ${Green_font_prefix} 1.${Font_color_suffix} 更改为中国时区(24h制,重启生效)
 ${Green_font_prefix} 2.${Font_color_suffix} bbr安装
 ${Green_font_prefix} 3.${Font_color_suffix} warp安装
 —————————代理类—————————
 ${Green_font_prefix} 4.${Font_color_suffix} trojan-go安装
 ${Green_font_prefix} 5.${Font_color_suffix} sing-box安装
 —————————测试类————————— 
 ${Green_font_prefix} 6.${Font_color_suffix} 流媒体测试
 ${Green_font_prefix} 7.${Font_color_suffix} 回程线路测试
 ${Green_font_prefix} 8.${Font_color_suffix} 三网测速 
" && echo

echo
read -e -p " 请输入数字 [0-8]:" num
case "$num" in
	0)
	update_shell
	;;
	1)
	timezone
	;;
	2)
	bbr
	;;
	3)
	warp
	;;
	4)
	trojan-go
	;;
	5)
	sing-box
	;;
  6)
	media
	;;
  7)
	huicheng
	;;
  8)
	speedTest
	;;
	*)
	echo "请输入正确数字 [0-8]"
	;;
esac
