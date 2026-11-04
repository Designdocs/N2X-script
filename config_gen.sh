#!/bin/bash
# Shared config generation helpers for N2X-script.
#
# This file is the single implementation. initconfig.sh and N2X.sh source it
# and call into it; neither one carries its own copy any more. install.sh
# always downloads it alongside N2X.sh, so it is present on any installed
# system, and N2X.sh aborts with a clear message when it is not.
#
# 在已有配置上追加协议（而不是整份重写）的实现在 config_append.sh 里，它依赖
# 本文件的 add_node_config / build_cores_config / write_default_*_json。
#
# xray 配套文件（dns.json / custom_outbound.json / route.json）的默认内容也在
# 本文件末尾，见 write_default_*_json。
#
# Callers are expected to set, before calling add_node_config:
#   api_host_val / api_key_val  节点里写入的 ApiHost / ApiKey 值
#   custom_dns_enabled          true 时 xray 节点开启 EnableDNS/DNSType=UseIP
# and to have initialised core_xray=false / core_sing=false.

N2X_CONFIG_GEN_VERSION=4

# 检查系统是否有 IPv6 地址
check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"  # 支持 IPv6
    else
        echo "0"  # 不支持 IPv6
    fi
}

# 协议选择。
#
# 每个协议固定属于一个核心：xray 与 sing-box 各自实现不同的协议集，两者可以
# 同时运行。AnyTLS 两个核心都实现了，所以菜单里出现两次——节点用 "Core" 指定
# 走哪一个，互不影响。
#
# 设置：NodeType / core / core_xray / core_sing / isreality / istls / nocert
select_node_protocol() {
    isreality=""
    istls=""
    nocert=""

    echo -e "${yellow}请选择节点传输协议：${plain}"
    echo -e "${yellow}  —— Xray 核心 ——${plain}"
    echo -e "${green}   1. Shadowsocks${plain}"
    echo -e "${green}   2. Vless${plain}"
    echo -e "${green}   3. Vmess${plain}"
    echo -e "${green}   4. Trojan${plain}"
    echo -e "${green}   5. AnyTLS${plain}（Xray 实现）"
    echo -e "${green}   6. ArtX${plain}"
    echo -e "${yellow}  —— sing-box 核心 ——${plain}"
    echo -e "${green}   7. AnyTLS${plain}（sing-box 实现）"
    echo -e "${green}   8. Hysteria${plain}（V1/V2 由面板的「协议版本」决定）"
    echo -e "${green}   9. TUIC${plain}（仅支持 V5）"
    echo -e "${green}  10. ShadowTLS${plain}（需面板支持该协议）"
    echo -e "${green}  11. NaiveProxy${plain}"
    read -rp "请输入：" node_choice
    case "$node_choice" in
        1  ) NodeType="shadowsocks"; core="xray" ;;
        2  ) NodeType="vless";       core="xray" ;;
        3  ) NodeType="vmess";       core="xray" ;;
        4  ) NodeType="trojan";      core="xray" ;;
        5  ) NodeType="anytls";      core="xray"; istls="y" ;;
        6  ) NodeType="artx";        core="xray"; istls="y" ;;
        7  ) NodeType="anytls";      core="sing"; istls="y" ;;
        8  ) NodeType="hysteria";    core="sing"; istls="y" ;;
        9  ) NodeType="tuic";        core="sing"; istls="y" ;;
        10 ) NodeType="shadowtls";   core="sing"; nocert="y" ;;
        11 ) NodeType="naive";       core="sing"; istls="y" ;;
        *  ) NodeType="shadowsocks"; core="xray" ;;
    esac

    if [ "$core" = "sing" ]; then
        core_sing=true
    else
        core_xray=true
    fi

    if [ "$NodeType" == "vless" ]; then
        read -rp "请选择是否为reality节点？(y/n)" isreality
    fi
}

# 证书域名回车时的默认值。追加协议时由 config_append.sh 换成现有节点的域名。
DEFAULT_CERT_DOMAIN="all.nom-loc.com"

