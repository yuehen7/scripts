# scripts

代理服务与端口转发一键安装管理脚本，包含 Xray、sing-box、WireProxy-WARP 与 Realm 四套独立实现。

| 脚本 | 内核版本 | 管理命令 | 配置文件 |
| --- | --- | --- | --- |
| `install_xray.sh` | Xray `v26.6.27`（固定版本） | `xr` | `/etc/xray/config.json` |
| `install_singbox.sh` | sing-box（安装时获取最新版） | `sb` | `/etc/sing-box/config.json` |
| `install_warp.sh` | WireProxy + wgcf（安装时获取最新版） | `warp` | `/etc/wireproxy/wireproxy.conf` |
| `install_realm.sh` | Realm（安装时获取最新版） | `realm` | `/etc/realm/config.toml` |

## 环境要求

- Linux，使用 systemd（Debian/Ubuntu/CentOS 等）或 OpenRC（Alpine 等）管理服务
- root 权限运行
- 需要 bash 4+（Alpine 需先手动安装 bash，见下文）
- 支持架构：x86_64、arm64、armv7、s390x、riscv64
- 依赖：`curl`、`wget`、`jq`、`openssl`、`tar`/`unzip`、`iproute2`（脚本会自动安装；bash 必须预先存在）
- Argo quick 模式会额外下载 `cloudflared`（支持 Linux amd64 / arm64 / armv7 / i386）；sing-box named 模式使用 1.14+ 内置 cloudflared，不需要额外二进制

> WireProxy-WARP 由 wgcf 注册账户，wgcf 官方仅提供 x86_64、arm64、armv7、386、s390x 二进制，暂不支持 riscv64。WARP 使用 UDP 出站，服务器需能访问 CloudFlare 的 WARP Endpoint（默认 2408 端口）。

> Realm 官方预编译包支持 x86_64、aarch64、armv7、armv6、mips/mipsel/mips64/mips64el，暂不支持 s390x、riscv64 与 32 位 x86。脚本会根据架构与 libc（glibc / musl）自动选择对应安装包。

## 安装

### Xray

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_xray.sh)
```

### sing-box

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_singbox.sh)
```

Xray / sing-box 安装流程：安装依赖 → 应用 BBR/网络优化 → 下载内核 → **交互选择入站协议** → 生成配置 → 注册服务（systemd/OpenRC）→ 启动。Xray 的 Argo 和 sing-box 的 Argo quick 模式会额外下载 `cloudflared`；sing-box 的 Argo named 模式使用内置 cloudflared。

### WireProxy-WARP

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_warp.sh)
```

WireProxy-WARP 安装流程：安装依赖 → 下载 WireProxy 与 wgcf → 设置 SOCKS5 端口和监听地址 → 注册 WARP 账户 → 生成配置 → 注册服务（systemd/OpenRC）→ 启动并验证连通性。

### Realm 端口转发

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_realm.sh)
```

Realm 安装流程：安装依赖 → 应用 BBR/网络优化 → 下载 Realm 内核 → 生成基础配置 → 注册服务（systemd/OpenRC）→ 交互添加第一条转发规则 → 启动。已安装时会询问是否保留现有规则，仅更新内核。

### Alpine Linux

Alpine 默认使用 OpenRC，且未预装 bash，请先安装 bash 再执行脚本：

```shell
apk add --no-cache bash curl ca-certificates
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_xray.sh)
```

sing-box / WARP / Realm 同理，把文件名换成 `install_singbox.sh` / `install_warp.sh` / `install_realm.sh` 即可。

脚本会自动识别服务管理器：

- systemd：注册 `/etc/systemd/system/xray.service`、`sing-box.service`、`wireproxy-warp.service` 或 `realm.service`，日志通过 `journalctl` 查看
- OpenRC：生成 `/etc/init.d/xray`、`/etc/init.d/sing-box`、`/etc/init.d/wireproxy-warp` 或 `/etc/init.d/realm`，日志写入 `/var/log/xray.log`、`/var/log/sing-box.log`、`/var/log/wireproxy-warp.log` 或 `/var/log/realm.log`

## 入站协议选择

生成配置时会提示选择要启用的协议，可多选，**至少选择一个**：

