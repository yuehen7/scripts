# scripts

代理服务一键安装与管理脚本，包含 Xray、sing-box 与 WireProxy-WARP 三套独立实现。

| 脚本 | 内核版本 | 管理命令 | 配置文件 |
| --- | --- | --- | --- |
| `install_xray.sh` | Xray `v26.6.27`（固定版本） | `xr` | `/etc/xray/config.json` |
| `install_singbox.sh` | sing-box（安装时获取最新版） | `sb` | `/etc/sing-box/config.json` |
| `install_warp.sh` | WireProxy + wgcf（安装时获取最新版） | `warp` | `/etc/wireproxy/wireproxy.conf` |

## 环境要求

- Linux，使用 systemd（Debian/Ubuntu/CentOS 等）或 OpenRC（Alpine 等）管理服务
- root 权限运行
- 需要 bash 4+（Alpine 需先手动安装 bash，见下文）
- 支持架构：x86_64、arm64、armv7、s390x、riscv64
- 依赖：`curl`、`wget`、`jq`、`openssl`、`tar`/`unzip`、`iproute2`（脚本会自动安装；bash 必须预先存在）

> WireProxy-WARP 由 wgcf 注册账户，wgcf 官方仅提供 x86_64、arm64、armv7、386、s390x 二进制，暂不支持 riscv64。WARP 使用 UDP 出站，服务器需能访问 CloudFlare 的 WARP Endpoint（默认 2408 端口）。

## 安装

### Xray

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_xray.sh)
```

### sing-box

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_singbox.sh)
```

Xray / sing-box 安装流程：安装依赖 → 应用 BBR/网络优化 → 下载内核 → **交互选择入站协议** → 生成配置 → 注册服务（systemd/OpenRC）→ 启动。

### WireProxy-WARP

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_warp.sh)
```

WireProxy-WARP 安装流程：安装依赖 → 下载 WireProxy 与 wgcf → 设置 SOCKS5 端口和监听地址 → 注册 WARP 账户 → 生成配置 → 注册服务（systemd/OpenRC）→ 启动并验证连通性。

### Alpine Linux

Alpine 默认使用 OpenRC，且未预装 bash，请先安装 bash 再执行脚本：

```shell
apk add --no-cache bash curl ca-certificates
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_xray.sh)
```

sing-box / WARP 同理，把文件名换成 `install_singbox.sh` / `install_warp.sh` 即可。

脚本会自动识别服务管理器：

- systemd：注册 `/etc/systemd/system/xray.service`、`sing-box.service` 或 `wireproxy-warp.service`，日志通过 `journalctl` 查看
- OpenRC：生成 `/etc/init.d/xray`、`/etc/init.d/sing-box` 或 `/etc/init.d/wireproxy-warp`，日志写入 `/var/log/xray.log`、`/var/log/sing-box.log` 或 `/var/log/wireproxy-warp.log`

## 入站协议选择

生成配置时会提示选择要启用的协议，可多选，**至少选择一个**：

| 编号 | 协议 | 默认端口 | 说明 |
| --- | --- | --- | --- |
| 1 | Shadowsocks | 32443 | 加密方式 `2022-blake3-aes-128-gcm`，密码自动生成 |
| 2 | VLESS + Reality | 443 | `xtls-rprx-vision`，自动测速选择伪装目标 |
| 3 | VMess + WS + TLS | 2053 | WS 路径 `/175443`，支持 CDN 回源 |

输入方式：

- 单选：`1`
- 多选：`1,3` 或 `2 3`
- 全选：`all`

选择协议后会逐个询问已启用协议的端口：

- **直接回车**：使用上表中的默认端口
- **输入自定义端口**：范围 1–65535，多个协议之间不能重复（重复会要求重新输入）

说明：

- VLESS-Reality 与 VMess-WS-TLS 共用固定 UUID `8326d9fd-3246-4ca0-aa48-894f0e7d96d6`。
- 仅选择 VMess-WS-TLS 时才需要域名和证书；只选 Shadowsocks / VLESS-Reality 时无需证书。
- Shadowsocks 密码、Reality 密钥对和 Short ID 在每次重新生成配置时都会更新。

## 住宅 IP 出站

生成配置时还会询问是否启用住宅 IP 出站：

1. 选择是否启用
2. 选择代理类型：HTTP 或 SOCKS5
3. 输入代理地址：`host:port`（兼容 `http://`、`socks5://` 前缀）
4. 输入用户名和密码（**均可留空**，无认证代理直接回车）