# 证书域名输入。设置：certdomain
read_cert_domain() {
    local default_domain="${cert_domain_default:-$DEFAULT_CERT_DOMAIN}"
    read -rp "请输入证书域名（回车默认 ${default_domain}）：" certdomain
    certdomain="${certdomain//[[:space:]]/}"
    certdomain="${certdomain:-$default_domain}"
}

# 证书模式选择。设置：certmode / certdomain
select_cert_mode() {
    certmode="none"
    # 不需要证书的节点保持占位值，追加协议时 config_append.sh 靠它判断能否继承。
    certdomain="all.example.com"

    if [ "$nocert" == "y" ]; then
        # ShadowTLS 直接借用握手目标站点的证书，自己不需要证书。
        echo -e "${green}ShadowTLS 借用握手目标站点的证书，无需申请自有证书，CertMode 保持 none。${plain}"
        return
    fi

    if [[ "$isreality" != "y" && "$isreality" != "Y" &&  "$istls" != "y" ]]; then
        read -rp "请选择是否进行TLS配置？(y/n)" istls
    fi

    if [[ "$isreality" != "y" && "$isreality" != "Y" && ( "$istls" == "y" || "$istls" == "Y" ) ]]; then
        read_cert_domain
        echo -e "${yellow}请选择证书申请模式：${plain}"
        echo -e "${green}1. http模式自动申请，节点域名已正确解析${plain}"
        echo -e "${green}2. dns模式自动申请，需填入正确域名服务商API参数${plain}"
        echo -e "${green}3. self模式，自签证书或提供已有证书文件${plain}"
        read -rp "请输入：" certmode
        case "$certmode" in
            1 ) certmode="http" ;;
            2 ) certmode="dns" ;;
            3 ) certmode="self" ;;
        esac
        if [ "$certmode" != "http" ]; then
            echo -e "${red}请手动修改配置文件后重启N2X！${plain}"
        fi
    fi
}

# DDNS is offered only after a certificate was configured, and never inherited
# as enabled merely because an existing node uses it.
select_ddns() {
    ddns_enabled=false
    ddns_provider="cloudflare"
    ddns_env='{}'
    case "$certmode" in
        http|dns|self|file) ;;
        *) return ;;
    esac
    local answer provider_choice
    read -rp "是否开启 DDNS 自动更新证书域名的公网 IP？[y/N]: " answer || answer=""
    if [[ ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        return
    fi
    ddns_enabled=true
    echo -e "${yellow}请选择 DDNS 服务商：${plain}"
    echo "1. Cloudflare（默认，使用 API Token）"
    echo "2. 阿里云国际平台（Alibaba Cloud DNS，使用 RAM AccessKey）"
    read -rp "请输入 [1]: " provider_choice || provider_choice=""
    case "$provider_choice" in
        2)
            ddns_provider="alidns"
            ddns_env='{"ALICLOUD_ACCESS_KEY":"ExampleAccessKey","ALICLOUD_SECRET_KEY":"ExampleSecretKey"}'
            ;;
        ""|1) ;;
        *)
            echo -e "${red}无效的 DDNS 服务商，DDNS 保持关闭。${plain}"
            ddns_enabled=false
            ;;
    esac
    if [[ "$ddns_enabled" == true ]]; then
        echo -e "${yellow}DDNS 默认更新 A 记录，每 300 秒检查一次。请检查 DDNSConfig 的域名与凭据后重启；AAAA 记录可手动设置 RecordType。${plain}"
        if [[ "$ddns_provider" == cloudflare ]]; then
            echo "Cloudflare 默认复用 CertConfig.DNSEnv.CF_DNS_API_TOKEN，也可在 DDNSConfig.DNSEnv 中单独填写。"
        fi
    fi
}

# 协议专属选项块。输出带 12 空格缩进、以逗号结尾的 JSON 片段，无内容时输出空。
node_protocol_options() {
    case "$NodeType" in
        artx )
            # 两项都是主机内存占比，内核自己的默认值就是这两个数字，写出来是为了
            # 让装完机的人知道有这两个旋钮可调，而不是必须改才能跑。
            cat <<EOF
            "ArtXOptions": {
                "WindowBudgetSharePercent": 25,
                "WindowBudgetReservePercent": 20
            },
