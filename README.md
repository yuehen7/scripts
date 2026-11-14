# scripts

代理服务一键安装与管理脚本，包含 Xray 与 sing-box 两套独立实现。

| 脚本 | 内核版本 | 管理命令 | 配置文件 |
| --- | --- | --- | --- |
| `install_xray.sh` | Xray `v26.6.27`（固定版本） | `xr` | `/etc/xray/config.json` |
| `install_singbox.sh` | sing-box（安装时获取最新版） | `sb` | `/etc/sing-box/config.json` |

## 环境要求

- Linux，使用 systemd 管理服务
- root 权限运行
- 支持架构：x86_64、arm64、armv7、s390x、riscv64
- 依赖：`curl`、`wget`、`jq`、`openssl`、`tar`/`unzip`（脚本会自动安装）
- 建议安装 `iproute2`（提供 `ss` 命令），用于安装前的端口占用检查

## 安装

### Xray

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_xray.sh)
```

### sing-box

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/yuehen7/scripts/main/install_singbox.sh)
```

安装流程：安装依赖 → 应用 BBR/网络优化 → 下载内核 → **交互选择入站协议** → 生成配置 → 注册 systemd 服务 → 启动。

## 入站协议选择

生成配置时会提示选择要启用的协议，可多选，**至少选择一个**：

| 编号 | 协议 | 端口 | 说明 |
| --- | --- | --- | --- |
| 1 | Shadowsocks | 32443 | 加密方式 `2022-blake3-aes-128-gcm`，密码自动生成 |
| 2 | VLESS + Reality | 443 | `xtls-rprx-vision`，自动测速选择伪装目标 |
| 3 | VMess + WS + TLS | 2053 | WS 路径 `/175443`，支持 CDN 回源 |

输入方式：

- 单选：`1`
- 多选：`1,3` 或 `2 3`
- 全选：`all`

说明：

- VLESS-Reality 与 VMess-WS-TLS 共用固定 UUID `8326d9fd-3246-4ca0-aa48-894f0e7d96d6`。
- 仅选择 VMess-WS-TLS 时才需要域名和证书；只选 Shadowsocks / VLESS-Reality 时无需证书。
- Shadowsocks 密码、Reality 密钥对和 Short ID 在每次重新生成配置时都会更新。

## 服务管理

安装完成后会部署管理命令，无参数运行进入交互菜单：

```shell
xr          # Xray 交互菜单
sb          # sing-box 交互菜单
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
```

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

| 协议 | 端口 | 协议类型 |
| --- | --- | --- |
| VLESS + Reality | 443 | TCP |
| VMess + WS + TLS | 2053 | TCP |
| Shadowsocks | 32443 | TCP + UDP |

云服务器还需在安全组中放行相同端口。

## BBR 与网络优化

安装时自动写入：

- `/etc/sysctl.d/99-network-bbr.conf`
- `/etc/security/limits.d/99-nofile.conf`

启用 `fq` + `bbr`，并调整 TCP 缓冲区与文件描述符上限。可通过 `xr bbr` / `sb bbr` 查看状态并重新应用。

## 更新与卸载

```shell
sb update        # 更新 sing-box 到最新版
xr uninstall     # 卸载 Xray
sb uninstall     # 卸载 sing-box
```

Xray 使用固定版本 `v26.6.27`，如需升级请修改脚本顶部的 `XRAY_VERSION` 后重新执行安装。
