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
    read -rp "请输入：" NodeType
    case "$NodeType" in
        1 ) NodeType="shadowsocks" ;;
        2 ) NodeType="vless" ;;
        3 ) NodeType="vmess" ;;
        4 ) NodeType="trojan" ;;
        5 ) NodeType="anytls" ;;
        * ) NodeType="shadowsocks" ;;
    esac
    if [ "$NodeType" == "vless" ]; then
        read -rp "请选择是否为reality节点？(y/n)" isreality
    fi
    if [ "$NodeType" == "anytls" ]; then
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
    xray_dns_opts=""
    if [ "$custom_dns_enabled" = true ]; then
        xray_dns_opts='            "EnableDNS": true,
            "DNSType": "UseIP",
'
    fi
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "\${N2X_API_HOST}",
            "ApiKey": "\${N2X_API_KEY}",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "0.0.0.0",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
${xray_dns_opts}            "EnableProxyProtocol": false,
            "EnableUot": true,
            "EnableTFO": true,
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "all.example.com",
                "CertFile": "/etc/N2X/fullchain.cer",
                "KeyFile": "/etc/N2X/cert.key",
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

# 完整的 generate_config_file() 太长且包含大量 heredoc，暂时仍以内联版本为准；
# 之后确认无误再迁移到这里并删除重复定义。