EOF
            ;;
        shadowtls )
            local handshake="" handshake_port=""
            read -rp "请输入 ShadowTLS 握手目标域名（回车则使用面板下发的值）：" handshake
            if [[ -n "$handshake" ]]; then
                read -rp "请输入握手目标端口（回车默认 443）：" handshake_port
                [[ "$handshake_port" =~ ^[0-9]+$ ]] || handshake_port=443
            else
                handshake_port=0
            fi
            cat <<EOF
            "ShadowTLSOptions": {
                "Version": 0,
                "HandshakeServer": "$handshake",
                "HandshakeServerPort": $handshake_port,
                "StrictMode": false,
                "WildcardSNI": "off"
            },
EOF
            ;;
        naive )
            cat <<EOF
            "NaiveOptions": {
                "Network": ""
            },
EOF
            ;;
    esac
}

# 核心相关的节点选项。xray 与 sing 认的字段不同，不要互相照抄。
node_core_options() {
    if [ "$core" = "sing" ]; then
        cat <<EOF
            "EnableSniff": true,
            "EnableTFO": true,
EOF
        return
    fi

    if [ "$custom_dns_enabled" = true ]; then
        cat <<EOF
            "EnableDNS": true,
            "DNSType": "UseIP",
EOF
    else
        cat <<EOF
            "EnableDNS": false,
            "DNSType": "UseIPv4",
EOF
    fi
    cat <<EOF
            "EnableProxyProtocol": false,
            "EnableUot": true,
            "EnableTFO": true,
EOF
}

# 拼接核心选项与协议专属选项。
#
# 不能在调用处直接写 $(node_core_options)$(node_protocol_options) 后面紧跟字面
# 文本——命令替换会把每个 $(...) 结尾的换行符吃掉，两块结尾的逗号就会和后面
# 的 "CertConfig": { 粘在同一行（生成的 JSON 语法仍合法，但人工检查/编辑时
# 格式是错的）。这里用 printf 显式补回内部换行，调用处把整个函数结果单独放在
# heredoc 的一行上，末尾的换行由 heredoc 自身的换行符提供，不经过命令替换。
node_extra_options() {
    local core_opts protocol_opts
    core_opts="$(node_core_options)"
    protocol_opts="$(node_protocol_options)"
    printf '%s\n' "$core_opts"
    if [[ -n "$protocol_opts" ]]; then
        printf '%s\n' "$protocol_opts"
    fi
}

# 节点配置生成
add_node_config() {
    core="xray"
    while true; do
        read -rp "请输入节点Node ID：" NodeID
        # 判断NodeID是否为正整数
        if [[ "$NodeID" =~ ^[0-9]+$ ]]; then
            break  # 输入正确，退出循环
        else
            echo "错误：请输入正确的数字作为Node ID。"
        fi
    done

    select_node_protocol
    select_cert_mode
    select_ddns

    ipv6_support=$(check_ipv6_support)
    listen_ip="0.0.0.0"
    if [ "$ipv6_support" -eq 1 ]; then
        listen_ip="::"
    fi

    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$api_host_val",
            "ApiKey": "$api_key_val",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "WebSocket": {
                "Enabled": true,
                "URL": "",
                "Debug": false
            },
            "ListenIP": "$listen_ip",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "ReportMinTraffic": 0,
$(node_extra_options)
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/N2X/fullchain-{domain}.cer",
                "KeyFile": "/etc/N2X/cert-{domain}.key",
                "Email": "example@gmail.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "CF_DNS_API_TOKEN": "ExampleTOKEN"
                }
            },
            "DDNSConfig": {
                "Enabled": $ddns_enabled,
                "Provider": "$ddns_provider",
                "Domain": "",
                "ZoneName": "",
                "RecordType": "A",
                "Interval": 300,
                "TTL": 600,
                "IPURL": "",
                "DNSEnv": $ddns_env
            }
        },
