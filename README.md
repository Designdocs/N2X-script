# N2X - 自用备份

## 支持的协议与核心

N2X 同时运行 xray 与 sing-box 两个核心，配置向导（`N2X config` / `initconfig.sh`）
按协议自动选择核心并写入对应的 `Cores` 条目：

| 协议 | 核心 | 证书 |
| --- | --- | --- |
| Shadowsocks / Vless / Vmess / Trojan | xray | 可选（vless 支持 reality） |
| AnyTLS | xray **或** sing-box | 必需 |
| ArtX | xray | 必需 |
| Hysteria2 / TUIC | sing-box | 必需 |
| ShadowTLS | sing-box | 不需要，借用握手目标站点的证书 |
| NaiveProxy | sing-box | 必需 |

AnyTLS 在菜单里出现两次，分别对应 xray 与 sing-box 两套实现，可以同时部署在不同节点上，
互不影响；节点里的 `"Core"` 字段决定由哪个核心承载。

NaiveProxy 增删用户会重建监听器并断开在途连接（sing-box 的 naive 入站没有在线用户管理
接口），只在面板真的改动该节点用户时发生。不能接受这一点就不要使用 naive 节点。

配置生成的实现集中在 `config_gen.sh`，`initconfig.sh`、`N2X.sh`、`config_append.sh` 与
`install.sh` 只负责调用，不再各自维护一份副本。`tests/node_protocol_matrix_test.sh` 会把
全部 11 个协议跑一遍并校验产出的 JSON。

xray 配套文件 `dns.json` / `custom_outbound.json` / `route.json` 的默认内容同样只有
`config_gen.sh` 一份（`write_default_*_json`）。全新安装时由 `install.sh` 写入，写不出来会
明确报错——这三个文件是 `Cores.Paths` 指向的路径，xray 读不到会直接 panic。已存在的文件
一律不覆盖。`tests/install_side_files_test.sh` 覆盖这段逻辑。

## 新增协议：追加还是重建

菜单里是两件不同的事，别用错：

| 菜单 | 命令 | 行为 |
| --- | --- | --- |
| 15. 生成 N2X 配置文件 | `N2X generate` | **重建**：备份旧文件后整份重写，之前配好的节点会全部消失 |
| 16. 增加协议配置 | `N2X addnode` | **追加**：只往 `Nodes` 里加新节点，其余内容原样保留 |

追加（`config_append.sh`）的具体行为：

- 只在缺少对应核心时才往 `Cores` 里补一条。新节点走 sing 而配置里只有 xray，就补一条 sing；
  该核心已存在则不动它，已经改过的 `ConnectionConfig`、`NTP` 等参数都保留。
- `NodeID + 协议 + 核心`三者都相同的节点视为重复，跳过并提示，不会写进去。同一个 NodeID
  配不同协议是允许的。
- ApiHost/ApiKey 默认沿用现有节点。现有值是 `${N2X_API_HOST}` 这类占位符时直接照抄，
  不会把 `.env` 里的明文写进配置。
- 新节点的证书信息（`CertDomain`/`Email`/`Provider`/`DNSEnv`）在仍是占位值时，
  从现有节点继承，并在合并时打印继承了哪些字段。
- 新增 xray 核心时补齐 `dns.json`、`custom_outbound.json`、`route.json`——xray 读不到
  `RouteConfigPath`/`OutboundConfigPath` 指向的文件会直接 panic。已存在的文件一律不覆盖。
- 合并前会把原文件备份到 `config.json.bak`；解析失败时不做任何改动。合并依赖 python3
  （或 python），没有解释器时会明确报错而不是去拼字符串。
- 配置里如果有注释或尾逗号（N2X 自己能读，标准 JSON 不能），会先提示注释将丢失并等确认。

`tests/append_protocol_test.sh` 覆盖上述行为。

## 最小诱饵 Web 服务

N2X 安装和升级会部署一个独立的本地 Web companion。它使用同一份 N2X 二进制，仅监听 loopback，不占用节点公网端口，也不依赖 Caddy 或 Nginx。

默认配置文件内容：

```dotenv
N2X_ARTX_DECOY_LISTEN=127.0.0.1:60443
```

需要修改端口时，编辑 `/etc/N2X/artx-decoy.env`，然后执行：

```bash
systemctl restart N2X-artx-decoy N2X
N2X decoy status
```

管理命令：`N2X decoy status`、`N2X decoy restart`、`N2X decoy log`。`restart` 会先重启并检查诱饵服务，然后重启 N2X 主服务，使修改后的监听地址同时生效。诱饵服务启动失败只会产生告警，不会阻止 N2X 主服务和原有协议运行。

管理脚本更新会校验 HTTPS 证书和 shell 语法，再原子替换本地文件。完整 release checksum 绑定需要发布流程提供稳定的签名清单，作为后续发布加固项，本轮不伪造未存在的校验值。

# 一键安装

```
wget -N https://raw.githubusercontent.com/Designdocs/N2X-script/main/install.sh && bash install.sh
```
