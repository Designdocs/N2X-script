#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

log_info() { echo -e "${green}$*${plain}"; }
log_warn() { echo -e "${yellow}$*${plain}"; }
log_error() { echo -e "${red}$*${plain}"; }
die() { log_error "$*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1，请重试安装或手动安装。"
}

require_any_cmd() {
    local a="$1" b="$2"
    if command -v "$a" >/dev/null 2>&1; then
        return 0
    fi
    if command -v "$b" >/dev/null 2>&1; then
        return 0
    fi
    die "缺少依赖命令: $a 或 $b，请重试安装或手动安装。"
}

download_file() {
    local url="$1" out="$2"
    if command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -N --progress=bar --tries=3 --timeout=15 -O "$out" "$url"
    else
        curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
    fi
}

verify_sha256_if_possible() {
    local zip_url="$1" zip_path="$2"
    if ! command -v openssl >/dev/null 2>&1; then
        return 0
    fi
    local dgst_url="${zip_url}.dgst"
    local dgst_path="${zip_path}.dgst"
    if download_file "$dgst_url" "$dgst_path" >/dev/null 2>&1; then
        local expected
        expected="$(grep -E 'SHA256' "$dgst_path" | awk '{print $2}' | head -n1)"
        if [[ -n "$expected" ]]; then
            local actual
            actual="$(openssl dgst -sha256 "$zip_path" | awk '{print $2}')"
            if [[ "$expected" != "$actual" ]]; then
                die "校验失败：sha256 不匹配，请重新下载。"
            fi
            log_info "sha256 校验通过。"
        fi
    fi
    rm -f "$dgst_path" >/dev/null 2>&1 || true
}

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

detect_arch_candidates() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|x64|amd64)
            echo "linux-64 linux-386"
            ;;
        aarch64|arm64)
            echo "linux-arm64-v8a"
            ;;
        armv7*|armv8l)
            echo "linux-arm32-v7a linux-arm32-v6 linux-arm32-v5"
            ;;
        armv6*|armv6l)
            echo "linux-arm32-v6 linux-arm32-v5"
            ;;
        armv5*|armv5l)
            echo "linux-arm32-v5"
            ;;
        mips64le)
            echo "linux-mips64le"
            ;;
        mips64)
            echo "linux-mips64"
            ;;
        mipsle)
            echo "linux-mips32le linux-mips32le-softfloat"
            ;;
        mips*)
            echo "linux-mips32 linux-mips32-softfloat"
            ;;
        ppc64le)
            echo "linux-ppc64le"
            ;;
        ppc64)
            echo "linux-ppc64"
            ;;
        riscv64)
            echo "linux-riscv64"
            ;;
        s390x)
            echo "linux-s390x"
            ;;
        *)
            echo "linux-64 linux-386"
            ;;
    esac
}

url_exists() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsI --retry 2 --retry-delay 2 "$url" >/dev/null 2>&1
        return $?
    fi
    wget --spider -q "$url" >/dev/null 2>&1
}

pick_asset_suffix() {
    local version="$1"
    local suffixes
    suffixes=$(detect_arch_candidates)
    for suf in $suffixes; do
        local test_url="https://github.com/Designdocs/N2X/releases/download/${version}/N2X-${suf}.zip"
        if url_exists "$test_url"; then
            echo "$suf"
            return 0
        fi
    done
    return 1
}

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
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates gettext -y >/dev/null 2>&1 || die "yum 安装依赖失败"
        update-ca-trust force-enable >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates gettext >/dev/null 2>&1 || die "apk 安装依赖失败"
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1 || die "apt-get update 失败"
        apt install wget curl unzip tar cron socat ca-certificates gettext-base -y >/dev/null 2>&1 || die "apt 安装依赖失败"
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1 || die "apt-get update 失败"
        apt install wget curl unzip tar cron socat gettext-base -y >/dev/null 2>&1 || die "apt 安装依赖失败"
        apt-get install ca-certificates wget -y >/dev/null 2>&1 || true
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1 || die "pacman 更新失败"
        pacman -S --noconfirm --needed wget curl unzip tar cron socat gettext >/dev/null 2>&1 || die "pacman 安装依赖失败"
        pacman -S --noconfirm --needed ca-certificates wget >/dev/null 2>&1 || true
    fi
}

verify_dependencies() {
    require_any_cmd curl wget
    require_cmd unzip
    require_cmd tar
    require_cmd sed
    require_cmd awk
    require_cmd grep
    if [[ x"${release}" != x"alpine" ]]; then
        require_cmd systemctl
        require_cmd journalctl
    fi
    require_cmd envsubst
}

