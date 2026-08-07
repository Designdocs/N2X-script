#!/bin/bash
# 一键配置

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/config_gen.sh" ]]; then
    source "$SCRIPT_DIR/config_gen.sh"
elif [[ -f /usr/local/N2X/config_gen.sh ]]; then
    source /usr/local/N2X/config_gen.sh
fi

# config_gen.sh 提供 add_node_config / build_cores_config / config_help_block /
# write_default_*_json 等共享实现，本文件不再重复定义。缺失时直接报错，避免生成
# 半成品配置。write_default_route_json 是 config_gen.sh v4 才有的，一并检查可以
# 挡住只升级了本文件、config_gen.sh 还是旧版的情况。
if ! declare -F add_node_config >/dev/null || ! declare -F write_default_route_json >/dev/null; then
    echo "错误：未找到 config_gen.sh 或其版本过旧，无法生成配置。请重新安装或升级 N2X 后重试。" >&2
    return 1 2>/dev/null || exit 1
fi

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
    config_api_host=""
    config_api_key=""
    if [[ ! -f /etc/N2X/.env ]]; then
        echo -e "${yellow}未检测到 /etc/N2X/.env，将在配置文件中直接填写 ApiHost 和 ApiKey。${plain}"
        while [[ -z "$config_api_host" ]]; do
            read -rp "请输入面板 API 地址 (ApiHost，例如 https://panel.example.com): " config_api_host
        done
        while [[ -z "$config_api_key" ]]; do
            read -rp "请输入面板 API KEY (ApiKey): " config_api_key
        done
        api_host_val="$config_api_host"
        api_key_val="$config_api_key"
    else
        echo -e "${green}已检测到 /etc/N2X/.env，ApiHost/ApiKey 将从环境变量读取。${plain}"
        api_host_val='${N2X_API_HOST}'
        api_key_val='${N2X_API_KEY}'
    fi

    nodes_config=()
    first_node=true
    core_xray=false
    core_sing=false
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

    # 初始化核心配置数组（只写入实际用到的核心）
    cores_config=$(build_cores_config)

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
    "Nodes": [$formatted_nodes_config],
    "_help": {
$(config_help_block)
    }
}
EOF

    # DnsConfigPath 默认指向 /etc/N2X/dns.json；N2X generate 单独运行时兜底创建。
    if [ "$core_xray" = true ]; then
        if [[ ! -f /etc/N2X/dns.json ]]; then
            write_default_dns_json /etc/N2X/dns.json
        fi
    fi

    if [[ ! -f /etc/N2X/.env.example ]]; then
        cat <<'EOF' > /etc/N2X/.env.example
N2X_API_HOST=https://example.com
N2X_API_KEY=please_fill_me
EOF
    fi
    
    # custom_outbound.json / route.json：默认内容见 config_gen.sh 的
    # write_default_*_json。生成配置是重建，这里按语义直接覆盖。
    write_default_custom_outbound_json /etc/N2X/custom_outbound.json
    write_default_route_json /etc/N2X/route.json
    echo -e "${green}N2X 配置文件生成完成${plain}"
    echo -e "${yellow}下一步建议：${plain}"
    echo -e "1. 检查 /etc/N2X/config.json 是否正确"
    echo -e "2. 证书模式为 dns/http 时确认域名解析与 API 参数无误"
    echo -e "3. 如有自定义 DNS/路由或 SOCKS5 解锁，可编辑 /etc/N2X/dns.json、/etc/N2X/custom_outbound.json 与 /etc/N2X/route.json"
    echo -e "${yellow}正在重启 N2X 服务...${plain}"
    n2x restart
}