EOF
)
    nodes_config+=("$node_config")
}

# Cores 数组生成。只写入实际用到的核心，两个核心可以并存。
build_cores_config() {
    local cores="["

    if [ "$core_xray" = true ]; then
        cores+="
    {
        \"Type\": \"xray\",
        \"Log\": {
            \"Level\": \"error\",
            \"ErrorPath\": \"/etc/N2X/error.log\"
        },
        \"ConnectionConfig\": {
            \"handshake\": 4,
            \"connIdle\": 600,
            \"uplinkOnly\": 2,
            \"downlinkOnly\": 5,
            \"statsUserUplink\": false,
            \"statsUserDownlink\": false,
            \"bufferSize\": 64
        },
        \"DnsConfigPath\": \"/etc/N2X/dns.json\",
        \"OutboundConfigPath\": \"/etc/N2X/custom_outbound.json\",
        \"RouteConfigPath\": \"/etc/N2X/route.json\",
        \"EnableBTExtraSniffing\": true
    },"
    fi

    if [ "$core_sing" = true ]; then
        cores+="
    {
        \"Type\": \"sing\",
        \"Log\": {
            \"Disable\": false,
            \"Level\": \"error\",
            \"Output\": \"\",
            \"Timestamp\": true
        },
        \"NTP\": {
            \"Enable\": false,
            \"Server\": \"time.apple.com\",
            \"ServerPort\": 0
        },
        \"OriginalPath\": \"\"
    },"
    fi

    cores+="]"
    echo "$cores" | sed 's/},]$/}]/'
}