启用后：

- 该代理作为默认出站，未被拦截规则命中的流量都从住宅 IP 出站
- Xray 会额外把 53 端口 DNS 查询固定为直连，避免 DNS 走 HTTP/SOCKS 代理失败
- sing-box 的 `route.final` 会指向该住宅代理
- `xr info` / `sb info` 会显示当前住宅代理的类型、地址与认证信息
- 重新执行 `xr gen` / `sb gen` 会重新询问并覆盖现有出站配置

## WireProxy-WARP

WireProxy 是一个用户态 WireGuard 客户端，可以把 WARP 暴露为 SOCKS5 代理，无需创建 TUN 网卡，适合作为 Xray / sing-box 的上游出站，或作为独立代理使用。

安装时可配置：

- **SOCKS5 端口**：直接回车使用随机端口，脚本会自动检测端口占用
- **监听地址**：默认 `127.0.0.1`（仅本机）；填写 `0.0.0.0` 可对外提供服务
- **SOCKS5 认证**：监听 `0.0.0.0` 时建议设置用户名和密码，并配合防火墙限制来源 IP
- **Endpoint**：默认 `engage.cloudflareclient.com:2408`，安装后可随时更换

说明：

- WireProxy 的 SOCKS5 目前仅支持 TCP，UDP 流量无法通过该代理。
- 账户文件、配置文件均包含私钥，权限为 `600`。
- `warp info` 会通过代理访问 CloudFlare trace，显示出口 IP、WARP/WARP+ 状态和出口地区。
- 如果安装时默认 Endpoint 无法连通，脚本会自动尝试其他 CloudFlare Endpoint。

### 切换 WARP 出口 IP

`warp ip` 的执行流程：

1. 记录当前出口 IP；
2. 随机轮换 CloudFlare WARP Endpoint（如 `162.159.192.0/24`、`188.114.96.0/24` 等），每次重启并验证连通性；
3. 如果 Endpoint 轮换后出口 IP 仍未变化，自动重新注册 WARP 账户后再次尝试；
4. 切换失败时恢复原 Endpoint，避免停留在不可用节点。

> 部分网络环境下 CloudFlare 会固定出口 IP，此时轮换 Endpoint 或重新注册也可能无法改变。频繁重新注册可能触发 CloudFlare 429 限流。

相关命令：

| 命令 | 说明 |
| --- | --- |
| `warp ip` | 切换 WARP 出口 IP |
| `warp endpoint` | 手动更换 / 自动选择可用 Endpoint |
| `warp reg` | 仅重新注册 WARP 账户 |
| `warp plus` | 绑定 WARP+ 许可证 |
| `warp port` | 修改 SOCKS5 端口 |
| `warp stack` | 设置域名出口优先级（auto / v4 / v6） |
| `warp info` | 查看 SOCKS5 地址、出口 IP 与 WARP 状态 |

### IPv4 / IPv6 出口优先级

需要区分两层：

- **Endpoint 传输**：`warp ip` / `warp endpoint` 会先检测 IPv4 连通性；IPv4 可用时使用 IPv4 Endpoint，否则使用 IPv6 Endpoint。
- **代理出口**：配置同时启用 IPv4/IPv6（`AllowedIPs = 0.0.0.0/0, ::/0`）。访问 IP 字面量时按字面量协议走；访问域名时由 WireProxy 的 `ResolveStrategy` 决定：
  - `auto`（默认）：双栈时优先 IPv6
  - `ipv4`：优先 IPv4
  - `ipv6`：优先 IPv6

切换方式：

```shell
warp stack        # 交互选择
warp stack v4     # 优先 IPv4
warp stack v6     # 优先 IPv6
warp stack auto   # 恢复自动
```

优先级会写入 `/etc/wireproxy/wireproxy.conf` 的 `[Resolve] ResolveStrategy`，切换后自动重启并验证；`warp info` 会显示当前策略。

## 服务管理

安装完成后会部署管理命令，无参数运行进入交互菜单：

```shell
xr          # Xray 交互菜单
sb          # sing-box 交互菜单
warp        # WireProxy-WARP 交互菜单
```