| 编号 | 脚本 | 协议 | 默认端口 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | Xray / sing-box | Shadowsocks | 32443 | 加密方式 `2022-blake3-aes-128-gcm`，密码自动生成 |
| 2 | Xray / sing-box | VLESS + Reality | 443 | `xtls-rprx-vision`，自动测速选择伪装目标 |
| 3 | Xray / sing-box | VMess + WS + TLS | 2053 | WS 路径每次生成时随机，支持 CDN 回源 |
| 4 | sing-box | Hysteria2 | 8443/UDP | QUIC，密码自动生成 |
| 4 | Xray | Argo 隧道 | 本地 WS 随机高位端口 | 明文 VMess-WS + 外部 cloudflared，支持 quick / named / local |
| 5 | sing-box | Argo 隧道 | 本地 WS 随机高位端口 | quick 用外部 cloudflared；named 用 sing-box 内置 cloudflared |

输入方式：

- 单选：`1`
- 多选：`1,3` 或 `2 3`
- 全选：`all`

选择协议后会逐个询问已启用协议的端口：

- **直接回车**：使用上表中的默认端口
- **输入自定义端口**：范围 1–65535，多个协议之间不能重复（重复会要求重新输入）

说明：

- VLESS-Reality 与 VMess-WS-TLS 共用固定 UUID `8326d9fd-3246-4ca0-aa48-894f0e7d96d6`；Xray / sing-box 的 Argo 明文 VMess-WS 入站也复用该 UUID。
- VMess-WS-TLS 与 Hysteria2 需要证书；只选 Shadowsocks / VLESS-Reality 时无需证书。
- Shadowsocks 密码、Hysteria2 密码、Reality 密钥对和 Short ID 在每次重新生成配置时都会更新。
- Hysteria2 使用 UDP，端口检查会分别检查 TCP 与 UDP；请确保本机防火墙和云安全组放行对应的 UDP 端口。
- Hysteria2 不能通过 Cloudflare Argo 等仅支持 HTTP/WebSocket 的隧道转发。
- Xray 的第 4 项是 Argo 隧道，会新增一个仅监听 `127.0.0.1` 的明文 VMess-WS 入站；详细配置见下文。
- sing-box 的第 5 项也是 Argo 隧道：quick 模式使用外部 cloudflared，named 模式使用 sing-box 1.14+ 内置 cloudflared；详细配置见下文。

### Hysteria2

Hysteria2 复用 `/etc/sing-box/cert/` 下的证书：

- 使用脚本生成的临时自签证书时，`sb info` 会输出带 `insecure=1` 的链接，客户端需开启跳过证书校验（Mihomo 为 `skip-cert-verify: true`）。
- 使用正式证书时，脚本会优先从证书 SAN/CN 中提取具体域名作为 SNI；如果只有通配符证书，会提示输入实际使用的子域名。`sb info` 输出的链接不包含 `insecure`。
- 更换证书后建议重新执行 `sb gen`，让 SNI 与新证书重新匹配；如果证书域名没有变化，也可以只重新执行 `sb info`。

### Xray Argo 隧道

Xray 的第 4 项会在本机启动一个仅监听 `127.0.0.1` 的明文 VMess-WS 入站，再由外部 `cloudflared` 通过 Cloudflare Argo 隧道对外提供服务。支持三种模式：

- **quick**：使用随机 `*.trycloudflare.com` 域名，无需 Cloudflare 账号；cloudflared 每次重启后域名都会变化。
- **named**：使用 Cloudflare Zero Trust 的 Tunnel Token，域名固定；需要在 Cloudflare 面板创建隧道，并把 Public Hostname 指向 `http://127.0.0.1:<本地 WS 端口>`。
- **local**：使用 `cloudflared` CLI 托管隧道。脚本会引导完成一次浏览器授权，自动创建/复用隧道、写入 DNS 记录并生成 `config.yml`，域名固定，不需要面板配置。

配置流程会询问：

1. Argo 模式（quick / named / local）
2. cloudflared 连接 Cloudflare 边缘使用 IPv4 还是 IPv6
3. named / local 模式额外询问公开域名
4. named 模式询问 Tunnel Token；local 模式执行浏览器授权、创建隧道并绑定 DNS

安装后管理：

```shell
xr argo            # 交互菜单
xr argo status     # 查看模式、域名、服务状态
xr argo info       # 查看 Argo 节点链接
xr argo bind       # local 模式：绑定/改绑固定域名（可传域名参数）
xr argo restart    # 重启隧道（quick 模式会生成新域名）
xr argo log        # 查看 cloudflared 日志
xr argo update     # 更新 cloudflared
xr argo uninstall  # 仅卸载 Argo
```

说明：