# config.json 里的 _help 说明块。
config_help_block() {
    cat <<'EOF'
        "Log": "Level 可填 debug/info/warn/error；Output 留空输出到控制台，否则填写日志文件绝对路径。",
        "ScheduledRestart": "需支持此字段的新版二进制；默认关闭，手动添加此配置段并将 Enabled 设为 true 开启。IntervalDays 默认 3，启动或调整计划后至少运行 3×24 小时，再在首个可用的 StartTime（默认 03:00）到 EndTime（默认 05:00，不含）窗口内随机选一分钟退出重启。Timezone 留空使用服务器时区，可填 Asia/Shanghai。普通配置热重载不重置计划；更改计划、关闭后再开启或进程重启会重新计时。所有节点连接会中断，最多等待 10 秒清理；自动拉起依赖服务管理器的重启策略。",
        "Cores.Type": "Type 可填 xray 或 sing，两者可同时配置；如配置多个同类核心，可增加 Name，并在节点中用 CoreName 指定。",
        "Cores.Log": "xray 核心 Level 可填 debug/info/warning/error/none，ErrorPath 为空时输出到控制台；sing 核心 Level 可填 trace/debug/info/warn/error/fatal/panic，Output 为空时输出到控制台。",
        "Cores.ConnectionConfig": "handshake/connIdle/uplinkOnly/downlinkOnly 单位为秒；bufferSize 单位为 KB。仅 xray 核心使用。connIdle 默认 600 秒（10 分钟），按业务数据空闲计时，不是连接总时长；持续传输会刷新计时。uplinkOnly/downlinkOnly 仅在一侧结束后生效；已显式配置的值优先。",
        "Cores.Paths": "DnsConfigPath/OutboundConfigPath/RouteConfigPath 均填写绝对路径；对应文件留空时使用核心内置默认配置。仅 xray 核心使用。",
        "Cores.EnableBTExtraSniffing": "控制 BT DHT 与 UDP tracker 嗅探；不需要时设为 false。仅 xray 核心使用。",
        "Cores.Sing.NTP": "Enable=true 时 sing 核心自行校时，适用于宿主机时间不准导致 TUIC/Hysteria2 握手失败的情况；ServerPort=0 表示使用默认 123。",
        "Cores.Sing.OriginalPath": "填写自定义 sing-box 基础配置的绝对路径，留空使用内置默认；只能使用 N2X 已注册的入站/出站类型。",
        "Nodes.Basic": "Core 填 xray 或 sing；NodeID 填面板节点数字 ID；Timeout 单位为秒。",
        "Nodes.NodeType": "xray 核心可填 shadowsocks/vless/vmess/trojan/anytls/artx；sing 核心可填 shadowsocks/vless/vmess/trojan/anytls/hysteria/tuic/shadowtls/naive。anytls 两个核心都支持，用 Core 指定由谁承载。hysteria 节点填 hysteria 即可，V1/V2 由面板下发的 version 决定；tuic 仅支持 V5；shadowtls 需要面板支持该协议类型。",
        "Nodes.API": "ApiHost 填面板完整 HTTP(S) 地址且不带接口路径；ApiKey 填面板对接密钥。",
        "Nodes.WebSocket": "Enabled=false 时仅使用 HTTP；URL 留空会根据 ApiHost 自动生成，也可填写完整 ws:// 或 wss:// 地址；Debug 仅排障时开启。",
        "Nodes.Traffic": "DeviceOnlineMinTraffic 和 ReportMinTraffic 的单位均为 KB；ReportMinTraffic=0 表示不设置最低上报流量。",
        "Nodes.DNS": "EnableDNS=true 时 DNSType 可填 AsIs/UseIP/UseIPv4/UseIPv6；false 时 DNSType 不生效。仅 xray 节点使用。",
        "Nodes.Network": "ListenIP/SendIP 可填 0.0.0.0、:: 或指定地址；EnableProxyProtocol 仅在受信任的前置代理发送 PROXY protocol 时开启；EnableUot/EnableTFO 填 true 或 false。",
        "Nodes.Sing": "sing 节点用 EnableSniff 控制流量嗅探，DomainStrategy 可填 AsIs/PreferIPv4/PreferIPv6/IPv4Only/IPv6Only。",
        "Nodes.ShadowTLSOptions": "均为面板值的本地覆盖，留空或填 0 表示沿用面板下发：Version 可填 1/2/3；HandshakeServer 与 HandshakeServerPort 指定伪装握手的目标站点；StrictMode 建议仅在握手目标可控时开启；WildcardSNI 可填 off/authed/all。",
        "Nodes.ArtXOptions": "仅 artx 节点使用，两项都是主机总内存的百分比，填 0 表示沿用内核默认值：WindowBudgetSharePercent 是 ArtX 可用于接收窗口的内存占比（1..100，默认 25），该预算在连接被接受时按当时在线的连接数均分，决定还有多少并发用户能拿到最宽的窗口；WindowBudgetReservePercent 是必须留给系统上其他程序的内存占比（1..99，默认 20），窗口预算会被压低到不会把可用内存吃到这条线以下。",
        "Nodes.NaiveOptions": "Network 可填 tcp（HTTP/2）或 udp（HTTP/3），留空表示两者都监听。注意 naive 增删用户会重建监听器并断开在途连接。",
        "Nodes.CertConfig": "CertMode 可填 none/file/http/dns/self：file 使用现有证书，http/dns 自动申请，self 生成自签证书；RejectUnknownSni=true 时拒绝未知 SNI。hysteria2/tuic/naive/anytls 必须有可用证书，shadowtls 固定填 none。",
        "Nodes.CertPaths": "http/dns/self 模式的 CertFile 和 KeyFile 支持 {domain}；file 模式请填写现有证书的实际绝对路径。",
        "Nodes.CertProvider": "Provider 和 DNSEnv 仅 dns 模式使用；Provider 填 lego 支持的名称，例如 cloudflare、alidns。cloudflare 使用 CF_DNS_API_TOKEN，仅授权所需域名的 Zone/DNS/Edit 和 Zone/Zone/Read；Email 是证书账户邮箱。",
        "Nodes.DDNSConfig": "Enabled 默认 false；Provider 支持 cloudflare、alidns（阿里云国际平台）；Domain 留空沿用 CertDomain，泛域名证书须单独填写具体主机名；ZoneName 留空按公共后缀推断主域名，托管子区域须手动填写。RecordType 为 A/AAAA；Interval 秒数默认 300；TTL 默认 600，仅新建记录使用。DNSEnv 留空时复用相同 Provider 的 CertConfig.DNSEnv。IPURL 留空使用 api.ipify.org / api6.ipify.org。"
EOF
}

