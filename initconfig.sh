#!/bin/bash
# 一键配置

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/config_gen.sh" ]]; then
    source "$SCRIPT_DIR/config_gen.sh"
elif [[ -f /usr/local/N2X/config_gen.sh ]]; then
    source /usr/local/N2X/config_gen.sh
fi

# 检查系统是否有 IPv6 地址
check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"  # 支持 IPv6
    else
        echo "0"  # 不支持 IPv6
    fi
}

add_node_config() {
    core="xray"
    core_xray=true
    isreality=""
    istls=""
    while true; do
        read -rp "请输入节点Node ID：" NodeID
        # 判断NodeID是否为正整数
        if [[ "$NodeID" =~ ^[0-9]+$ ]]; then
            break  # 输入正确，退出循环
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
    xray_dns_opts=""
    if [ "$custom_dns_enabled" = true ]; then
        xray_dns_opts='            "EnableDNS": true,
            "DNSType": "UseIP",
'
    fi
    # 根据是否有 .env 决定 ApiHost/ApiKey 的值
    if [ "$use_env_vars" = true ]; then
        api_host_val='${N2X_API_HOST}'
        api_key_val='${N2X_API_KEY}'
    else
        api_host_val="$config_api_host"
        api_key_val="$config_api_key"
    fi

    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$api_host_val",
            "ApiKey": "$api_key_val",
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

generate_config_file() {
    echo -e "${yellow}N2X 配置文件生成向导${plain}"
    echo -e "${red}请阅读以下注意事项：${plain}"
    echo -e "${red}1. 目前该功能正处测试阶段${plain}"
    echo -e "${red}2. 生成的配置文件会保存到 /etc/N2X/config.json${plain}"
    echo -e "${red}3. 原来的配置文件会保存到 /etc/N2X/config.json.bak${plain}"
    echo -e "${red}4. 目前仅部分支持TLS${plain}"
    echo -e "${red}5. 使用此功能生成的配置文件会自带审计，确定继续？(y/n)${plain}"
    read -rp "请输入：" continue_prompt
    if [[ "$continue_prompt" =~ ^[Nn][Oo]? ]]; then
        exit 0
    fi

    if [[ -d /etc/V2bX ]]; then
        echo -e "${yellow}提示：检测到旧目录 /etc/V2bX，本向导生成的新配置会使用 /etc/N2X 路径。${plain}"
    fi

    # 判断是否已有 .env 文件，若无则在向导中收集 ApiHost/ApiKey 直接写入 config
    use_env_vars=true
    config_api_host=""
    config_api_key=""
    if [[ ! -f /etc/N2X/.env ]]; then
        echo -e "${yellow}未检测到 /etc/N2X/.env，将在配置文件中直接填写 ApiHost 和 ApiKey。${plain}"
        use_env_vars=false
        while [[ -z "$config_api_host" ]]; do
            read -rp "请输入面板 API 地址 (ApiHost，例如 https://panel.example.com): " config_api_host
        done
        while [[ -z "$config_api_key" ]]; do
            read -rp "请输入面板 API KEY (ApiKey): " config_api_key
        done
    else
        echo -e "${green}已检测到 /etc/N2X/.env，ApiHost/ApiKey 将从环境变量读取。${plain}"
    fi

    nodes_config=()
    first_node=true
    core_xray=false
    read -rp "是否开启自定义 DNS（仅 xray 生效：DnsConfigPath=/etc/N2X/dns.json + xray 节点 EnableDNS/DNSType=UseIP）？(y/n) " enable_custom_dns
    if [[ "$enable_custom_dns" == "y" || "$enable_custom_dns" == "Y" ]]; then
        custom_dns_enabled=true
    else
        custom_dns_enabled=false
    fi
    
    while true; do
        if [ "$first_node" = true ]; then
            first_node=false
            add_node_config
        else
            read -rp "是否继续添加节点配置？(回车继续，输入n或no退出)" continue_adding_node
            if [[ "$continue_adding_node" =~ ^[Nn][Oo]? ]]; then
                break
            fi
            add_node_config
        fi
    done

    # 初始化核心配置数组
    cores_config="["
    xray_dns_config_line=""
    if [ "$custom_dns_enabled" = true ]; then
        xray_dns_config_line='        "DnsConfigPath": "/etc/N2X/dns.json",'
    fi

    # 检查并添加xray核心配置
    if [ "$core_xray" = true ]; then
        cores_config+="
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
${xray_dns_config_line}
        \"OutboundConfigPath\": \"/etc/N2X/custom_outbound.json\",
        \"RouteConfigPath\": \"/etc/N2X/route.json\"
    },"
    fi

    # 移除最后一个逗号并关闭数组
    cores_config+="]"
    cores_config=$(echo "$cores_config" | sed 's/},]$/}]/')

    # 切换到配置文件目录
    cd /etc/N2X
    
    # 备份旧的配置文件
    mv config.json config.json.bak
    nodes_config_str="${nodes_config[*]}"
    formatted_nodes_config="${nodes_config_str%,}"

    # 创建 config.json 文件
    cat <<EOF > /etc/N2X/config.json
{
    "Log": {
        "Level": "error",
        "Output": ""
    },
    "Cores": $cores_config,
    "Nodes": [$formatted_nodes_config]
}
EOF

    # 如果启用了自定义 DNS，确保 dns.json 存在（安装脚本通常已生成，此处仅兜底）
    if [ "$custom_dns_enabled" = true ] && [ "$core_xray" = true ]; then
        if [[ ! -f /etc/N2X/dns.json ]]; then
            cat <<'EOF' > /etc/N2X/dns.json
{
  "servers": [
    "1.1.1.1",
    "8.8.8.8"
  ],
  "tag": "dns_inbound"
}
EOF
        fi
    fi

    if [[ ! -f /etc/N2X/.env.example ]]; then
        cat <<'EOF' > /etc/N2X/.env.example
N2X_API_HOST=https://example.com
N2X_API_KEY=please_fill_me
EOF
    fi
    
    # 创建 custom_outbound.json 文件
    cat <<EOF > /etc/N2X/custom_outbound.json
[
    {
        "tag": "IPv4_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv4v6"
        }
    },
    {
        "tag": "IPv6_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv6"
        }
    },
    {
        "protocol": "blackhole",
        "tag": "block"
    }
]
EOF
    
    # 创建 route.json 文件
    cat <<EOF > /etc/N2X/route.json
{
    "domainStrategy": "AsIs",
    "rules": [
        {
            "outboundTag": "block",
            "ip": [
                "geoip:private"
            ]
        },
        {
            "outboundTag": "block",
            "domain": [
                "regexp:(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
                "regexp:(.+.|^)(360|so).(cn|com)",
                "regexp:(Subject|HELO|SMTP)",
                "regexp:(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
                "regexp:(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
                "regexp:(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
                "regexp:(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
                "regexp:(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
                "regexp:(.+.|^)(360).(cn|com|net)",
                "regexp:(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
                "regexp:(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
                "regexp:(.*.||)(netvigator|torproject).(com|cn|net|org)",
                "regexp:(..||)(visa|mycard|gash|beanfun|bank).",
                "regexp:(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
                "regexp:(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
                "regexp:(.*.||)(mycard).(com|tw)",
                "regexp:(.*.||)(gash).(com|tw)",
                "regexp:(.bank.)",
                "regexp:(.*.||)(pincong).(rocks)",
                "regexp:(.*.||)(taobao).(com)",
                "regexp:(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
                "regexp:(flows|miaoko).(pages).(dev)"
            ]
        },
        {
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
            "outboundTag": "block",
            "protocol": [
                "bittorrent"
            ]
        },
        {
            "outboundTag": "IPv4_out",
            "network": "udp,tcp"
        }
    ]
}
EOF
    echo -e "${green}N2X 配置文件生成完成${plain}"
    echo -e "${yellow}下一步建议：${plain}"
    echo -e "1. 检查 /etc/N2X/config.json 是否正确"
    echo -e "2. 证书模式为 dns/http 时确认域名解析与 API 参数无误"
    echo -e "3. 如有自定义 DNS/路由，可编辑 /etc/N2X/dns.json 与 /etc/N2X/route.json"
    echo -e "${yellow}正在重启 N2X 服务...${plain}"
    n2x restart
}
