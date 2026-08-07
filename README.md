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

配置生成的实现集中在 `config_gen.sh`，`initconfig.sh` 与 `N2X.sh` 只负责调用，
不再各自维护一份副本。`tests/node_protocol_matrix_test.sh` 会把全部 11 个协议跑一遍并校验产出的 JSON。

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