# ---- xray 配套文件：dns.json / custom_outbound.json / route.json ----------
#
# 这三份默认内容以前在 initconfig.sh、N2X.sh、config_append.sh 里各存一份
# heredoc，三份已经漂移：N2X.sh 少了末尾的 IPv4_out 兜底规则，config_append.sh
# 整段域名黑名单都没有。这里是唯一实现，三个调用方都改成调用本节函数。
#
# 每个函数只做一件事：把默认内容写到 $1。是否覆盖已有文件由调用方决定——
# 「生成配置」是重建，直接覆盖；「追加协议」只在文件缺失时才调用。
#
# 一律使用带引号的 <<'EOF'：route.json 的正则里含 $，不加引号时要靠 shell 恰好
# 不展开 $) 才侥幸不出错，换个正则就会被静默改写。
write_default_dns_json() {
    cat <<'EOF' > "$1"
{
  "servers": [
    "1.1.1.1",
    "8.8.8.8"
  ],
  "tag": "dns_inbound"
}
EOF
}

write_default_custom_outbound_json() {
    cat <<'EOF' > "$1"
[
    {
        "tag": "IPv4_out",
        "protocol": "freedom",
        "settings": {},
        "streamSettings": {
            "sockopt": {
                "domainStrategy": "UseIPv4v6"
            }
        }
    },
    {
        "tag": "IPv6_out",
        "protocol": "freedom",
        "settings": {},
        "streamSettings": {
            "sockopt": {
                "domainStrategy": "UseIPv6"
            }
        }
    },
    {
        "tag": "socks5-unlock",
        "protocol": "socks",
        "settings": {
            "servers": [{
                "address": "socks5.example.invalid",
                "port": 1080,
                "users": [{
                    "user": "USERNAME",
                    "pass": "PASSWORD"
                }]
            }]
        }
    },
    {
        "protocol": "blackhole",
        "tag": "block"
    }
]
EOF
}

