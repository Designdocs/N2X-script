#!/bin/bash
# 在已有 config.json 上追加协议节点（与「生成配置」的整份重写相对）。
#
# 依赖 config_gen.sh 提供的 add_node_config / build_cores_config，调用方（N2X.sh）
# 先 source config_gen.sh 再 source 本文件。install.sh 会把两个文件一起装到
# /usr/local/N2X/ 下。

# 「生成 N2X 配置文件」是重建：备份旧文件后整份重写，之前配好的节点会消失。
# 这里做的是合并：读出现有 config.json，只往 Nodes 里追加新节点，只在缺少对应
# 核心时才补一条 Cores，其余内容（Log、已有节点、已有核心的自定义参数、_help）
# 原样保留。

# 配置目录。默认 /etc/N2X，测试用 N2X_CONFIG_DIR 覆盖。
n2x_config_dir() {
    printf '%s\n' "${N2X_CONFIG_DIR:-/etc/N2X}"
}

# 合并 JSON 必须用真正的解析器：已有配置是用户手改过的，字段顺序、缩进、注释
# 都不确定，用 sed 拼接只会写出坏配置。python3 优先，python 兜底，都没有就放弃。
n2x_python_bin() {
    if command -v python3 >/dev/null 2>&1; then
        printf 'python3\n'
    elif command -v python >/dev/null 2>&1; then
        printf 'python\n'
    else
        return 1
    fi
}

