#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'
ENV_PATH="/etc/N2X/.env"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/config_gen.sh" ]]; then
    source "$SCRIPT_DIR/config_gen.sh"
elif [[ -f /usr/local/N2X/config_gen.sh ]]; then
    source /usr/local/N2X/config_gen.sh
fi

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误: ${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

# 检查系统是否有 IPv6 地址
check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"  # 支持 IPv6
    else
        echo "0"  # 不支持 IPv6
    fi
}

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "是否重启N2X" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
}

trim_text() {
    local text="$1"
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "$text"
}

strip_wrapping_quotes() {
    local value="$1"
    if [[ ${#value} -ge 2 ]]; then
        if [[ ( "${value:0:1}" == "\"" && "${value: -1}" == "\"" ) || ( "${value:0:1}" == "'" && "${value: -1}" == "'" ) ]]; then
            value="${value:1:-1}"
        fi
    fi
    printf '%s' "$value"
}

get_file_mode() {
    local path="$1"
    local mode=""
    mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
    if [[ -z "$mode" ]]; then
        mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
    fi
    printf '%s' "$mode"
}

get_file_owner() {
    local path="$1"
    local owner=""
    owner="$(stat -c '%U:%G' "$path" 2>/dev/null || true)"
    if [[ -z "$owner" ]]; then
        owner="$(stat -f '%Su:%Sg' "$path" 2>/dev/null || true)"
    fi
    printf '%s' "$owner"
}

is_permission_secure() {
    local mode="$1"
    [[ -n "$mode" ]] || return 1
    if [[ ${#mode} -gt 3 ]]; then
        mode="${mode: -3}"
    fi
    [[ "$mode" =~ ^[0-7]{3}$ ]] || return 1
    local mode_oct=$((8#$mode))
    # group/other 权限必须为 0
    (( (mode_oct & 077) == 0 ))
}

create_env_file_interactive() {
    mkdir -p /etc/N2X >/dev/null 2>&1 || true
    chmod 700 /etc/N2X >/dev/null 2>&1 || true

    local input_host=""
    local input_key=""
    while [[ -z "$input_host" ]]; do
        read -rp "请输入面板 API 地址 (N2X_API_HOST，例如 https://panel.example.com): " input_host
    done
    while [[ -z "$input_key" ]]; do
        read -rp "请输入面板 API KEY (N2X_API_KEY): " input_key
    done

    cat <<EOF > "$ENV_PATH"
# Panel API 配置
N2X_API_HOST=${input_host}
N2X_API_KEY=${input_key}
EOF
    chmod 600 "$ENV_PATH" >/dev/null 2>&1 || true
    echo -e "${green}已创建 ${ENV_PATH}${plain}"
}

validate_env_file_detailed() {
    local env_path="$1"
    local -a errors=()
    local -a warnings=()
    local line_no=0
    local host_count=0
    local key_count=0
    local host_value=""
    local key_value=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        local trimmed
        trimmed="$(trim_text "$line")"

        if [[ -z "$trimmed" || "$trimmed" == \#* || "$trimmed" == \;* ]]; then
            continue
        fi
        if [[ "$trimmed" == export\ * ]]; then
            trimmed="$(trim_text "${trimmed#export }")"
        fi
        if [[ "$trimmed" != *=* ]]; then
            errors+=("第 ${line_no} 行缺少 '='，应使用 KEY=VALUE 格式。")
            continue
        fi

        local key value
        key="$(trim_text "${trimmed%%=*}")"
        value="$(trim_text "${trimmed#*=}")"

        if [[ -z "$key" ]]; then
            errors+=("第 ${line_no} 行键名为空。")
            continue
        fi
        if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            errors+=("第 ${line_no} 行键名 '${key}' 非法（仅允许字母/数字/下划线，且不能以数字开头）。")
            continue
        fi

        value="$(strip_wrapping_quotes "$value")"
        case "$key" in
            N2X_API_HOST)
                host_count=$((host_count + 1))
                host_value="$value"
                if [[ -z "$value" ]]; then
                    errors+=("第 ${line_no} 行 N2X_API_HOST 不能为空。")
                fi
                ;;
            N2X_API_KEY)
                key_count=$((key_count + 1))
                key_value="$value"
                if [[ -z "$value" ]]; then
                    errors+=("第 ${line_no} 行 N2X_API_KEY 不能为空。")
                fi
                ;;
        esac
    done < "$env_path"

    if [[ "$host_count" -eq 0 ]]; then
        errors+=("缺少必填项 N2X_API_HOST。")
    elif [[ "$host_count" -gt 1 ]]; then
        warnings+=("N2X_API_HOST 出现 ${host_count} 次，将以最后一次为准。")
    fi
    if [[ "$key_count" -eq 0 ]]; then
        errors+=("缺少必填项 N2X_API_KEY。")
    elif [[ "$key_count" -gt 1 ]]; then
        warnings+=("N2X_API_KEY 出现 ${key_count} 次，将以最后一次为准。")
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo -e "${yellow}格式警告：${plain}"
        for item in "${warnings[@]}"; do
            echo -e "  - ${item}"
        done
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        echo -e "${red}格式检测结果：不合格${plain}"
        for item in "${errors[@]}"; do
            echo -e "  - ${item}"
        done
        return 1
    fi

    if [[ -n "$host_value" && -n "$key_value" ]]; then
        echo -e "${green}格式检测结果：合格${plain}"
        echo "  - N2X_API_HOST: 已填写"
        echo "  - N2X_API_KEY: 已填写"
    fi
    return 0
}

manage_env_file() {
    echo -e "${yellow}N2X .env 管理${plain}"
    echo "目标路径: ${ENV_PATH}"

    if [[ ! -f "$ENV_PATH" ]]; then
        echo -e "${yellow}检测结果：未找到 ${ENV_PATH}${plain}"
        local create_env
        read -rp "是否现在创建 ${ENV_PATH}？[Y/n]: " create_env
        create_env="${create_env:-Y}"
        if [[ "$create_env" =~ ^[Yy]$ ]]; then
            create_env_file_interactive
            echo -e "${yellow}已完成创建，建议再次执行 N2X env 查看检测结果。${plain}"
        else
            echo -e "${yellow}已跳过创建。${plain}"
        fi
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return
    fi

    local mode owner
    mode="$(get_file_mode "$ENV_PATH")"
    owner="$(get_file_owner "$ENV_PATH")"

    echo -e "${green}检测结果：找到 .env 文件${plain}"
    echo "文件路径: ${ENV_PATH}"
    echo "文件属主: ${owner:-未知}"
    if is_permission_secure "$mode"; then
        echo -e "文件权限: ${mode:-未知} (合格，建议 600)"
    else
        echo -e "${red}文件权限: ${mode:-未知} (不合格，建议 chmod 600 ${ENV_PATH})${plain}"
    fi

    validate_env_file_detailed "$ENV_PATH"
    if [[ $? -eq 0 ]]; then
        echo -e "${green}.env 检测通过。${plain}"
    else
        echo -e "${yellow}请根据上方提示修复后再重试。${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/Designdocs/N2X-script/main/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    if [[ $# == 0 ]]; then
        echo && echo -n -e "输入指定版本(默认最新版): " && read version
    else
        version=$2
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/Designdocs/N2X-script/main/install.sh) $version
    if [[ $? == 0 ]]; then
        echo -e "${green}更新完成，已自动重启 N2X，请使用 N2X log 查看运行日志${plain}"
        exit
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

config() {
    echo "N2X在修改配置后会自动尝试重启"
    vi /etc/N2X/config.json
    sleep 2
    restart
    check_status
    case $? in
        0)
            echo -e "N2X状态: ${green}已运行${plain}"
            ;;
        1)
            echo -e "检测到您未启动N2X或N2X自动重启失败，是否查看日志？[Y/n]" && echo
            read -e -rp "(默认: y):" yn
            [[ -z ${yn} ]] && yn="y"
            if [[ ${yn} == [Yy] ]]; then
               show_log
            fi
            ;;
        2)
            echo -e "N2X状态: ${red}未安装${plain}"
    esac
}

uninstall() {
    confirm "确定要卸载 N2X 吗?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        service N2X stop
        rc-update del N2X
        rm /etc/init.d/N2X -f
    else
        systemctl stop N2X
        systemctl disable N2X
        rm /etc/systemd/system/N2X.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi
    rm /etc/N2X/ -rf
    rm /usr/local/N2X/ -rf

    echo ""
    echo -e "卸载成功，如果你想删除此脚本，则退出脚本后运行 ${green}rm /usr/bin/N2X -f${plain} 进行删除"
    echo ""

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}N2X已运行，无需再次启动，如需重启请选择重启${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service N2X start
        else
            systemctl start N2X
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}N2X 启动成功，请使用 N2X log 查看运行日志${plain}"
        else
            echo -e "${red}N2X可能启动失败，请稍后使用 N2X log 查看日志信息${plain}"
            echo -e "${yellow}也可运行：journalctl -u N2X -n 50 --no-pager${plain}"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    if [[ x"${release}" == x"alpine" ]]; then
        service N2X stop
    else
        systemctl stop N2X
    fi
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}N2X 停止成功${plain}"
    else
        echo -e "${red}N2X停止失败，可能是因为停止时间超过了两秒，请稍后查看日志信息${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ x"${release}" == x"alpine" ]]; then
        service N2X restart
    else
        systemctl restart N2X
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}N2X 重启成功，请使用 N2X log 查看运行日志${plain}"
    else
        echo -e "${red}N2X可能启动失败，请稍后使用 N2X log 查看日志信息${plain}"
        echo -e "${yellow}也可运行：journalctl -u N2X -n 50 --no-pager${plain}"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ x"${release}" == x"alpine" ]]; then
        service N2X status
    else
        systemctl status N2X --no-pager -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update add N2X
    else
        systemctl enable N2X
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}N2X 设置开机自启成功${plain}"
    else
        echo -e "${red}N2X 设置开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update del N2X
    else
        systemctl disable N2X
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}N2X 取消开机自启成功${plain}"
    else
        echo -e "${red}N2X 取消开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ x"${release}" == x"alpine" ]]; then
        echo -e "${red}alpine系统暂不支持日志查看${plain}\n" && exit 1
    else
        journalctl -u N2X.service -e --no-pager -f
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

install_bbr() {
    bash <(curl -L -s https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh)
}

update_shell() {
    wget -O /usr/bin/N2X -N --no-check-certificate https://raw.githubusercontent.com/Designdocs/N2X-script/main/N2X.sh
    if [[ $? != 0 ]]; then
        echo ""
        echo -e "${red}下载脚本失败，请检查本机能否连接 Github${plain}"
        before_show_menu
    else
        chmod +x /usr/bin/N2X
        echo -e "${green}升级脚本成功，请重新运行脚本${plain}" && exit 0
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/N2X/N2X ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service N2X status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status N2X | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(rc-update show | grep N2X)
        if [[ x"${temp}" == x"" ]]; then
            return 1
        else
            return 0
        fi
    else
        temp=$(systemctl is-enabled N2X)
        if [[ x"${temp}" == x"enabled" ]]; then
            return 0
        else
            return 1;
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        echo -e "${red}N2X已安装，请不要重复安装${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        echo -e "${red}请先安装N2X${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "N2X状态: ${green}已运行${plain}"
            show_enable_status
            ;;
        1)
            echo -e "N2X状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "N2X状态: ${red}未安装${plain}"
    esac
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

generate_x25519_key() {
    echo -n "正在生成 x25519 密钥："
    /usr/local/N2X/N2X x25519
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_N2X_version() {
    echo -n "N2X 版本："
    /usr/local/N2X/N2X version
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

add_node_config() {
    echo -e "${green}请选择节点核心类型：${plain}"
    echo -e "${green}1. xray${plain}"
    echo -e "${green}2. singbox${plain}"
    echo -e "${green}3. hysteria2${plain}"
    read -rp "请输入：" core_type
    if [ "$core_type" == "1" ]; then
        core="xray"
        core_xray=true
    elif [ "$core_type" == "2" ]; then
        core="sing"
        core_sing=true
    elif [ "$core_type" == "3" ]; then
        core="hysteria2"
        core_hysteria2=true
    else
        echo "无效的选择。请选择 1 2 3。"
        continue
    fi
    while true; do
        read -rp "请输入节点Node ID：" NodeID
        # 判断NodeID是否为正整数
        if [[ "$NodeID" =~ ^[0-9]+$ ]]; then
            break  # 输入正确，退出循环
        else
            echo "错误：请输入正确的数字作为Node ID。"
        fi
    done

    if [ "$core_hysteria2" = true ] && [ "$core_xray" = false ] && [ "$core_sing" = false ]; then
        NodeType="hysteria2"
    else
        echo -e "${yellow}请选择节点传输协议：${plain}"
        echo -e "${green}1. Shadowsocks${plain}"
        echo -e "${green}2. Vless${plain}"
        echo -e "${green}3. Vmess${plain}"
        if [ "$core_sing" == true ]; then
            echo -e "${green}4. Hysteria${plain}"
            echo -e "${green}5. Hysteria2${plain}"
        fi
        if [ "$core_hysteria2" == true ] && [ "$core_sing" = false ]; then
            echo -e "${green}5. Hysteria2${plain}"
        fi
        echo -e "${green}6. Trojan${plain}"  
        if [ "$core_sing" == true ]; then
            echo -e "${green}7. Tuic${plain}"
            echo -e "${green}8. AnyTLS${plain}"
        fi
        read -rp "请输入：" NodeType
        case "$NodeType" in
            1 ) NodeType="shadowsocks" ;;
            2 ) NodeType="vless" ;;
            3 ) NodeType="vmess" ;;
            4 ) NodeType="hysteria" ;;
            5 ) NodeType="hysteria2" ;;
            6 ) NodeType="trojan" ;;
            7 ) NodeType="tuic" ;;
            8 ) NodeType="anytls" ;;
            * ) NodeType="shadowsocks" ;;
        esac
    fi
    fastopen=true
    if [ "$NodeType" == "vless" ]; then
        read -rp "请选择是否为reality节点？(y/n)" isreality
    elif [ "$NodeType" == "hysteria" ] || [ "$NodeType" == "hysteria2" ] || [ "$NodeType" == "tuic" ] || [ "$NodeType" == "anytls" ]; then
        fastopen=false
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
    node_config=""
    if [ "$core_type" == "1" ]; then 
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "0.0.0.0",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "EnableProxyProtocol": false,
            "EnableUot": true,
            "EnableTFO": true,
            "DNSType": "UseIPv4",
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
    elif [ "$core_type" == "2" ]; then
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "$listen_ip",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "TCPFastOpen": $fastopen,
            "SniffEnabled": true,
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
    elif [ "$core_type" == "3" ]; then
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Hysteria2ConfigPath": "/etc/N2X/hy2config.yaml",
            "Timeout": 30,
            "ListenIP": "",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
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
    fi
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
    
    nodes_config=()
    first_node=true
    core_xray=false
    core_sing=false
    fixed_api_info=false
    check_api=false
    
    while true; do
        if [ "$first_node" = true ]; then
            read -rp "请输入机场网址(https://example.com)：" ApiHost
            read -rp "请输入面板对接API Key：" ApiKey
            read -rp "是否设置固定的机场网址和API Key？(y/n)" fixed_api
            if [ "$fixed_api" = "y" ] || [ "$fixed_api" = "Y" ]; then
                fixed_api_info=true
                echo -e "${red}成功固定地址${plain}"
            fi
            first_node=false
            add_node_config
        else
            read -rp "是否继续添加节点配置？(回车继续，输入n或no退出)" continue_adding_node
            if [[ "$continue_adding_node" =~ ^[Nn][Oo]? ]]; then
                break
            elif [ "$fixed_api_info" = false ]; then
                read -rp "请输入机场网址：" ApiHost
                read -rp "请输入面板对接API Key：" ApiKey
            fi
            add_node_config
        fi
    done

    # 初始化核心配置数组
    cores_config="["

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
        \"OutboundConfigPath\": \"/etc/N2X/custom_outbound.json\",
        \"RouteConfigPath\": \"/etc/N2X/route.json\"
    },"
    fi

    # 检查并添加sing核心配置
    if [ "$core_sing" = true ]; then
        cores_config+="
    {
        \"Type\": \"sing\",
        \"Log\": {
            \"Level\": \"error\",
            \"Timestamp\": true
        },
        \"NTP\": {
            \"Enable\": true,
            \"Server\": \"time.apple.com\",
            \"ServerPort\": 0
        },
        \"OriginalPath\": \"/etc/N2X/sing_origin.json\"
    },"
    fi

    # 检查并添加hysteria2核心配置
    if [ "$core_hysteria2" = true ]; then
        cores_config+="
    {
        \"Type\": \"hysteria2\",
        \"Log\": {
            \"Level\": \"error\"
        }
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
                "outboundTag": "block",
                "protocol": [
                    "bittorrent"
                ]
            }
        ]
    }