# Upgrade existing outbound files without regenerating user configuration.
# Optional arguments select explicit files; otherwise also discover custom xray
# OutboundConfigPath values in config.json. Ordinary sourcing does not write;
# the update_shell compatibility hook below runs only during a script upgrade.
migrate_freedom_domain_strategy() {
    local py
    if command -v python3 >/dev/null 2>&1; then
        py=python3
    else
        echo "freedom 配置迁移需要 python3，原文件未改动。" >&2
        return 1
    fi
    "$py" - "${N2X_CONFIG_DIR:-/etc/N2X}" "$@" <<'PY'
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("JSON 包含重复键，拒绝改写")
        result[key] = value
    return result


def load(raw):
    return json.loads(raw, object_pairs_hook=unique_object)


def strategy(value):
    allowed = {"", "asis", "useip", "useipv4", "useipv6", "useipv4v6", "useipv6v4",
               "forceip", "forceipv4", "forceipv6", "forceipv4v6", "forceipv6v4"}
    if not isinstance(value, str) or value.lower() not in allowed:
        raise ValueError("domainStrategy/targetStrategy 无效，拒绝改写")
    return value.lower() or "asis"


def migrate(path):
    # Resolve symlinks so replacing the target does not destroy the link.
    path = path.resolve()
    if not path.exists():
        return
    with path.open("rb") as handle:
        raw = handle.read()
        original_stat = os.fstat(handle.fileno())
    outbounds = load(raw)
    if not isinstance(outbounds, list) or any(not isinstance(o, dict) for o in outbounds):
        raise ValueError("出站配置必须是对象数组，拒绝改写")
    changed = 0
    for index, outbound in enumerate(outbounds):
        settings = outbound.get("settings")
        if outbound.get("protocol") != "freedom" or not isinstance(settings, dict):
            continue
        if "domainStrategy" not in settings:
            continue
        legacy = settings["domainStrategy"]
        legacy_strategy = strategy(legacy)
        target_strategy = strategy(outbound.get("targetStrategy", ""))
        # Xray ignores AsIs freedom strategies. A non-AsIs targetStrategy also
        # takes precedence over freedom, so removing that legacy field suffices.
        if legacy_strategy != "asis" and target_strategy == "asis":
            stream = outbound.get("streamSettings")
            if stream is None:
                stream = {}
            if not isinstance(stream, dict):
                raise ValueError("出站[%d] streamSettings 不是对象" % index)
            sockopt = stream.get("sockopt")
            if sockopt is None:
                sockopt = {}
            if not isinstance(sockopt, dict):
                raise ValueError("出站[%d] sockopt 不是对象" % index)
            if "domainStrategy" in sockopt:
                if strategy(sockopt["domainStrategy"]) != legacy_strategy:
                    raise ValueError("出站[%d] 新旧 domainStrategy 冲突，请手动确认" % index)
            else:
                sockopt["domainStrategy"] = legacy
            stream["sockopt"] = sockopt
            outbound["streamSettings"] = stream
        del settings["domainStrategy"]
        changed += 1
    if not changed:
        return
    payload = (json.dumps(outbounds, ensure_ascii=False, indent=4, allow_nan=False) + "\n").encode("utf-8")
    backup = None
    backup_complete = False
    temporary = None
    try:
        # Unique names never overwrite an earlier backup. Both files retain the
        # original owner and permissions, including private SOCKS credentials.
        for is_backup, data in ((True, raw), (False, payload)):
            suffix = ".bak.freedom-domain-strategy." if is_backup else ".tmp.freedom-domain-strategy."
            fd, name = tempfile.mkstemp(prefix=path.name + suffix, dir=str(path.parent))
            if is_backup:
                backup = name
            else:
                temporary = name
            with os.fdopen(fd, "wb") as handle:
                current = os.fstat(handle.fileno())
                if (current.st_uid, current.st_gid) != (original_stat.st_uid, original_stat.st_gid):
                    os.fchown(handle.fileno(), original_stat.st_uid, original_stat.st_gid)
                os.fchmod(handle.fileno(), stat.S_IMODE(original_stat.st_mode))
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            if is_backup:
                backup_complete = True
        if path.read_bytes() != raw:
            raise ValueError("文件在迁移期间被修改，拒绝覆盖")
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary)
        if backup is not None and not backup_complete:
            os.unlink(backup)
    print("已迁移 %s 的 %d 个 freedom 旧字段；备份：%s" % (path, changed, backup))


config_dir = Path(sys.argv[1])
targets = [Path(p) for p in sys.argv[2:]]
failed = False
if not targets:
    targets.append(config_dir / "custom_outbound.json")
    config_path = config_dir / "config.json"
    if config_path.exists():
        try:
            config = load(config_path.read_bytes())
            for core in config.get("Cores", []):
                if core.get("Type") != "xray":
                    continue
                path = core.get("OutboundConfigPath", "")
                if path:
                    path = os.path.expandvars(path)
                    if "$" in path:
                        raise ValueError("OutboundConfigPath 含未解析的环境变量")
                    target = Path(path)
                    if not target.is_absolute():
                        target = Path(os.environ.get("N2X_INSTALL_DIR", "/usr/local/N2X")) / target
                    targets.append(target)
        except Exception:
            print("无法解析 %s 的自定义出站路径；继续检查默认文件，自定义路径可作为迁移函数参数传入。" % config_path, file=sys.stderr)
            failed = True
seen = set()
for target in targets:
    try:
        key = str(target.resolve())
        if key in seen:
            continue
        seen.add(key)
        migrate(target)
    except Exception as error:
        print("freedom 配置迁移失败（%s）：%s；该文件未改动。" % (target, error), file=sys.stderr)
        failed = True
sys.exit(1 if failed else 0)
PY
}

