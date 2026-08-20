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

## 下载拦截（BT / P2P）启停

菜单 `20. 下载拦截管理`，或命令行 `N2X download on|off|status [traffic|domain]`。
改的是 `route.json`，改完自动重启 N2X。

分成两组独立开关，因为两者的误伤面完全不同：

| 分组 | ruleTag | 拦什么 | 误伤面 |
| --- | --- | --- | --- |
| `traffic` | `download-block-protocol` | 协议嗅探判定为 `bittorrent` 的流量 | 认流量特征，基本不会误伤 |
| `traffic` | `download-block-port` | BT 常用端口 `6881-6889,6969,2710,51413` | 同上 |
| `domain` | `download-block-domain` | `bittorrent`/`utorrent`、`xunlei`/`sandai`、`ed2k`/`announce` 域名 | 认域名字样，`torrentmac`、`torrentfreak` 这类资讯/软件站会跟着被拦 |

想放行 torrent 字样的资讯/软件站又要继续拦 BT 流量，就只关 `domain` 组：

```bash
N2X download off domain
```

省略分组等同于 `all`，两组一起开关。菜单里 1/2 是切换（显示当前状态），3/4 是两组全开/全关。

不受开关影响、始终生效的：私有网段拦截、广告/风控类域名黑名单、`socks5-unlock` 分流。
域名黑名单因此拆成两条规则——常规 18 条不可开关，下载类 3 条归 `domain` 组。

关闭时把摘下来的规则原样存到 `/etc/N2X/download-block.disabled.json`（一个数组，两组
混放，靠 `ruleTag` 区分），重新开启时放回去，所以手动往这几条规则里加过的域名不会因为
关一次开关就丢。存根空了会被删掉。存根丢失也能开启，此时缺哪条补哪条，回落到
`config_gen.sh` 里的内置默认。

一组里少了一条（比如手动删了端口规则）算「已关闭」，开启时只补缺的那条，不会写重复。

实现在 `download_block.sh`。它不自己维护一份默认规则，需要默认值时是现调
`write_default_route_json` 生成一份再把带标记的规则取出来用。改 JSON 依赖 python3
（或 python），没有解释器时明确报错而不是拼字符串；`route.json` 缺失或解析失败时
一个字节都不写。插入位置固定在第一条无匹配条件的兜底规则之前——插在兜底之后的规则
永远匹配不到。

`tests/download_block_toggle_test.sh` 覆盖分组开关、互不干扰、幂等、部分缺失补齐、
存根自愈、自定义 route.json 以及菜单接线。

### 老机器升级：自动补标记

`route.json` 已存在时安装脚本一律不覆盖（用户改过的内容要保留），所以 ruleTag 之前
生成的配置里那几条 BT 规则是没有标记的，分组开关认不出来。升级会自动跑一次迁移把标记
补上：`install.sh`（`N2X update` 走的也是它）和 `N2X update_shell` 各调一次
`download_block_migrate`。幂等，跑多少次都一样。

迁移做三件事：

- `protocol: ["bittorrent"]` 的规则就地打上 `download-block-protocol`，不挪位置
- 端口含 `6881` 的规则就地打上 `download-block-port`
- 从常规域名黑名单里摘掉认识的下载类正则，另立一条带 `download-block-domain` 的规则，
  内容用当前默认——**老的宽泛正则 `(^|[^a-zA-Z]|bit|u)torrent` 就是在这一步被换成收窄版
  `(^|[.])(bittorrent|utorrent)([.]|$)` 的**，升级后 `torrentmac.net` 这类站点不再被误伤

只认得出确定的老默认值，认不出的规则一律不碰；用户已经关掉的分组也不会被塞回来
（规则不在 `route.json` 里就没得打标）。`route.json` 缺失时静默跳过，解析失败时返回
非零且一个字节都不写，且不会中断安装。

`tests/download_block_migrate_test.sh` 覆盖迁移、幂等、部分迁移、已关分组不回填、
无关配置不动、缺失/损坏处理以及升级流程接线。

## 出口解锁设置

菜单 `21. 出口解锁设置`，或 `N2X unlock add|list|clear`。交互式录入一条代理出站，同时把
指定域名的路由指过去；一条录完问「继续添加下一条？」，可以连着加。

三种录入方式：

| 方式 | 说明 |
| --- | --- |
| 1. 逐项输入（默认） | 标签、协议、地址、端口、账号密码、TLS 一项项问 |
| 2. 粘贴代理链接 | `socks5://user:pass@host:port` 这类链接，自动提取字段 |
| 3. 粘贴完整出站 JSON | 直接贴一个 `{ ... }` 对象，原样写入 |

三种方式最后都要逐条录入解锁域名，走同一套校验。

### 方式 2：代理链接

支持 `http://` `https://` `socks://` `socks5://` `socks5h://`。

- `https://` 映射成 http 出站 + TLS；其余映射成明文
- `socks5h` 与 `socks5` 同等对待——它的区别是 DNS 由代理端解析，而 xray 的 socks 出站
  本来就把域名发给代理