| 子命令 | Xray | sing-box | 说明 |
| --- | :---: | :---: | --- |
| `start` | ✅ | ✅ | 启动服务 |
| `stop` | ✅ | ✅ | 停止服务 |
| `restart` | ✅ | ✅ | 重启服务 |
| `status` | ✅ | ✅ | 查看运行状态 |
| `log` | ✅ | ✅ | 实时查看日志 |
| `info` | ✅ | ✅ | 查看入站节点信息 |
| `check` / `test` | ✅ | ✅ | 检查配置文件 |
| `edit` | ✅ | ✅ | 编辑配置并可选重启 |
| `gen` | ✅ | ✅ | 重新选择协议并生成配置 |
| `bbr` | ✅ | ✅ | 查看/重新应用 BBR 优化 |
| `update` | ❌ | ✅ | 更新 sing-box 内核 |
| `uninstall` | ✅ | ✅ | 卸载脚本与内核 |

示例：

```shell
xr info
sb restart
warp ip
```

WireProxy-WARP 的 `warp` 支持上表中的 `start`、`stop`、`restart`、`status`、`log`、`info`、`check`、`test`、`edit`、`uninstall`，以及专用的 `ip`、`endpoint`、`port`、`stack`、`reg`、`plus` 子命令。

> `xr gen` / `sb gen` 会覆盖现有 `config.json`，并重新生成 Shadowsocks 密码、Reality 密钥和 Short ID，执行后需同步更新客户端节点。

## 节点信息

`xr info` / `sb info` 会读取当前配置并输出：

- 服务器地址、端口、UUID 或 Shadowsocks 密码
- 分享链接：`vless://`、`vmess://`、`ss://`
- Mihomo 可用的节点 JSON（添加到 `proxies` 数组）

## 证书

启用 VMess-WS-TLS 时，证书需放置在：

```text
/etc/xray/cert/fullchain.pem
/etc/xray/cert/privkey.pem

/etc/sing-box/cert/fullchain.pem
/etc/sing-box/cert/privkey.pem
```

- 若证书缺失，脚本会自动生成 1 年有效期的临时自签证书，仅用于让服务正常启动。
- 对外提供服务前请替换为正式证书（如 Let's Encrypt）。
- 只启用 Shadowsocks 或 VLESS-Reality 时不需要证书。

## 端口与防火墙

按实际选择的协议放行对应端口：

| 协议 | 默认端口 | 协议类型 |
| --- | --- | --- |
| VLESS + Reality | 443 | TCP |
| VMess + WS + TLS | 2053 | TCP |
| Shadowsocks | 32443 | TCP + UDP |
| WireProxy SOCKS5 | 安装时随机 / 自定义 | TCP |

云服务器还需在安全组中放行相同端口。如果生成配置时自定义了端口，请以实际配置为准；`xr info` / `sb info` / `warp info` 会显示最终使用的端口。

WireProxy 仅监听 `127.0.0.1` 时无需放行端口；监听 `0.0.0.0` 时需放行对应 TCP 端口，并建议启用 SOCKS5 用户名/密码认证、限制来源 IP。WARP 本身通过 UDP 连接 CloudFlare Endpoint（默认 2408），无需在服务器上放行入站 UDP。

## BBR 与网络优化

安装时自动写入：

- `/etc/sysctl.d/99-network-bbr.conf`
- `/etc/security/limits.d/99-nofile.conf`

启用 `fq` + `bbr`，并调整 TCP 缓冲区与文件描述符上限。可通过 `xr bbr` / `sb bbr` 查看状态并重新应用。

- systemd：由 `sysctl --system` 在开机时加载
- OpenRC（Alpine）：额外写入 `/etc/local.d/99-network-bbr.start`，通过 `local` 服务开机应用；服务本身的 nofile 限制由 init 脚本中的 `rc_ulimit` 设置

## 更新与卸载

```shell
sb update        # 更新 sing-box 到最新版
xr uninstall     # 卸载 Xray
sb uninstall     # 卸载 sing-box
warp uninstall   # 卸载 WireProxy-WARP
```

重新执行 `install_warp.sh` 时会提示是否保留现有 WARP 账户和端口设置，选择保留即可只更新 WireProxy / wgcf 程序。

Xray 使用固定版本 `v26.6.27`，如需升级请修改脚本顶部的 `XRAY_VERSION` 后重新执行安装。