- cloudflared 路径：`/usr/local/bin/cloudflared-argo`
- 服务名：`cloudflared-argo`，日志：`/var/log/cloudflared-argo.log`
- 支持架构：x86_64、arm64、armv7、i386；不支持 s390x / riscv64
- Argo 只代理 HTTP/WebSocket/TCP，不能转发 Hysteria2 等 UDP 协议
- 服务器不需要放行 Argo 入站端口，但需要能出站访问 Cloudflare
- named 模式的 Token 保存在 `/etc/xray/argo/token`（权限 `600`）
- local 模式的状态保存在 `/etc/xray/argo/`：`tunnel_name`、`tunnel_uuid`、`credentials_file`、`origin_cert`、`config.yml`
- local 模式的隧道名为 `xray-<域名转换>`；复用已有隧道前会检查本机凭证文件，缺失时只提示、不会自动删除云端隧道
- local 模式绑定 DNS 时，如果记录已存在，必须手动确认才会加 `--overwrite-dns`
- 授权文件默认在 `/root/.cloudflared/cert.pem`，权限 `600`；换机器时可复制该目录跳过再次授权（也可用 `TUNNEL_ORIGIN_CERT` 指定路径）
- local 模式创建的是云端资源；如果中途取消或本机配置写入失败，隧道/DNS 记录不会自动回收，需要在 Cloudflare 面板手动清理
- 同一域名重复绑定会复用同名隧道；换域名会新建一个 `xray-<新域名>` 隧道，避免覆盖旧绑定
- 卸载只清理本机服务和状态，云端隧道与 DNS 记录会保留；按提示执行 `cloudflared tunnel delete <name>` 才会删除
- 本地 WS 端口默认随机高位，WS 路径在每次 `xr gen` 时随机生成
- quick 模式启动后会轮询日志等待域名；20 秒未获取到会自动重启 cloudflared 重试一次
- named / local 模式启动后会轮询日志确认连接已注册，而不是固定等待几秒
- 修改 Argo 模式或端口后执行 `xr gen`，再执行 `xr restart` 使配置生效

### sing-box Argo 隧道

sing-box 的第 5 项支持两种模式：

- **quick**：外部 cloudflared + 本地明文 VMess-WS，随机 `*.trycloudflare.com` 域名。选择后会自动下载 `cloudflared` 并注册 `cloudflared-singbox-argo` 服务。
- **named**：sing-box 1.14+ 内置 `cloudflared` 入站 + 本地明文 VMess-WS，使用 Tunnel Token，域名固定。不需要额外下载 cloudflared。

配置流程：

1. 选择 quick / named
2. 选择 cloudflared 连接 Cloudflare 边缘使用 IPv4 还是 IPv6
3. named 模式额外输入 Tunnel Token 和公开域名

named 模式需要在 Cloudflare Zero Trust 面板把 Public Hostname 指向：

```text
http://127.0.0.1:<本地 WS 端口>
```

管理：

```shell
sb argo            # 交互菜单
sb argo status
sb argo info
sb argo start      # quick 启动外部 cloudflared；named 等同 sb start
sb argo stop       # quick 停止外部 cloudflared；named 等同 sb stop
sb argo restart
sb argo log        # quick 看 cloudflared 日志；named 看 sing-box 日志
sb argo update     # quick 更新 cloudflared；named 请使用 sb update
sb argo uninstall  # 仅卸载 Argo 外部服务与状态
```

说明：

- quick 的 cloudflared 路径：`/usr/local/bin/cloudflared-singbox-argo`
- quick 服务名：`cloudflared-singbox-argo`，日志：`/var/log/cloudflared-singbox-argo.log`
- named 的 Token 写入 `/etc/sing-box/config.json`，脚本会将该文件权限设为 `600`
- named 模式会自动添加路由规则，放行内置 cloudflared 对 `127.0.0.1` 的连接，避免被 `ip_is_private` 规则拒绝
- quick 支持架构：x86_64、arm64、armv7、i386；named 的架构随 sing-box
- 本地 WS 端口默认随机高位，WS 路径在每次 `sb gen` 时随机生成
- quick 模式启动后会轮询日志等待域名；20 秒未获取到会自动重启 cloudflared 重试一次
- Argo 只代理 HTTP/WebSocket/TCP，不能转发 Hysteria2 等 UDP 协议
- 服务器不需要放行 Argo 入站端口，但需要能出站访问 Cloudflare
- 修改 Argo 模式或端口后执行 `sb gen`，再执行 `sb restart` 使配置生效

## 住宅 IP 出站

