# N2X - 自用备份

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