# 唯一的 python 入口，两种模式：
#
#   facts <config.json>
#       固定输出 7 行（是否需要清理注释 / 是否已有 xray / 是否已有 sing /
#       xray 是否配了 DnsConfigPath / 节点数 / ApiHost / ApiKey），其后是给人看
#       的节点清单。
#
#   merge <config.json> <nodes.json> <cores.json> <out.json>
#       把 nodes.json 追加进 Nodes、把 cores.json 里缺失的核心追加进 Cores，
#       结果写入 out.json（不改动 config.json）。退出码：0 已写出、2 解析失败、
#       3 没有任何新增（全是重复节点）。
n2x_config_py() {
    local py
    py="$(n2x_python_bin)" || return 127
    "$py" - "$@" <<'PY'
import io
import json
import sys


def trim_json5(raw):
    """去掉 // 与 /* */ 注释和 ] } 前的尾逗号。

    N2X 自己用 common/json5 的 TrimNodeReader 读配置，所以 /etc/N2X/config.json
    里允许出现注释和尾逗号；python 的 json 不认。这里是那份实现的等价移植，
    只在严格解析失败后才用，调用方会提醒用户注释会在合并后丢失。
    """
    s = list(raw)
    n = len(s)

    def consume_comment(i):
        if i < n and s[i] == '/':
            s[i - 1] = ' '
            while i < n and s[i] not in '\r\n':
                s[i] = ' '
                i += 1
            return i
        if i < n and s[i] == '*':
            s[i - 1] = ' '
            s[i] = ' '
            while i < n:
                if s[i] != '*':
                    s[i] = ' '
                else:
                    s[i] = ' '
                    i += 1
                    if i < n and s[i] == '/':
                        s[i] = ' '
                        break
                i += 1
            return i
        return i

    i = 0
    while i < n:
        c = s[i]
        if c == '"':
            i += 1
            while i < n:
                if s[i] == '"':
                    i += 1
                    break
                elif s[i] == '\\':
                    i += 1
                i += 1
        elif c == '/':
            i = consume_comment(i + 1)
        elif c == ',':
            j = i
            while True:
                i += 1
                if i >= n:
                    break
                if s[i] in '}]':
                    s[j] = ' '
                    break
                if s[i] == '/':
                    i = consume_comment(i + 1)
                elif not s[i].isspace():
                    break
        else:
            i += 1
    return ''.join(s)


def load_config(path):
    """返回 (数据, 是否清理过注释)。解析失败时抛异常，由调用方兜住。"""
    with io.open(path, 'r', encoding='utf-8') as handle:
        raw = handle.read()
    try:
        return json.loads(raw), False
    except ValueError:
        return json.loads(trim_json5(raw)), True


def dict_list(data, key):
    value = data.get(key)
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def one_line(value):
    return str(value or '').replace('\r', ' ').replace('\n', ' ')


# add_node_config 写死的占位值。只有当新节点仍是这些占位值时，才从现有节点
# 继承对应字段——用户自己填过的值一律不动。
CERT_PLACEHOLDERS = {
    'CertDomain': ('', 'all.example.com', 'example.com'),
    'Email': ('', 'example@gmail.com'),
    'Provider': ('', 'cloudflare'),
    'CertFile': ('', '/etc/N2X/fullchain-{domain}.cer'),
    'KeyFile': ('', '/etc/N2X/cert-{domain}.key'),
}
DNSENV_PLACEHOLDER = {
    'CF_API_KEY': 'ExampleKEY',
    'CLOUDFLARE_EMAIL': 'example@gmail.com',
}


def cert_donor(nodes):
    """挑一个可继承证书信息的现有节点：优先最后一个真正用证书的节点。"""
    donor = None
    for node in nodes:
        cert = node.get('CertConfig')
        if not isinstance(cert, dict):
            continue
        if str(cert.get('CertMode') or 'none') != 'none':
            donor = cert
    if donor is not None:
        return donor
    for node in nodes:
        cert = node.get('CertConfig')
        if isinstance(cert, dict):
            donor = cert
    return donor


def inherit_cert(new_node, donor):
    """把现有节点的证书信息补进新节点，返回被继承的字段名。"""
    cert = new_node.get('CertConfig')
    if not isinstance(cert, dict) or not isinstance(donor, dict):
        return []
    if str(cert.get('CertMode') or 'none') == 'none':
        return []

    inherited = []
    for field, placeholders in CERT_PLACEHOLDERS.items():
        if field in ('CertFile', 'KeyFile') and 'CertDomain' not in inherited:
            # 证书路径通常带着域名，域名没继承就别继承路径，否则指到别的域名上。
            continue
        donor_value = donor.get(field)
        if not isinstance(donor_value, str) or not donor_value.strip():
            continue
        if str(cert.get(field) or '') not in placeholders:
            continue
        if donor_value == cert.get(field):
            continue
        cert[field] = donor_value
        inherited.append(field)

    donor_env = donor.get('DNSEnv')
    if isinstance(donor_env, dict) and donor_env and donor_env != DNSENV_PLACEHOLDER:
        if cert.get('DNSEnv') in (None, {}, DNSENV_PLACEHOLDER):
            cert['DNSEnv'] = dict(donor_env)
            inherited.append('DNSEnv')
    return inherited


def node_key(node):
    return (node.get('NodeID'), str(node.get('NodeType') or ''), str(node.get('Core') or ''))


def do_facts(path):
    data, trimmed = load_config(path)
    if not isinstance(data, dict):
        raise ValueError('config.json 的顶层不是一个 JSON 对象')

    cores = dict_list(data, 'Cores')
    nodes = dict_list(data, 'Nodes')
    types = [str(core.get('Type') or '') for core in cores]
    custom_dns = any(
        str(core.get('Type') or '') == 'xray' and str(core.get('DnsConfigPath') or '').strip()
        for core in cores
    )

    host = ''
    key = ''
    for node in nodes:
        host = one_line(node.get('ApiHost'))
        key = one_line(node.get('ApiKey'))
        if host or key:
            break

    out = [
        'true' if trimmed else 'false',
        'true' if 'xray' in types else 'false',
        'true' if 'sing' in types else 'false',
        'true' if custom_dns else 'false',
        str(len(nodes)),
        host,
        key,
    ]
    for node in nodes:
        cert = node.get('CertConfig')
        cert_mode = cert.get('CertMode') if isinstance(cert, dict) else None
        out.append('  - NodeID={0}  协议={1}  核心={2}  证书={3}'.format(
            one_line(node.get('NodeID')) or '?',
            one_line(node.get('NodeType')) or '?',
            one_line(node.get('Core')) or 'xray',
            one_line(cert_mode) or 'none',
        ))
    print('\n'.join(out))


def do_merge(config_path, nodes_path, cores_path, out_path):
    data, _ = load_config(config_path)
    if not isinstance(data, dict):
        raise ValueError('config.json 的顶层不是一个 JSON 对象')
    with io.open(nodes_path, 'r', encoding='utf-8') as handle:
        new_nodes = json.load(handle)
    with io.open(cores_path, 'r', encoding='utf-8') as handle:
        new_cores = json.load(handle)

    cores = data.get('Cores')
    if not isinstance(cores, list):
        cores = []
    nodes = data.get('Nodes')
    if not isinstance(nodes, list):
        nodes = []

    messages = []

    have_types = set(
        str(core.get('Type') or '') for core in cores if isinstance(core, dict)
    )
    cores_added = []
    for core in new_cores:
        if not isinstance(core, dict):
            continue
        core_type = str(core.get('Type') or '')
        if core_type in have_types:
            continue
        cores.append(core)
        have_types.add(core_type)
        cores_added.append(core_type)

    donor = cert_donor([node for node in nodes if isinstance(node, dict)])
    seen = set(node_key(node) for node in nodes if isinstance(node, dict))
    added = 0
    skipped = 0
    for node in new_nodes:
        if not isinstance(node, dict):
            continue
        key = node_key(node)
        if key in seen:
            skipped += 1
            messages.append('  跳过重复节点：NodeID={0} 协议={1} 核心={2}（已存在）'.format(
                one_line(node.get('NodeID')), one_line(node.get('NodeType')), one_line(node.get('Core'))))
            continue
        inherited = inherit_cert(node, donor)
        if inherited:
            messages.append('  NodeID={0} 已从现有节点继承证书配置：{1}'.format(
                one_line(node.get('NodeID')), '、'.join(inherited)))
        nodes.append(node)
        seen.add(key)
        added += 1

    if added == 0:
        for line in messages:
            print(line)
        print('没有新增任何节点。')
        sys.exit(3)

    data['Cores'] = cores
    data['Nodes'] = nodes

    text = json.dumps(data, ensure_ascii=False, indent=4)
    if not isinstance(text, type(u'')):
        text = text.decode('utf-8')
    with io.open(out_path, 'w', encoding='utf-8') as handle:
        handle.write(text)
        handle.write(u'\n')

    for line in messages:
        print(line)
    print('新增节点 {0} 个，跳过重复 {1} 个。'.format(added, skipped))
    if cores_added:
        print('新增核心：{0}'.format('、'.join(cores_added)))
    else:
        print('核心无需变动（所需核心已存在）。')


mode = sys.argv[1] if len(sys.argv) > 1 else ''
try:
    if mode == 'facts':
        do_facts(sys.argv[2])
    elif mode == 'merge':
        do_merge(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    else:
        sys.stderr.write('unknown mode: {0}\n'.format(mode))
        sys.exit(2)
except SystemExit:
    raise
except Exception as exc:  # noqa: BLE001 - 统一转成给用户看的一行错误
    sys.stderr.write('{0}\n'.format(exc))
    sys.exit(2)
PY
}

# 新增 xray 核心时补齐配套文件，已存在的一律不动。
#
# 默认内容由 config_gen.sh 的 write_default_dns_json /
# write_default_custom_outbound_json / write_default_route_json 提供（同一份实现
# 也被 initconfig.sh、N2X.sh 的「生成配置」复用）。这里只在文件缺失时调用，绝不
# 覆盖用户已有的内容——重建是「生成配置」的语义，追加协议不该动它们。
#
# xray 核心读不到 RouteConfigPath / OutboundConfigPath 指向的文件会直接 panic，
# 所以新增 xray 核心时必须补齐。
ensure_xray_side_files() {
    local cfg_dir="$1"

    if [[ ! -f "$cfg_dir/dns.json" ]]; then
        write_default_dns_json "$cfg_dir/dns.json"
        echo -e "${green}已创建 $cfg_dir/dns.json（默认 DNS）${plain}"
    fi
    if [[ ! -f "$cfg_dir/custom_outbound.json" ]]; then
        write_default_custom_outbound_json "$cfg_dir/custom_outbound.json"
        echo -e "${green}已创建 $cfg_dir/custom_outbound.json（默认出站）${plain}"
    fi
    if [[ ! -f "$cfg_dir/route.json" ]]; then
        write_default_route_json "$cfg_dir/route.json"
        echo -e "${green}已创建 $cfg_dir/route.json（默认路由）${plain}"
    fi
}

# 新节点用的 ApiHost/ApiKey：默认沿用现有节点的值。
#
# 现有值是 ${N2X_API_HOST} 这类占位符时直接照抄——真实值由 /etc/N2X/.env 提供，
# 问用户要一遍反而会把明文写进配置。设置：api_host_val / api_key_val
select_append_api_info() {
    local existing_host="$1" existing_key="$2" cfg_dir="$3"
    local reuse masked

    if [[ "$existing_host" == *'$'* || "$existing_key" == *'$'* ]]; then
        api_host_val="$existing_host"
        api_key_val="$existing_key"
        echo -e "${green}现有节点使用环境变量占位符（$existing_host），新节点沿用同样的写法，实际值仍由 $cfg_dir/.env 提供。${plain}"
        return 0
    fi

    if [[ -n "$existing_host" ]]; then
        if [[ ${#existing_key} -gt 4 ]]; then
            masked="${existing_key:0:4}****"
        elif [[ -n "$existing_key" ]]; then
            masked="****"
        else
            masked="(空)"
        fi
        echo -e "${yellow}现有 ApiHost：${plain}$existing_host"
        echo -e "${yellow}现有 ApiKey ：${plain}$masked"
        read -rp "新节点是否沿用以上机场网址和 API Key？(回车沿用，输入n重新填写)" reuse
        if [[ ! "$reuse" =~ ^[Nn][Oo]? ]]; then
            api_host_val="$existing_host"
            api_key_val="$existing_key"
            return 0
        fi
    fi

    if [[ -z "$existing_host" && -f "$cfg_dir/.env" ]]; then
        echo -e "${green}检测到 $cfg_dir/.env，新节点将写入 \${N2X_API_HOST} / \${N2X_API_KEY} 占位符。${plain}"
        api_host_val='${N2X_API_HOST}'
        api_key_val='${N2X_API_KEY}'
        return 0
    fi

    api_host_val=""
    api_key_val=""
    while [[ -z "$api_host_val" ]]; do
        read -rp "请输入机场网址(https://example.com)：" api_host_val
    done
    while [[ -z "$api_key_val" ]]; do
        read -rp "请输入面板对接API Key：" api_key_val
    done
}

# 在已有 config.json 上追加协议节点。成功返回 0（配置已改写，调用方负责重启
# 服务），无改动或失败返回非 0。
append_node_configs() {
    local cfg_dir cfg facts trimmed has_xray has_sing existing_dns node_count
    local existing_host existing_key node_table answer tmp_dir nodes_str core_list
    local add_xray=false add_sing=false saved_xray saved_sing new_cores merge_status

    cfg_dir="$(n2x_config_dir)"
    cfg="$cfg_dir/config.json"

    if ! n2x_python_bin >/dev/null; then
        echo -e "${red}未检测到 python3/python，无法安全地合并 JSON 配置。${plain}"
        echo -e "${yellow}请先安装 python3（Debian/Ubuntu: apt-get install -y python3；CentOS: yum install -y python3），或改用「生成 N2X 配置文件」重建配置。${plain}"
        return 1
    fi

    if [[ ! -f "$cfg" ]]; then
        echo -e "${red}未找到 $cfg。${plain}"
        echo -e "${yellow}还没有配置可供追加，请先使用「生成 N2X 配置文件」创建初始配置。${plain}"
        return 1
    fi

    if ! facts="$(n2x_config_py facts "$cfg")"; then
        echo -e "${red}$cfg 解析失败，为避免破坏现有配置，本次不做任何改动。${plain}"
        echo -e "${yellow}请先用菜单「修改配置」修好 JSON 语法后重试。${plain}"
        return 1
    fi

    {
        IFS= read -r trimmed
        IFS= read -r has_xray
        IFS= read -r has_sing
        IFS= read -r existing_dns
        IFS= read -r node_count
        IFS= read -r existing_host
        IFS= read -r existing_key
        node_table="$(cat)"
    } <<EOF
$facts
EOF

    echo -e "${yellow}当前配置概况（$cfg）：${plain}"
    echo -e "  已有节点：${node_count} 个"
    if [[ -n "$node_table" ]]; then
        echo "$node_table"
    fi
    core_list=""
    if [[ "$has_xray" == "true" ]]; then
        core_list="xray"
    fi
    if [[ "$has_sing" == "true" ]]; then
        if [[ -n "$core_list" ]]; then
            core_list="$core_list + sing"
        else
            core_list="sing"
        fi
    fi
    echo -e "  已有核心：${core_list:-（无）}"
    echo ""

    if [[ "$trimmed" == "true" ]]; then
        echo -e "${yellow}注意：配置里含有注释或尾逗号（N2X 能读，标准 JSON 不能）。${plain}"
        echo -e "${yellow}合并后会按标准 JSON 重新写出，注释将丢失（原文件仍会备份为 config.json.bak）。${plain}"
        read -rp "是否继续？(y/n)" answer
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            echo -e "${yellow}已取消，配置未改动。${plain}"
            return 1
        fi
    fi

    select_append_api_info "$existing_host" "$existing_key" "$cfg_dir"

    # 自定义 DNS 只影响 xray 节点，跟着现有 xray 核心走；还没有 xray 核心时才问。
    if [[ "$has_xray" == "true" ]]; then
        if [[ "$existing_dns" == "true" ]]; then
            custom_dns_enabled=true
            echo -e "${green}现有 xray 核心已配置 DnsConfigPath，新增的 xray 节点同样开启 EnableDNS/DNSType=UseIP。${plain}"
        else
            custom_dns_enabled=false
            echo -e "${green}现有 xray 核心未配置 DnsConfigPath，新增的 xray 节点保持 EnableDNS=false。${plain}"
        fi
    else
        read -rp "是否开启自定义 DNS（仅新增 xray 节点时生效）？(y/n) " answer
        if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
            custom_dns_enabled=true
        else
            custom_dns_enabled=false
        fi
    fi

    nodes_config=()
    core_xray=false
    core_sing=false
    while true; do
        add_node_config
        read -rp "是否继续添加节点配置？(回车继续，输入n或no退出)" answer
        if [[ "$answer" =~ ^[Nn][Oo]? ]]; then
            break
        fi
    done

    if [[ "$core_xray" == "true" && "$has_xray" != "true" ]]; then
        add_xray=true
    fi
    if [[ "$core_sing" == "true" && "$has_sing" != "true" ]]; then
        add_sing=true
    fi

    # build_cores_config 读全局 core_xray/core_sing，这里临时改成「需要补哪个」，
    # 已经存在的核心不会被重复写入，也不会覆盖它现有的参数。
    saved_xray="$core_xray"
    saved_sing="$core_sing"
    core_xray="$add_xray"
    core_sing="$add_sing"
    new_cores="$(build_cores_config)"
    core_xray="$saved_xray"
    core_sing="$saved_sing"

    tmp_dir="$(mktemp -d)" || return 1

    nodes_str="${nodes_config[*]}"
    printf '[%s]\n' "${nodes_str%,}" > "$tmp_dir/nodes.json"
    printf '%s\n' "$new_cores" > "$tmp_dir/cores.json"

    n2x_config_py merge "$cfg" "$tmp_dir/nodes.json" "$tmp_dir/cores.json" "$tmp_dir/config.json"
    merge_status=$?
    if [[ $merge_status -ne 0 ]]; then
        rm -rf "$tmp_dir"
        if [[ $merge_status -eq 3 ]]; then
            echo -e "${yellow}配置未改动。${plain}"
        else
            echo -e "${red}合并失败，配置未改动。${plain}"
        fi
        return 1
    fi

    cp -f "$cfg" "$cfg.bak" || { rm -rf "$tmp_dir"; echo -e "${red}备份 $cfg.bak 失败，已中止。${plain}"; return 1; }
    # 用重定向而不是 mv：保留原文件的属主与权限。
    if ! cat "$tmp_dir/config.json" > "$cfg"; then
        rm -rf "$tmp_dir"
        echo -e "${red}写入 $cfg 失败，请用 $cfg.bak 恢复。${plain}"
        return 1
    fi
    rm -rf "$tmp_dir"
    chmod 600 "$cfg" 2>/dev/null || true

    if [[ "$add_xray" == "true" ]]; then
        ensure_xray_side_files "$cfg_dir"
    fi

    echo -e "${green}协议已追加到 $cfg（原配置已备份为 $cfg.bak）${plain}"
    return 0
}
