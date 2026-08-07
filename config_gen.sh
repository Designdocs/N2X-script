#!/bin/bash
# Shared config generation helpers for N2X-script.
#
# This file is the single implementation. initconfig.sh and N2X.sh source it
# and call into it; neither one carries its own copy any more. install.sh
# always downloads it alongside N2X.sh, so it is present on any installed
# system, and N2X.sh aborts with a clear message when it is not.
#
# Callers are expected to set, before calling add_node_config:
#   api_host_val / api_key_val  节点里写入的 ApiHost / ApiKey 值
#   custom_dns_enabled          true 时 xray 节点开启 EnableDNS/DNSType=UseIP
# and to have initialised core_xray=false / core_sing=false.

N2X_CONFIG_GEN_VERSION=2

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

# 证书模式选择。设置：certmode
select_cert_mode() {
    certmode="none"
    certdomain="example.com"

    if [ "$nocert" == "y" ]; then
        # ShadowTLS 直接借用握手目标站点的证书，自己不需要证书。
        echo -e "${green}ShadowTLS 借用握手目标站点的证书，无需申请自有证书，CertMode 保持 none。${plain}"
        return
    fi

    if [[ "$isreality" != "y" && "$isreality" != "Y" &&  "$istls" != "y" ]]; then
        read -rp "请选择是否进行TLS配置？(y/n)" istls
    fi

    if [[ "$isreality" != "y" && "$isreality" != "Y" && ( "$istls" == "y" || "$istls" == "Y" ) ]]; then
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

# 协议专属选项块。输出带 12 空格缩进、以逗号结尾的 JSON 片段，无内容时输出空。
node_protocol_options() {
    case "$NodeType" in
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
$(node_core_options)$(node_protocol_options)            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "all.example.com",
                "CertFile": "/etc/N2X/fullchain-{domain}.cer",
                "KeyFile": "/etc/N2X/cert-{domain}.key",
                "Email": "example@gmail.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "CF_API_KEY": "ExampleKEY",
                    "CLOUDFLARE_EMAIL": "example@gmail.com"
                }
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
            \"connIdle\": 300,
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
        "Cores.Type": "Type 可填 xray 或 sing，两者可同时配置；如配置多个同类核心，可增加 Name，并在节点中用 CoreName 指定。",
        "Cores.Log": "xray 核心 Level 可填 debug/info/warning/error/none，ErrorPath 为空时输出到控制台；sing 核心 Level 可填 trace/debug/info/warn/error/fatal/panic，Output 为空时输出到控制台。",
        "Cores.ConnectionConfig": "handshake/connIdle/uplinkOnly/downlinkOnly 单位为秒；bufferSize 单位为 KB。仅 xray 核心使用。",
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
        "Nodes.NaiveOptions": "Network 可填 tcp（HTTP/2）或 udp（HTTP/3），留空表示两者都监听。注意 naive 增删用户会重建监听器并断开在途连接。",
        "Nodes.CertConfig": "CertMode 可填 none/file/http/dns/self：file 使用现有证书，http/dns 自动申请，self 生成自签证书；RejectUnknownSni=true 时拒绝未知 SNI。hysteria2/tuic/naive/anytls 必须有可用证书，shadowtls 固定填 none。",
        "Nodes.CertPaths": "http/dns/self 模式的 CertFile 和 KeyFile 支持 {domain}；file 模式请填写现有证书的实际绝对路径。",
        "Nodes.CertProvider": "Provider 和 DNSEnv 仅 dns 模式使用；Provider 填 lego 支持的名称，例如 cloudflare、alidns。"
EOF
}