EOF

    ipv6_support=$(check_ipv6_support)
    dnsstrategy="ipv4_only"
    if [ "$ipv6_support" -eq 1 ]; then
        dnsstrategy="prefer_ipv4"
    fi
    # 创建 sing_origin.json 文件
    cat <<EOF > /etc/N2X/sing_origin.json
{
  "dns": {
    "servers": [
      {
        "tag": "cf",
        "address": "1.1.1.1"
      }
    ],
    "strategy": "$dnsstrategy"
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "domain_resolver": {
        "server": "cf",
        "strategy": "$dnsstrategy"
      }
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "block"
      },
      {
        "domain_regex": [
            "(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
            "(.+.|^)(360|so).(cn|com)",
            "(Subject|HELO|SMTP)",
            "(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
            "(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
            "(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
            "(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
            "(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
            "(.+.|^)(360).(cn|com|net)",
            "(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
            "(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
            "(.*.||)(netvigator|torproject).(com|cn|net|org)",
            "(..||)(visa|mycard|gash|beanfun|bank).",
            "(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
            "(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
            "(.*.||)(mycard).(com|tw)",
            "(.*.||)(gash).(com|tw)",
            "(.bank.)",
            "(.*.||)(pincong).(rocks)",
            "(.*.||)(taobao).(com)",
            "(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
            "(flows|miaoko).(pages).(dev)"
        ],
        "outbound": "block"
      },
      {
        "outbound": "direct",
        "network": [
          "udp","tcp"
        ]
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  }
}
EOF

    # 创建 hy2config.yaml 文件           
    cat <<EOF > /etc/N2X/hy2config.yaml
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s
resolver:
  type: system