ensure_cron_job() {
    local spec="$1" cmd="$2"
    local tmp
    tmp="$(crontab -l 2>/dev/null || true)"
    if ! printf "%s\n" "$tmp" | grep -Fq "$cmd"; then
        printf "%s\n%s %s\n" "$tmp" "$spec" "$cmd" | crontab -
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

fix_etc_n2x_permissions() {
    mkdir -p /etc/N2X/ >/dev/null 2>&1 || true
    chmod 700 /etc/N2X/ >/dev/null 2>&1 || true
    if [[ -f /etc/N2X/config.json ]]; then
        chmod 600 /etc/N2X/config.json >/dev/null 2>&1 || true
    fi
    if [[ -f /etc/N2X/.env ]]; then
        chmod 600 /etc/N2X/.env >/dev/null 2>&1 || true
    fi
}

# Ensure required env vars exist for systemd before first启动
ensure_env_file() {
    mkdir -p /etc/N2X/ >/dev/null 2>&1 || true
    # 已存在则保持用户设置
    if [[ -f /etc/N2X/.env ]]; then
        chmod 600 /etc/N2X/.env >/dev/null 2>&1 || true
        return
    fi

    local input_host input_key input_cert_domain input_cert_provider input_cert_email input_cf_api_key input_cf_email
    while [[ -z "$input_host" ]]; do
        read -rp "请输入面板 API 地址 (N2X_API_HOST，例如 https://panel.example.com): " input_host
    done
    while [[ -z "$input_key" ]]; do
        read -rp "请输入面板 API KEY (N2X_API_KEY): " input_key
    done
    read -rp "请输入证书域名 (N2X_CERT_DOMAIN，可留空，例如 all.cloudtls.top): " input_cert_domain
    read -rp "请选择证书 DNS 提供商 (N2X_CERT_PROVIDER，默认 cloudflare): " input_cert_provider
    input_cert_provider=${input_cert_provider:-cloudflare}
    read -rp "请输入证书邮箱 (N2X_CERT_EMAIL，用于 ACME 注册，可留空): " input_cert_email
    read -rp "请输入 Cloudflare Global API Key (CF_API_KEY，如使用 Cloudflare DNS，可留空): " input_cf_api_key
    read -rp "请输入 Cloudflare 账号邮箱 (CLOUDFLARE_EMAIL，如使用 Cloudflare DNS，可留空): " input_cf_email

    cat <<EOF > /etc/N2X/.env
# Panel API 配置
N2X_API_HOST=${input_host}
N2X_API_KEY=${input_key}

# 证书申请：域名与 DNS 提供商
N2X_CERT_DOMAIN=${input_cert_domain}
# 证书 DNS Provider，默认 cloudflare
N2X_CERT_PROVIDER=${input_cert_provider}
# 用于 ACME 注册的邮箱
N2X_CERT_EMAIL=${input_cert_email}

# Cloudflare DNS API（使用 Cloudflare 申请证书时需要）
CF_API_KEY=${input_cf_api_key}
CLOUDFLARE_EMAIL=${input_cf_email}
EOF
    chmod 600 /etc/N2X/.env >/dev/null 2>&1 || true
    log_info "已生成 /etc/N2X/.env，API 与证书相关变量已写入，可随时编辑补充。"
}

# 检查是否具备启动所需的最小 env；否则跳过启动，避免循环失败
env_ready_for_start() {
    if [[ ! -f /etc/N2X/.env ]]; then
        log_warn "/etc/N2X/.env 不存在，跳过启动，请先填写 N2X_API_HOST 与 N2X_API_KEY"
        return 1
    fi
    # shellcheck disable=SC1091
    set -a; source /etc/N2X/.env; set +a
    if [[ -z "$N2X_API_HOST" || -z "$N2X_API_KEY" ]]; then
        log_warn "N2X_API_HOST 或 N2X_API_KEY 为空，跳过启动，请编辑 /etc/N2X/.env"
        return 1
    fi
    return 0
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
            die "检测 N2X 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 N2X 版本安装"
        fi
        log_info "检测到 N2X 最新版本：${last_version}，开始安装"
        asset_suffix=$(pick_asset_suffix "$last_version") || die "当前架构无可用安装包，请检查发行页面：$last_version"
        log_info "选择下载包: ${asset_suffix}"
        url="https://github.com/Designdocs/N2X/releases/download/${last_version}/N2X-${asset_suffix}.zip"
        download_file "$url" /usr/local/N2X/N2X-linux.zip || die "下载 N2X 失败：$url"
        verify_sha256_if_possible "$url" /usr/local/N2X/N2X-linux.zip
    else
        last_version=$1
        asset_suffix=$(pick_asset_suffix "$last_version") || die "当前架构无可用安装包，请检查发行页面：$last_version"
        log_info "选择下载包: ${asset_suffix}"
        url="https://github.com/Designdocs/N2X/releases/download/${last_version}/N2X-${asset_suffix}.zip"
        log_info "开始安装 N2X $1"
        download_file "$url" /usr/local/N2X/N2X-linux.zip || die "下载 N2X $1 失败：$url"
        verify_sha256_if_possible "$url" /usr/local/N2X/N2X-linux.zip
    fi

    unzip N2X-linux.zip
    rm N2X-linux.zip -f
    chmod +x N2X
    mkdir /etc/N2X/ -p
    fix_etc_n2x_permissions
    # 旧配置迁移提示（仅在首次安装且检测到 V2bX 配置时）
    if [[ ! -f /etc/N2X/config.json && -f /etc/V2bX/config.json ]]; then
        echo -e "${yellow}检测到旧的 V2bX 配置，是否迁移到 N2X？${plain}"
        read -rp "迁移旧配置到 /etc/N2X/config.json [Y/n]: " do_migrate
        do_migrate="${do_migrate:-Y}"
        if [[ "$do_migrate" =~ ^[Yy]$ ]]; then
            cp /etc/V2bX/config.json /etc/N2X/config.json
            sed -i.bak \
                -e 's#/etc/V2bX#/etc/N2X#g' \
                -e 's#/usr/local/V2bX#/usr/local/N2X#g' \
                -e 's#V2bX#N2X#g' \
                /etc/N2X/config.json || true
            log_info "已迁移旧配置，并备份为 /etc/N2X/config.json.bak"
        fi
    fi
    cp geoip.dat /etc/N2X/
    cp geosite.dat /etc/N2X/
    ensure_env_file
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
        log_info "N2X ${last_version} 安装完成，已设置开机自启"
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
EnvironmentFile=-/etc/N2X/.env
RuntimeDirectory=N2X
RuntimeDirectoryMode=0755
UMask=0077
SyslogIdentifier=N2X
StandardOutput=journal
StandardError=journal
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/N2X/
ExecStartPre=/bin/sh -c 'test -n "$N2X_API_HOST" || { echo "N2X_API_HOST is empty"; exit 1; }'
ExecStartPre=/bin/sh -c 'test -n "$N2X_API_KEY" || { echo "N2X_API_KEY is empty"; exit 1; }'
ExecStartPre=/bin/sh -c 'command -v envsubst >/dev/null 2>&1 || { echo "envsubst not found"; exit 1; }'
ExecStartPre=/bin/sh -c 'test -f /etc/N2X/config.json || { echo "/etc/N2X/config.json not found"; exit 1; }'
ExecStartPre=/bin/sh -c 'envsubst '\''$N2X_API_HOST $N2X_API_KEY $N2X_CERT_DOMAIN $N2X_CERT_PROVIDER $N2X_CERT_EMAIL $CF_API_KEY $CLOUDFLARE_EMAIL'\'' < /etc/N2X/config.json > /run/N2X/config.json'
ExecStart=/usr/local/N2X/N2X server --config /run/N2X/config.json
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop N2X
        systemctl enable N2X
        log_info "N2X ${last_version} 安装完成，已设置开机自启"
    fi

    if [[ ! -f /etc/N2X/config.json ]]; then
        cp config.json /etc/N2X/ || true
        fix_etc_n2x_permissions
        echo -e ""
        echo -e "全新安装，请先参看教程：https://github.com/Designdocs/N2X-script/wiki ，配置必要的内容"
        first_install=true
    else
        if env_ready_for_start; then
            if [[ x"${release}" == x"alpine" ]]; then
                service N2X start
            else
                systemctl start N2X
            fi
            sleep 2
            check_status
            echo -e ""
            if [[ $? == 0 ]]; then
                log_info "N2X 重启成功"
            else
                log_warn "N2X 可能启动失败，最近日志："
                journalctl -u N2X -n 80 --no-pager || true
            fi
        else
            echo -e ""
            log_warn "因环境变量未完整，已跳过启动。请编辑 /etc/N2X/.env 后执行：systemctl restart N2X"
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
    # Cron: weekly geodata sync (Sat 04:00) and monthly update (1st 04:30)
    ensure_cron_job "0 4 * * 6" "/usr/bin/N2X update geodata -r >/var/log/N2X-geodata.log 2>&1"
    ensure_cron_job "30 4 1 * *" "/usr/bin/N2X update -r >/var/log/N2X-update.log 2>&1"
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
        read -rp "检测到你为第一次安装N2X，是否自动生成配置文件？[Y/n]: " if_generate
        if_generate="${if_generate:-Y}"
        if [[ $if_generate == [Yy] ]]; then
            curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/Designdocs/N2X-script/main/initconfig.sh
            source initconfig.sh
            rm initconfig.sh -f
            generate_config_file
        else
            log_warn "你可以稍后运行：N2X generate 生成配置文件。"
        fi
    fi
}

echo -e "${green}开始安装${plain}"
install_base
verify_dependencies
install_N2X $1
