#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

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

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
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

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat -y >/dev/null 2>&1
        apt-get install ca-certificates wget -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat >/dev/null 2>&1
        pacman -S --noconfirm --needed ca-certificates wget >/dev/null 2>&1
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

install_N2X() {
    if [[ -e /usr/local/N2X/ ]]; then
        rm -rf /usr/local/N2X/
    fi

    mkdir /usr/local/N2X/ -p
    cd /usr/local/N2X/

    if  [ $# == 0 ] ;then
        last_version=$(curl -Ls "https://api.github.com/repos/Designdocs/N2X/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 N2X 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 N2X 版本安装${plain}"
            exit 1
        fi
        echo -e "检测到 N2X 最新版本：${last_version}，开始安装"
        wget --no-check-certificate -N --progress=bar -O /usr/local/N2X/N2X-linux.zip https://github.com/Designdocs/N2X/releases/download/${last_version}/N2X-linux-${arch}.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 N2X 失败，请确保你的服务器能够下载 Github 的文件${plain}"
            exit 1
        fi
    else
        last_version=$1
        url="https://github.com/Designdocs/N2X/releases/download/${last_version}/N2X-linux-${arch}.zip"
        echo -e "开始安装 N2X $1"
        wget --no-check-certificate -N --progress=bar -O /usr/local/N2X/N2X-linux.zip ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 N2X $1 失败，请确保此版本存在${plain}"
            exit 1
        fi
    fi

    unzip N2X-linux.zip
    rm N2X-linux.zip -f
    chmod +x N2X
    mkdir /etc/N2X/ -p
    cp geoip.dat /etc/N2X/
    cp geosite.dat /etc/N2X/
    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/N2X -f
        cat <<EOF > /etc/init.d/N2X
#!/sbin/openrc-run

name="N2X"
description="N2X"

command="/usr/local/N2X/N2X"
command_args="server"
command_user="root"

pidfile="/run/N2X.pid"
command_background="yes"

depend() {
        need net
}
EOF
        chmod +x /etc/init.d/N2X
        rc-update add N2X default
        echo -e "${green}N2X ${last_version}${plain} 安装完成，已设置开机自启"
    else
        rm /etc/systemd/system/N2X.service -f
        cat <<EOF > /etc/systemd/system/N2X.service
[Unit]
Description=N2X Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/N2X/
ExecStart=/usr/local/N2X/N2X server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop N2X
        systemctl enable N2X
        echo -e "${green}N2X ${last_version}${plain} 安装完成，已设置开机自启"
    fi

    if [[ ! -f /etc/N2X/config.json ]]; then
        cp config.json /etc/N2X/
        echo -e ""
        echo -e "全新安装，请先参看教程：https://github.com/Designdocs/N2X-script/wiki ，配置必要的内容"
        first_install=true
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service N2X start
        else
            systemctl start N2X
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}N2X 重启成功${plain}"
        else
            echo -e "${red}N2X 可能启动失败，请稍后使用 N2X log 查看日志信息，若无法启动，则可能更改了配置格式，请前往 wiki 查看：https://github.com/Designdocs/N2X/wiki${plain}"
        fi
        first_install=false
    fi

    if [[ ! -f /etc/N2X/dns.json ]]; then
        cp dns.json /etc/N2X/
    fi
    if [[ ! -f /etc/N2X/route.json ]]; then
        cp route.json /etc/N2X/
    fi
    if [[ ! -f /etc/N2X/custom_outbound.json ]]; then
        cp custom_outbound.json /etc/N2X/
    fi
    if [[ ! -f /etc/N2X/custom_inbound.json ]]; then
        cp custom_inbound.json /etc/N2X/
    fi
    curl -o /usr/bin/N2X -Ls https://raw.githubusercontent.com/Designdocs/N2X-script/main/N2X.sh
    mkdir -p /usr/local/N2X/
    curl -o /usr/local/N2X/config_gen.sh -Ls https://raw.githubusercontent.com/Designdocs/N2X-script/main/config_gen.sh
    chmod +x /usr/bin/N2X
    if [ ! -L /usr/bin/n2x ]; then
        ln -s /usr/bin/N2X /usr/bin/n2x
        chmod +x /usr/bin/n2x
    fi
    cd $cur_dir
    rm -f install.sh
    echo -e ""
    echo "N2X 管理脚本使用方法 (兼容使用N2X执行，大小写不敏感): "
    echo "------------------------------------------"
    echo "N2X              - 显示管理菜单 (功能更多)"
    echo "N2X start        - 启动 N2X"
    echo "N2X stop         - 停止 N2X"
    echo "N2X restart      - 重启 N2X"
    echo "N2X status       - 查看 N2X 状态"
    echo "N2X enable       - 设置 N2X 开机自启"
    echo "N2X disable      - 取消 N2X 开机自启"
    echo "N2X log          - 查看 N2X 日志"
    echo "N2X x25519       - 生成 x25519 密钥"
    echo "N2X generate     - 生成 N2X 配置文件"
    echo "N2X update       - 更新 N2X"
    echo "N2X update x.x.x - 更新 N2X 指定版本"
    echo "N2X install      - 安装 N2X"
    echo "N2X uninstall    - 卸载 N2X"
    echo "N2X version      - 查看 N2X 版本"
    echo "------------------------------------------"
    # 首次安装询问是否生成配置文件
    if [[ $first_install == true ]]; then
        read -rp "检测到你为第一次安装N2X,是否自动直接生成配置文件？(y/n): " if_generate
        if [[ $if_generate == [Yy] ]]; then
            curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/Designdocs/N2X-script/main/initconfig.sh
            source initconfig.sh
            rm initconfig.sh -f
            generate_config_file
        fi
    fi
}

echo -e "${green}开始安装${plain}"
install_base
install_N2X $1