acl:
  inline:
    - direct(geosite:google)
    - reject(geosite:cn)
    - reject(geoip:cn)
masquerade:
  type: 404
EOF
    echo -e "${green}N2X 配置文件生成完成${plain}"
    echo -e "${yellow}下一步建议：${plain}"
    echo -e "1. 检查 /etc/N2X/config.json 是否正确"
    echo -e "2. 若启用 sing 核心，确保 /etc/N2X/sing_origin.json 存在（缺失可再次 generate）"
    echo -e "3. 证书模式为 dns/http 时确认域名解析与 API 参数无误"
    echo -e "4. 如有自定义 DNS/路由，可编辑 /etc/N2X/dns.json 与 /etc/N2X/route.json"
    echo -e "${yellow}正在重启 N2X 服务...${plain}"
    restart 0
    before_show_menu
}

# 放开防火墙端口
open_ports() {
    systemctl stop firewalld.service 2>/dev/null
    systemctl disable firewalld.service 2>/dev/null
    setenforce 0 2>/dev/null
    ufw disable 2>/dev/null
    iptables -P INPUT ACCEPT 2>/dev/null
    iptables -P FORWARD ACCEPT 2>/dev/null
    iptables -P OUTPUT ACCEPT 2>/dev/null
    iptables -t nat -F 2>/dev/null
    iptables -t mangle -F 2>/dev/null
    iptables -F 2>/dev/null
    iptables -X 2>/dev/null
    netfilter-persistent save 2>/dev/null
    echo -e "${green}放开防火墙端口成功！${plain}"
}

