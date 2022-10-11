# 脚本集合

具体内容包括：
* 时间区域修改
* BBR加速
* WARP
* trojan-go搭建
* sing-box搭建（支持Shadowsocks、ShadowTLS、Trojan一键配置）
* 流媒体检测
* 回程线路测试
* 三网下载测试

### 合集脚本使用

```
wget -N --no-check-certificate https://raw.githubusercontent.com/yuehen7/scripts/main/main.sh && chmod +x main.sh && bash main.sh
```

sing-box安装后可直接使用sing-box命令

### sing-box一键脚本使用

该脚本使用nginx前置进行vmess和trojan分流，自动创建静态网站进行伪装.
* vmess+ws+tls
* trojan+ws+tls

```
bash <(curl -s -L https://raw.githubusercontent.com/yuehen7/scripts/main/onekey.sh)
```





# 致谢  
[FranzKafkaYu/sing-box-yes](https://github.com/FranzKafkaYu/sing-box-yes)
<br/>
[SagerNet/sing-box](https://github.com/SagerNet/sing-box)  