生成配置时还会询问是否启用住宅 IP 出站：

1. 选择是否启用
2. 选择代理类型：HTTP 或 SOCKS5
3. 输入代理地址：`host:port`（兼容 `http://`、`socks5://` 前缀）
4. 输入用户名和密码（**均可留空**，无认证代理直接回车）
5. 选择出站模式：
   - **全局**（默认）：所有流量都从住宅 IP 出站
   - **规则**：仅规则集中的域名从住宅 IP 出站，其余流量直连

规则模式使用仓库中的共享规则集 [`rules/residential.json`](rules/residential.json)（sing-box source 格式），当前包含 Claude / Anthropic、监控风控、支付验证、Google 以及出口 IP 检测等域名：

- Xray 会将其转换为内联的 `domain:` / `keyword:` 路由规则，并把默认出站恢复为直连
- sing-box 会将其转换为 `domain_suffix` / `domain_keyword` 路由规则，并把 `route.final` 设为直连
- 生成配置时优先从 GitHub 拉取规则集，并缓存到 `/etc/xray/residential-rules.json` 或 `/etc/sing-box/residential-rules.json`；拉取失败且无缓存时会中止生成，避免静默降级

其他行为：

- 全局模式下，Xray 会把 53 端口 DNS 查询固定为直连，避免 DNS 走 HTTP/SOCKS 代理失败
- `xr info` / `sb info` 会显示当前住宅代理的类型、地址、认证信息、出站模式以及规则条数
- 重新执行 `xr gen` / `sb gen` 会重新询问并覆盖现有出站配置
- 修改 `rules/residential.json` 后重新执行 `xr gen` / `sb gen` 即可生效（规则集在生成时拉取）

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

## Realm 端口转发