show_usage() {
    echo "N2X 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "N2X              - 显示管理菜单 (功能更多)"
    echo "N2X start        - 启动 N2X"
    echo "N2X stop         - 停止 N2X"
    echo "N2X restart      - 重启 N2X"
    echo "N2X status       - 查看 N2X 状态"
    echo "N2X enable       - 设置 N2X 开机自启"
    echo "N2X disable      - 取消 N2X 开机自启"
    echo "N2X log          - 查看 N2X 日志"
    echo "N2X env          - 创建/检测 .env"
    echo "N2X x25519       - 生成 x25519 密钥"
    echo "N2X generate     - 生成 N2X 配置文件"
    echo "N2X update       - 更新 N2X"
    echo "N2X update x.x.x - 安装 N2X 指定版本"
    echo "N2X install      - 安装 N2X"
    echo "N2X uninstall    - 卸载 N2X"
    echo "N2X version      - 查看 N2X 版本"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}N2X 后端管理脚本，${plain}${red}不适用于docker${plain}
--- https://github.com/Designdocs/N2X ---
  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 N2X
  ${green}2.${plain} 更新 N2X
  ${green}3.${plain} 卸载 N2X
————————————————
  ${green}4.${plain} 启动 N2X
  ${green}5.${plain} 停止 N2X
  ${green}6.${plain} 重启 N2X
  ${green}7.${plain} 查看 N2X 状态
  ${green}8.${plain} 查看 N2X 日志
