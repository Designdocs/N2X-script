#!/bin/bash
# Shared config generation helpers for N2X-script.
# Both initconfig.sh and N2X.sh will source this file when present.

# Keep in sync with the function definitions in initconfig.sh / N2X.sh.

# 检查系统是否有 IPv6 地址
check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"  # 支持 IPv6
    else
        echo "0"  # 不支持 IPv6
    fi
}

# 节点配置生成
add_node_config() {
    core="xray"
    core_xray=true
    isreality=""
    istls=""
    while true; do
        read -rp "请输入节点Node ID：" NodeID
        if [[ "$NodeID" =~ ^[0-9]+$ ]]; then
            break
        else
            echo "错误：请输入正确的数字作为Node ID。"
        fi
    done

    echo -e "${yellow}请选择节点传输协议：${plain}"
    echo -e "${green}1. Shadowsocks${plain}"
    echo -e "${green}2. Vless${plain}"
    echo -e "${green}3. Vmess${plain}"
    echo -e "${green}4. Trojan${plain}"
    echo -e "${green}5. AnyTLS${plain}"
    echo -e "${green}6. ArtX${plain}"
    read -rp "请输入：" NodeType
    case "$NodeType" in
        1 ) NodeType="shadowsocks" ;;
        2 ) NodeType="vless" ;;
        3 ) NodeType="vmess" ;;
        4 ) NodeType="trojan" ;;
        5 ) NodeType="anytls" ;;
        6 ) NodeType="artx" ;;
        * ) NodeType="shadowsocks" ;;
    esac
    if [ "$NodeType" == "vless" ]; then
        read -rp "请选择是否为reality节点？(y/n)" isreality
    fi
    if [ "$NodeType" == "anytls" ] || [ "$NodeType" == "artx" ]; then
        istls="y"
    fi

    if [[ "$isreality" != "y" && "$isreality" != "Y" &&  "$istls" != "y" ]]; then
        read -rp "请选择是否进行TLS配置？(y/n)" istls
    fi

    certmode="none"
    certdomain="example.com"
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
    ipv6_support=$(check_ipv6_support)
    listen_ip="0.0.0.0"
    if [ "$ipv6_support" -eq 1 ]; then
        listen_ip="::"
    fi
    xray_dns_opts='            "EnableDNS": false,
            "DNSType": "UseIPv4",
'
    if [ "$custom_dns_enabled" = true ]; then
        xray_dns_opts='            "EnableDNS": true,
            "DNSType": "UseIP",
'
    fi
    node_config=$(cat <<EOF
{
            "_comment": "Core 固定填 xray；NodeID 填面板节点数字 ID；NodeType 可填 shadowsocks/vless/vmess/trojan/anytls/artx；Timeout 单位为秒。",
            "Core": "$core",
            "_api_comment": "ApiHost 填面板完整 HTTP(S) 地址且不带接口路径；ApiKey 填面板对接密钥。",
            "ApiHost": "\${N2X_API_HOST}",
            "ApiKey": "\${N2X_API_KEY}",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "WebSocket": {
                "_comment": "Enabled=false 时仅使用 HTTP；URL 留空会根据 ApiHost 自动生成，也可填写完整 ws:// 或 wss:// 地址；Debug 仅排障时开启。",
                "Enabled": true,
                "URL": "",
                "Debug": false
            },
            "ListenIP": "0.0.0.0",
            "SendIP": "0.0.0.0",
            "_traffic_comment": "DeviceOnlineMinTraffic 和 ReportMinTraffic 的单位均为 KB；ReportMinTraffic=0 表示不设置最低上报流量。",
            "DeviceOnlineMinTraffic": 200,
            "ReportMinTraffic": 0,
            "_dns_comment": "EnableDNS=true 时 DNSType 可填 AsIs/UseIP/UseIPv4/UseIPv6；false 时 DNSType 不生效。",
${xray_dns_opts}            "_network_comment": "ListenIP/SendIP 可填 0.0.0.0、:: 或指定地址；EnableProxyProtocol 仅在受信任的前置代理发送 PROXY protocol 时开启；EnableUot/EnableTFO 填 true 或 false。",
            "EnableProxyProtocol": false,
            "EnableUot": true,
            "EnableTFO": true,
            "CertConfig": {
                "_comment": "CertMode 可填 none/file/http/dns/self：file 使用现有证书，http/dns 自动申请，self 生成自签证书；RejectUnknownSni=true 时拒绝未知 SNI。",
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "all.example.com",
                "_paths_comment": "http/dns/self 模式的 CertFile 和 KeyFile 支持 {domain}；file 模式请填写现有证书的实际绝对路径。",
                "CertFile": "/etc/N2X/fullchain-{domain}.cer",
                "KeyFile": "/etc/N2X/cert-{domain}.key",
                "Email": "example@gmail.com",
                "_provider_comment": "Provider 和 DNSEnv 仅 dns 模式使用；Provider 填 lego 支持的名称，例如 cloudflare、alidns。",
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

# 完整的 generate_config_file() 太长且包含大量 heredoc，暂时仍以内联版本为准；
# 之后确认无误再迁移到这里并删除重复定义。