- 账号密码的百分号编码会还原，所以密码里带 `@` `:` `/` 也不会解析错
- IPv6 写成 `socks5://[2001:db8::1]:1080`，方括号会被脱掉
- 省略端口时按协议取默认值（http 80 / https 443 / socks 1080）
- 路径和查询串直接忽略

解析出来的字段照样走完整校验，再问标签和解锁域名。

### 方式 3：完整 JSON

粘贴一个出站对象，**粘完按一次回车再按一次空回车结束**。内容原样写入，不做重建，所以
`streamSettings`、`mux` 这些字段一字不差地保留——贴 vless/trojan 之类的出站也可以。

校验：必须是合法 JSON 且是 `{ }` 对象；必须有非空 `protocol`；`protocol` 是 `http`/`socks`
时还要求 `settings.servers[0]` 有 `address` 和数字型 `port`。JSON 里带 `tag` 的话必须和你
填的标签一致，不然菜单显示的和文件里的会对不上。`protocol` 不在已知列表里只警告不拦。

一条配置同时改两个文件：

```jsonc
// custom_outbound.json —— 插在 block 之前（即 IPv4_out / IPv6_out 之后）
{
    "tag": "http-unlock",
    "protocol": "http",
    "settings": { "servers": [{ "address": "abc.decodo.com", "port": 10003,
                                "users": [{ "user": "...", "pass": "..." }] }] },
    "streamSettings": { "security": "tls",
                        "tlsSettings": { "serverName": "abc.decodo.com",
                                         "allowInsecure": false } }
}

// route.json —— 插在末尾兜底规则之前
{
    "type": "field",
    "ruleTag": "custom-unlock-http-unlock",
    "outboundTag": "http-unlock",
    "domain": ["geosite:anthropic", "geosite:openai", "geosite:google-deepmind"]
}
```

没填账号就不写 `users`，没开 TLS 就不写 `streamSettings`，不留空壳字段。

### 录入时的校验

| 项 | 规则 |
| --- | --- |
| 标签 | `[A-Za-z0-9][A-Za-z0-9_.-]*`，不能撞 `IPv4_out`/`IPv6_out`/`block`/`socks5-unlock`，也不能和已有的重名 |
| 协议 | 只收 `http` / `socks`（xray 里 socks5 的协议名就是 `socks`） |
| 地址 | 域名、IPv4 或 IPv6，不接受带 `://`、端口或空格的写法 |
| 端口 | 1-65535 的纯数字，写进 JSON 时是数字不是字符串 |
| 账号密码 | 要么都填要么都不填 |
| 域名条目 | `geosite:` / `domain:` / `full:` / `regexp:` / `ext:` 前缀，或裸域名；至少一条 |

校验不过会当场重问那一项，不会把半截配置写进去。密码里的引号、反斜杠交给 json 库转义，
不拼字符串。

### 位置与生效

`route.json` 的规则插在**第一条无匹配条件的兜底规则之前**——插在兜底之后永远匹配不到。

`custom_outbound.json` 的出站插在 `block` **之前**，也就是 `IPv4_out` / `IPv6_out` 之后：

```
0. IPv4_out       <- 默认出站
1. IPv6_out
2. socks5-unlock
3. http-unlock    <- 新加的排这里
4. block
```

出站顺序不影响规则是否生效（路由是靠 `outboundTag` 找出站的），它唯一的作用是
**列表第一条会成为默认出站**（`app/proxyman/outbound` 的 `AddHandler` 把第一个注册的
handler 存成 `defaultHandler`）。所以关键是别占掉第 0 位：默认 `route.json` 最后一条
`network: udp,tcp` 的兜底规则会兜住所有连接，默认出站平时用不上，但一旦那条兜底被删，
未命中任何规则的流量就会全部走默认出站——那不该是一条计费的解锁代理。

`block` 恰好排在第 0 位这种畸形配置，会退让到第 1 位，不去擅自重排用户已有的出站。

两个文件同成同败：全程在内存里改、两边都校验通过才落盘，任一步失败两个文件都不动。

### 清除自定义

`N2X unlock clear`（菜单 3）把两个文件恢复成 `config_gen.sh` 里的默认内容。这不只是删解锁
配置——**你在这两个文件里做过的任何手改都会一并消失**（`socks5-unlock` 里填过的账号、自己
加的路由规则等）。所以：

- 需要输入大写 `YES` 才执行
- 执行前各备份一份 `.bak.<时间戳>` 到同目录
- **下载拦截两组的开关状态会被保留**：恢复默认会把三条 BT 规则写回开启态，这里会先记下
  原状态、恢复完再按原样关回去，不会因为清理解锁配置就把你关掉的拦截又打开

`tests/outbound_unlock_test.sh` 覆盖校验、写入位置、TLS/无 TLS、无账号、标签冲突、
失败不写、两文件同成同败、清除与备份、下载拦截状态保留以及菜单接线。

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