————————————————
  ${green}9.${plain} 设置 N2X 开机自启
  ${green}10.${plain} 取消 N2X 开机自启
————————————————
  ${green}11.${plain} 一键安装 bbr (最新内核)
  ${green}12.${plain} 查看 N2X 版本
  ${green}13.${plain} 生成 X25519 密钥
  ${green}14.${plain} 升级 N2X 维护脚本
  ${green}15.${plain} 生成 N2X 配置文件
  ${green}16.${plain} 创建/检测 .env 文件
  ${green}17.${plain} 放行 VPS 的所有网络端口
  ${green}18.${plain} 退出脚本
 "
 #后续更新可加入上方字符串中
    show_status
    echo && read -rp "请输入选择 [0-18]: " num

    case "${num}" in
        0) config ;;
        1) check_uninstall && install ;;
        2) check_install && update ;;
        3) check_install && uninstall ;;
        4) check_install && start ;;
        5) check_install && stop ;;
        6) check_install && restart ;;
        7) check_install && status ;;
        8) check_install && show_log ;;
        9) check_install && enable ;;
        10) check_install && disable ;;
        11) install_bbr ;;
        12) check_install && show_N2X_version ;;
        13) check_install && generate_x25519_key ;;
        14) update_shell ;;
        15) generate_config_file ;;
        16) manage_env_file ;;
        17) open_ports ;;
        18) exit ;;
        *) echo -e "${red}请输入正确的数字 [0-18]${plain}" ;;
    esac
}


if [[ $# > 0 ]]; then
    case $1 in
        "start") check_install 0 && start 0 ;;
        "stop") check_install 0 && stop 0 ;;
        "restart") check_install 0 && restart 0 ;;
        "status") check_install 0 && status 0 ;;
        "enable") check_install 0 && enable 0 ;;
        "disable") check_install 0 && disable 0 ;;
        "log") check_install 0 && show_log 0 ;;
        "env") manage_env_file 0 ;;
        "update") check_install 0 && update 0 $2 ;;
        "config") config $* ;;
        "generate") generate_config_file ;;
        "install") check_uninstall 0 && install 0 ;;
        "uninstall") check_install 0 && uninstall 0 ;;
        "x25519") check_install 0 && generate_x25519_key 0 ;;
        "version") check_install 0 && show_N2X_version 0 ;;
        "update_shell") update_shell ;;
        *) show_usage
    esac
else
    show_menu
fi