[Realm](https://github.com/zhboner/realm) 是一个用 Rust 编写的高性能端口转发工具，适合把中转机的端口转发到落地机，常用于中转 Hysteria2、Reality、游戏加速等 TCP/UDP 流量。

核心特性：

- 默认同时转发 TCP + UDP，UDP 可用于 Hysteria2、游戏等场景
- 支持单条规则只开 TCP 或只开 UDP
- 支持 `through` 指定出口 IP、`interface` 指定出口网卡
- 支持 `extra_remotes` + `balance` 在多个落地之间做负载均衡（`roundrobin` / `iphash`）
- 规则增删改后自动重启服务，配置权限 `600`，每次保存前自动备份为 `config.toml.bak`

### 规则管理

安装后无参数运行 `realm` 进入交互菜单，也可以直接使用子命令：

```shell
realm list                          # 查看所有转发规则
realm add                           # 交互添加规则
realm add 6666 1.2.3.4 443         # 监听 6666 -> 1.2.3.4:443（TCP+UDP）
realm add 8443 "[2001:db8::1]" 443 hy2-relay udp
                                     # 监听 8443 -> [2001:db8::1]:443，仅 UDP，带名称
realm edit 1                        # 修改规则 1（直接回车保留当前值）
realm del 2                         # 删除规则 2
realm check                         # 检查配置结构
```

交互添加规则时会依次询问：

1. 规则名称（可选，仅用于展示）
2. 本机监听地址和端口（监听地址默认 `0.0.0.0`；若端口被占用会拒绝）
3. 落地地址和端口（IPv6 使用 `[2001:db8::1]` 形式）
4. 转发模式：TCP+UDP / 仅 TCP / 仅 UDP
5. 是否配置高级选项：`through`、`interface`、`extra_remotes`、`balance`

> Realm 本身没有 `--test` / `-t` 配置检查参数，`realm check` 只做配置结构、端口重复和地址格式检查。修改后若服务未能启动，请执行 `realm log` 查看 Realm 的真实报错。

### 配置与限制

- 配置文件：`/etc/realm/config.toml`，由脚本按 `[[endpoints]]` 分块管理
- 内核：`/usr/local/bin/realm-bin`，管理命令：`/usr/local/bin/realm`
- 修改规则建议使用 `realm edit` / `realm del`；手动编辑配置后执行 `realm restart`
- 转发是否可用还取决于**落地机防火墙/安全组是否允许中转机 IP 访问落地端口**
- Realm 只做端口转发，不提供加密或伪装；需要 TLS / Reality / Hysteria2 时，落地机仍需运行对应服务
- 使用 `balance` 时，Realm 官方预编译包已内置 `balance` 特性；如果自行替换为 slim 版本则不可用
- 监听端口需在本机和云安全组放行；可执行 `realm fw <端口>` 自动放行 ufw / firewalld 的 TCP+UDP 端口

## 服务管理

安装完成后会部署管理命令，无参数运行进入交互菜单：

```shell
xr          # Xray 交互菜单
sb          # sing-box 交互菜单
warp        # WireProxy-WARP 交互菜单
realm       # Realm 交互菜单
```

| 子命令 | Xray | sing-box | 说明 |
| --- | :---: | :---: | --- |
| `start` | ✅ | ✅ | 启动服务 |
| `stop` | ✅ | ✅ | 停止服务 |
| `restart` | ✅ | ✅ | 重启服务 |
| `status` | ✅ | ✅ | 查看运行状态 |
| `log` | ✅ | ✅ | 实时查看日志 |
| `info` | ✅ | ✅ | 查看入站节点信息（并刷新 `links.txt`） |
| `links` | ✅ | ✅ | 查看已保存的节点链接（不重新探测网络） |
| `check` / `test` | ✅ | ✅ | 检查配置文件 |
| `edit` | ✅ | ✅ | 编辑配置并可选重启 |
| `gen` | ✅ | ✅ | 重新选择协议并生成配置 |
| `bbr` | ✅ | ✅ | 查看/重新应用 BBR 优化 |
| `update` | ❌ | ✅ | 更新 sing-box 内核 |
| `argo` | ✅ | ✅ | 管理 Argo 隧道（status/info/start/stop/restart/log/update/uninstall）；Xray 额外支持 `argo bind` |
| `uninstall` | ✅ | ✅ | 卸载脚本与内核 |

Xray 启用 Argo quick 后，`xr start` / `xr stop` / `xr restart` / `xr status` 会同时管理 Xray 和外部 cloudflared；sing-box quick 模式同理。sing-box named 模式的 cloudflared 内置于 sing-box，随 `sb start` / `sb stop` / `sb restart` 一起管理。

示例：

```shell
xr info
sb restart
warp ip
```

WireProxy-WARP 的 `warp` 支持上表中的 `start`、`stop`、`restart`、`status`、`log`、`info`、`check`、`test`、`edit`、`uninstall`，以及专用的 `ip`、`endpoint`、`port`、`stack`、`reg`、`plus` 子命令。

Realm 的 `realm` 支持：

| 子命令 | 说明 |
| --- | --- |
| `start` / `stop` / `restart` | 服务控制 |
| `status` | 查看内核版本、运行状态与规则数量 |
| `log` | 实时查看日志（systemd 用 `journalctl -u realm`） |
| `list` | 查看转发规则 |
| `add` | 交互或非交互添加规则 |
| `edit [ID]` | 修改规则 |
| `del [ID]` | 删除规则 |
| `check` | 检查配置结构 |
| `config` | 编辑配置文件并做结构检查 |
| `update` | 更新 Realm 内核到最新版（保留规则） |
| `bbr` | 查看/重新应用 BBR 优化 |
| `fw <端口>` | 用 ufw / firewalld 放行 TCP+UDP 端口 |
| `uninstall` | 卸载 Realm 与快捷命令 |

> `xr gen` / `sb gen` 会覆盖现有 `config.json`，并重新生成 Shadowsocks 密码、Reality 密钥和 Short ID，执行后需同步更新客户端节点。

## 节点信息

`xr info` / `sb info` 会读取当前配置并输出：

- 服务器地址、端口、UUID 或 Shadowsocks 密码
- 出口识别信息（国家-城市-ASN，来自 `speed.cloudflare.com/meta`，同时追加到节点备注）
- 分享链接：`vless://`、`vmess://`（含 Argo）、`ss://`、`hysteria2://`
- Mihomo 可用的节点 JSON（添加到 `proxies` 数组）
- 启用 Argo 时，`xr info` / `sb info` 会输出当前 quick 域名或 named 固定域名对应的 `vmess://` 链接

输出会同时保存到 `/etc/xray/links.txt` 或 `/etc/sing-box/links.txt`（权限 `600`）。终端断开后可用 `xr links` / `sb links` 直接查看；Argo quick 域名会随 cloudflared 重启变化，此时应重新执行 `xr info` / `sb info` 刷新文件。

## 证书

启用 VMess-WS-TLS 或 Hysteria2 时，证书需放置在：

```text
/etc/xray/cert/fullchain.pem
/etc/xray/cert/privkey.pem

/etc/sing-box/cert/fullchain.pem
/etc/sing-box/cert/privkey.pem
```

- VMess-WS-TLS 与 Hysteria2 共用同一份证书。
- 若证书缺失，脚本会自动生成 1 年有效期的临时自签证书，仅用于让服务正常启动。
- 使用临时自签证书时，Hysteria2 客户端必须开启跳过证书校验（`insecure=1` / `skip-cert-verify: true`）。
- 对外提供服务前请替换为正式证书（如 Let's Encrypt）。
- 只启用 Shadowsocks 或 VLESS-Reality 时不需要配置证书。
- Argo 隧道的本地 VMess-WS 入站是明文 HTTP，不需要 Xray 侧证书；客户端到 Cloudflare 边缘的 TLS 由 Cloudflare 提供。

## 端口与防火墙

按实际选择的协议放行对应端口：

| 协议 | 默认端口 | 协议类型 |
| --- | --- | --- |
| VLESS + Reality | 443 | TCP |
| VMess + WS + TLS | 2053 | TCP |
| Shadowsocks | 32443 | TCP + UDP |
| Hysteria2 | 8443 | UDP |
| Argo 本地 VMess-WS | 安装时随机（可自定义） | TCP（仅 `127.0.0.1`） |
| WireProxy SOCKS5 | 安装时随机 / 自定义 | TCP |
| Realm 转发规则 | 添加规则时自定义 | TCP + UDP（可只开其中一种） |

云服务器还需在安全组中放行相同端口。如果生成配置时自定义了端口，请以实际配置为准；`xr info` / `sb info` / `warp info` / `realm list` 会显示最终使用的端口。

Hysteria2 是 UDP/QUIC 协议，除本机防火墙外，云安全组也必须放行对应的 **UDP** 端口。

Argo 本地 VMess-WS 仅监听 `127.0.0.1`，无需放行；对外流量由 cloudflared 主动出站连接 Cloudflare 边缘。生成配置时默认分配随机高位端口并生成随机 WS 路径，实际值可从 `xr info` / `sb info` 或配置文件中查看。

WireProxy 仅监听 `127.0.0.1` 时无需放行端口；监听 `0.0.0.0` 时需放行对应 TCP 端口，并建议启用 SOCKS5 用户名/密码认证、限制来源 IP。WARP 本身通过 UDP 连接 CloudFlare Endpoint（默认 2408），无需在服务器上放行入站 UDP。

Realm 的每条转发规则都使用自定义监听端口，需要在**中转机**放行规则对应的 TCP/UDP 端口，并在**落地机**放行落地端口（允许中转机 IP 访问）。脚本不会自动修改云安全组；本机 ufw / firewalld 可通过 `realm fw <端口>` 放行。

## BBR 与网络优化

安装时自动写入：

- `/etc/sysctl.d/99-network-bbr.conf`
- `/etc/security/limits.d/99-nofile.conf`

启用 `fq` + `bbr`，并调整 TCP 缓冲区与文件描述符上限。可通过 `xr bbr` / `sb bbr` / `realm bbr` 查看状态并重新应用。

- systemd：由 `sysctl --system` 在开机时加载
- OpenRC（Alpine）：额外写入 `/etc/local.d/99-network-bbr.start`，通过 `local` 服务开机应用；服务本身的 nofile 限制由 init 脚本中的 `rc_ulimit` 设置

## 更新与卸载

```shell
sb update          # 更新 sing-box 到最新版（named 模式的内置 cloudflared 随之更新）
sb argo update     # 更新 sing-box quick 模式使用的外部 cloudflared
xr argo update     # 更新 Xray 使用的 cloudflared
xr uninstall       # 卸载 Xray（同时清理 Argo 服务与 cloudflared）
xr argo uninstall  # 仅卸载 Xray 的 Argo 隧道
sb uninstall       # 卸载 sing-box（同时清理 Argo 外部服务与 cloudflared）
sb argo uninstall  # 仅卸载 sing-box 的 Argo
warp uninstall     # 卸载 WireProxy-WARP
realm update       # 更新 Realm 内核到最新版（保留规则）
realm uninstall    # 卸载 Realm
```

重新执行 `install_warp.sh` 时会提示是否保留现有 WARP 账户和端口设置，选择保留即可只更新 WireProxy / wgcf 程序。

重新执行 `install_realm.sh` 或 `realm install` 时也会提示是否保留现有转发规则，选择保留即可只更新 Realm 内核。

Xray 使用固定版本 `v26.6.27`，如需升级请修改脚本顶部的 `XRAY_VERSION` 后重新执行安装。