# 规则顺序即匹配顺序：先 block，再 socks5-unlock，最后 IPv4_out 兜底。
# 每条都带 "type": "field"——这是 xray 唯一定义的规则类型，老版本核心缺了它会
# 直接报错，新版本可省略，写上在任何版本都成立。
write_default_route_json() {
    cat <<'EOF' > "$1"
{
    "domainStrategy": "AsIs",
    "rules": [
        {
            "type": "field",
            "outboundTag": "block",
            "ip": [
                "geoip:private"
            ]
        },
        {
            "type": "field",
            "outboundTag": "block",
            "domain": [
                "regexp:(^|[.])(api|ps|sv|offnavi|newvector|ulog[.]imap|newloc)([.]map|)[.](baidu|n[.]shifen)[.]com",
                "regexp:(^|[.])(360|so)[.](cn|com)",
                "regexp:(^|[.])(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168)[.](info|biz|com|de|net|org|me|la)",
                "regexp:(^|[.])(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian)[.](org|com|net)",
                "regexp:(^|[.])(360)[.](cn|com|net)",
                "regexp:(^|[.])(guanjia[.]qq[.]com|qqpcmgr)",
                "regexp:(^|[.])(rising|kingsoft|duba|xindubawukong|jinshanduba)[.](com|net|org)",
                "regexp:(^|[.])(netvigator|torproject)[.](com|cn|net|org)",
                "regexp:(^|[.])(visa|mycard|gash|beanfun|bank)([.]|$)",
                "regexp:(^|[.])(gov|12377|12315|creaders|zhuichaguoji|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly)[.](cn|com|org|net|club|fr|tw|hk|eu|info|me)",
                "regexp:(^|[.])(talk[.]news[.]pts[.]org|efcc[.]org|110[.]qq|cn[.]rfi)([.]|$)",
                "regexp:(^|[.])(miaozhen|cnzz|talkingdata|umeng)[.](cn|com)",
                "regexp:(^|[.])(mycard)[.](com|tw)",
                "regexp:(^|[.])(gash)[.](com|tw)",
                "regexp:(^|[.])(pincong)[.](rocks)",
                "regexp:(^|[.])(taobao)[.](com)",
                "regexp:(^|[.])(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126)[.](com|cloud|fun|cn|gs|xyz|cc)",
                "regexp:(^|[.])(flows|miaoko)[.](pages)[.](dev)"
            ]
        },
        {
            "type": "field",
            "outboundTag": "block",
            "ip": [
                "127.0.0.1/32",
                "10.0.0.0/8",
                "fc00::/7",
                "fe80::/10",
                "172.16.0.0/12"
            ]
        },
        {
            "type": "field",
            "ruleTag": "download-block-domain",
            "outboundTag": "block",
            "domain": [
                "regexp:(^|[.])(bittorrent|utorrent)([.]|$)",
                "regexp:(^|[.])(xunlei|sandai)",
                "regexp:(^|[.])(ed2k|announce)([.]|$)"
            ]
        },
        {
            "type": "field",
            "ruleTag": "download-block-protocol",
            "outboundTag": "block",
            "protocol": [
                "bittorrent"
            ]
        },
        {
            "type": "field",
            "ruleTag": "download-block-port",
            "outboundTag": "block",
            "network": "tcp,udp",
            "port": "6881-6889,6969,2710,51413"
        },
        {
            "type": "field",
            "outboundTag": "socks5-unlock",
            "domain": [
                "domain:socks5-unlock.invalid"
            ]
        },
        {
            "type": "field",
            "outboundTag": "IPv4_out",
            "network": "udp,tcp"
        }
    ]
}
EOF
}

# Released update_shell functions re-source this downloaded module but keep
# executing their old function body. Run the new migration at that upgrade
# entry point too, so an existing server is fixed on its first script upgrade.
if [[ "${FUNCNAME[1]:-}" == "update_shell" ]]; then
    # Old updaters source this file with stderr redirected to /dev/null.
    migrate_freedom_domain_strategy 2>&1 || echo "部分 freedom 配置未能迁移，请查看上方原因；失败文件保留原内容。"
fi
