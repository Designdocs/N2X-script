#!/bin/bash
# 出口解锁设置：交互式往 custom_outbound.json 加一条 http/socks 代理出站，同时往
# route.json 加一条把指定域名指过去的路由规则。
#
# 两个文件必须同成同败：出站写进去了、规则没写进去，等于多了个永远用不到的出站；
# 反过来规则指向不存在的 outboundTag，xray 会在 dispatcher 里直接掐断连接。所以
# 全程在临时文件里改，两边都校验通过才一起落盘。
#
# 路由规则打 "ruleTag": "custom-unlock-<tag>"，和 download_block.sh 一个路子，靠标
# 记认自己的东西，不去猜用户手写的规则。
#
# 依赖 config_gen.sh 的 write_default_*_json（清除时恢复默认）与 download_block.sh
# （清除会重写 route.json，得把下载拦截的开关状态原样恢复回去）。调用方 N2X.sh 按
# config_gen.sh -> download_block.sh -> outbound_unlock.sh 的顺序 source。

# 颜色变量由 N2X.sh 在 source 本文件之前定义；被 tests/ 单独 source 时补空值兜底。
: "${red:=}" "${green:=}" "${yellow:=}" "${plain:=}"

OUTBOUND_UNLOCK_RULE_TAG_PREFIX="custom-unlock"
# 这几个标签是默认配置里的固定角色，被顶掉会让路由整个失效。
OUTBOUND_UNLOCK_RESERVED_TAGS="IPv4_out IPv6_out block socks5-unlock"

outbound_unlock_config_dir() {
    printf '%s\n' "${N2X_CONFIG_DIR:-/etc/N2X}"
}

outbound_unlock_outbound_path() {
    printf '%s/custom_outbound.json\n' "$(outbound_unlock_config_dir)"
}

outbound_unlock_route_path() {
    printf '%s/route.json\n' "$(outbound_unlock_config_dir)"
}

# 与 config_append.sh / download_block.sh 同一套探测，避免多份实现漂移。
outbound_unlock_python_bin() {
    if declare -F n2x_python_bin >/dev/null 2>&1; then
        n2x_python_bin
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf 'python3\n'
    elif command -v python >/dev/null 2>&1; then
        printf 'python\n'
    else
        return 1
    fi
}

outbound_unlock_py() {
    local py
    py="$(outbound_unlock_python_bin)" || return 127
    "$py" - "$@" <<'PY'
import json
import os
import sys

RULE_PREFIX = "custom-unlock"


def load(path):
    with open(path, "r") as handle:
        return json.load(handle)


def write_atomic(path, payload):
    tmp = path + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=4)
        handle.write("\n")
    os.replace(tmp, path)


def rule_tag(rule):
    return str(rule.get("ruleTag", ""))


# 兜底规则没有任何匹配条件，插在它后面的规则永远轮不到。
MATCH_KEYS = (
    "domain", "domains", "ip", "port", "sourcePort", "protocol", "source",
    "user", "inboundTag", "attrs", "domainMatcher",
)


def rule_insert_index(rules):
    for index, rule in enumerate(rules):
        if not any(key in rule for key in MATCH_KEYS):
            return index
    return len(rules)


# 新出站插在 block 之前，也就是 IPv4_out / IPv6_out 之后。
#
# 顺序不影响规则是否生效（路由是靠 outboundTag 找出站的），它只决定默认出站：
# app/proxyman/outbound 的 AddHandler 把第一个注册的 handler 存成 defaultHandler。
# 所以关键是别占掉第 0 位——否则一旦 route.json 末尾那条 network=udp,tcp 的兜底规则
# 被删掉，未命中任何规则的流量就会全部走这条解锁代理，而不是直连。
#
# 找不到 block 就追加到末尾；block 恰好排在第 0 位这种畸形配置，就退让到 1，
# 不去擅自重排用户已有的出站。
def outbound_insert_index(outbounds):
    index = len(outbounds)
    for position, ob in enumerate(outbounds):
        if ob.get("tag") == "block":
            index = position
            break
    if outbounds and index == 0:
        index = 1
    return index


mode = sys.argv[1]

if mode == "tags":
    try:
        outbounds = load(sys.argv[2])
        rules = load(sys.argv[3]).get("rules", [])
    except Exception:
        sys.exit(2)
    # 以路由规则里的标记为准：出站和规则是一起写进去的，规则更能代表"这条是我加的"
    tags = [rule_tag(r)[len(RULE_PREFIX) + 1:] for r in rules
            if rule_tag(r).startswith(RULE_PREFIX + "-")]
    known = {ob.get("tag") for ob in outbounds}
    print(" ".join(t for t in tags if t in known))
    sys.exit(0)

if mode == "list":
    try:
        outbounds = load(sys.argv[2])
        rules = load(sys.argv[3]).get("rules", [])
    except Exception:
        sys.exit(2)
    by_tag = {ob.get("tag"): ob for ob in outbounds}
    found = False
    for rule in rules:
        tag = rule_tag(rule)
        if not tag.startswith(RULE_PREFIX + "-"):
            continue
        tag = tag[len(RULE_PREFIX) + 1:]
        ob = by_tag.get(tag)
        if ob is None:
            continue
        found = True
        srv = (ob.get("settings", {}).get("servers") or [{}])[0]
        auth = "有账号密码" if srv.get("users") else "无账号"
        tls = "TLS" if ob.get("streamSettings", {}).get("security") == "tls" else "明文"
        print("%s\t%s\t%s:%s\t%s / %s" % (
            tag, ob.get("protocol", "?"), srv.get("address", "?"),
            srv.get("port", "?"), auth, tls))
        for entry in rule.get("domain") or rule.get("domains") or []:
            print("\t  %s" % entry)
    if not found:
        print("(无)")
    sys.exit(0)

if mode == "add":
    (ob_path, rt_path, tag, protocol, address, port, user, password,
     use_tls, server_name, allow_insecure) = sys.argv[2:13]
    domains = sys.argv[13:]

    try:
        outbounds = load(ob_path)
    except Exception as exc:
        sys.stderr.write("custom_outbound.json 解析失败：%s\n" % exc)
        sys.exit(2)
    if not isinstance(outbounds, list):
        sys.stderr.write("custom_outbound.json 顶层必须是数组\n")
        sys.exit(2)
    try:
        route = load(rt_path)
    except Exception as exc:
        sys.stderr.write("route.json 解析失败：%s\n" % exc)
        sys.exit(2)
    if not isinstance(route.get("rules"), list):
        sys.stderr.write("route.json 里没有 rules 数组\n")
        sys.exit(2)

    if any(ob.get("tag") == tag for ob in outbounds):
        sys.stderr.write("出站标签已存在：%s\n" % tag)
        sys.exit(2)

    server = {"address": address, "port": int(port)}
    if user:
        server["users"] = [{"user": user, "pass": password}]

    new_outbound = {
        "tag": tag,
        "protocol": protocol,
        "settings": {"servers": [server]},
    }
    if use_tls == "1":
        new_outbound["streamSettings"] = {
            "security": "tls",
            "tlsSettings": {
                "serverName": server_name or address,
                "allowInsecure": allow_insecure == "1",
            },
        }

    new_rule = {
        "type": "field",
        "ruleTag": "%s-%s" % (RULE_PREFIX, tag),
        "outboundTag": tag,
        "domain": list(domains),
    }

    outbounds.insert(outbound_insert_index(outbounds), new_outbound)
    rules = route["rules"]
    route["rules"] = (rules[:rule_insert_index(rules)] + [new_rule]
                      + rules[rule_insert_index(rules):])

    # 两个文件同成同败：先都写临时文件，都成功了再一起 os.replace。
    write_atomic(ob_path, outbounds)
    try:
        write_atomic(rt_path, route)
    except Exception as exc:
        sys.stderr.write("写入 route.json 失败：%s\n" % exc)
        sys.exit(2)
    sys.exit(0)

sys.stderr.write("unknown mode: %s\n" % mode)
sys.exit(2)
PY
}

# ---- 校验 -----------------------------------------------------------------
# 全部只做校验、不改文件；失败时把原因打到 stderr，交互层直接重问。

outbound_unlock_validate_tag() {
    local tag="$1" reserved existing
    if [[ -z "$tag" ]]; then
        echo -e "${red}标签不能为空。${plain}" >&2
        return 1
    fi
    if ! printf '%s' "$tag" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then
        echo -e "${red}标签只能用字母、数字、_ . -，且以字母或数字开头：${tag}${plain}" >&2
        return 1
    fi
    for reserved in $OUTBOUND_UNLOCK_RESERVED_TAGS; do
        if [[ "$tag" == "$reserved" ]]; then
            echo -e "${red}${tag} 是默认配置的保留标签，换一个。${plain}" >&2
            return 1
        fi
    done
    for existing in $(outbound_unlock_tags 2>/dev/null); do
        if [[ "$tag" == "$existing" ]]; then
            echo -e "${red}标签已存在：${tag}${plain}" >&2
            return 1
        fi
    done
    return 0
}

outbound_unlock_validate_protocol() {
    case "$1" in
        http|socks) return 0 ;;
        *)
            echo -e "${red}协议只支持 http 或 socks，实得：$1${plain}" >&2
            return 1
            ;;
    esac
}

outbound_unlock_validate_port() {
    local port="$1"
    if ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
        echo -e "${red}端口必须是纯数字：${port}${plain}" >&2
        return 1
    fi
    if (( 10#$port < 1 || 10#$port > 65535 )); then
        echo -e "${red}端口必须在 1-65535 之间：${port}${plain}" >&2
        return 1
    fi
    return 0
}

# 域名或 IP（含 IPv6）。不接受带协议头、端口或空格的写法。
outbound_unlock_validate_address() {
    local addr="$1"
    if [[ -z "$addr" ]]; then
        echo -e "${red}服务器地址不能为空。${plain}" >&2
        return 1
    fi
    if printf '%s' "$addr" | grep -qE '[[:space:]/@]'; then
        echo -e "${red}地址里不能有空格、/ 或 @，只填主机名或 IP：${addr}${plain}" >&2
        return 1
    fi
    if printf '%s' "$addr" | grep -qE '^[0-9a-fA-F:]+$' && [[ "$addr" == *:* ]]; then
        return 0    # IPv6
    fi
    if printf '%s' "$addr" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'; then
        return 0    # 域名或 IPv4
    fi
    echo -e "${red}地址格式不对：${addr}${plain}" >&2
    return 1
}

# xray 支持的域名写法：geosite:/domain:/full:/regexp:/ext: 前缀，或裸域名。
outbound_unlock_validate_domain_entry() {
    local entry="$1"
    if [[ -z "$entry" ]]; then
        echo -e "${red}域名条目不能为空。${plain}" >&2
        return 1
    fi
    if printf '%s' "$entry" | grep -qE '[[:space:]]'; then
        echo -e "${red}域名条目里不能有空格：${entry}${plain}" >&2
        return 1
    fi
    case "$entry" in
        regexp:*)
            [[ -n "${entry#regexp:}" ]] && return 0
            echo -e "${red}regexp: 后面是空的。${plain}" >&2
            return 1
            ;;
        geosite:*|domain:*|full:*|ext:*)
            if [[ -z "${entry#*:}" ]]; then
                echo -e "${red}${entry%%:*}: 后面是空的。${plain}" >&2
                return 1
            fi
            if ! printf '%s' "${entry#*:}" | grep -qE '^[A-Za-z0-9._:-]+$'; then
                echo -e "${red}域名条目含非法字符：${entry}${plain}" >&2
                return 1
            fi
            return 0
            ;;
    esac
    if printf '%s' "$entry" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
        return 0
    fi
    echo -e "${red}域名条目格式不对：${entry}${plain}" >&2
    echo -e "${yellow}可用写法：geosite:openai、domain:openai.com、full:chat.openai.com、regexp:.*openai.*，或直接写 openai.com${plain}" >&2
    return 1
}

# ---- 读 -------------------------------------------------------------------

# 空格分隔的自定义解锁标签。文件缺失或解析失败时输出空串并返回 0，方便嵌在提示里。
outbound_unlock_tags() {
    local ob rt
    ob="$(outbound_unlock_outbound_path)"
    rt="$(outbound_unlock_route_path)"
    [[ -f "$ob" && -f "$rt" ]] || return 0
    outbound_unlock_py tags "$ob" "$rt" 2>/dev/null || true
    return 0
}

outbound_unlock_list() {
    local ob rt
    ob="$(outbound_unlock_outbound_path)"
    rt="$(outbound_unlock_route_path)"
    echo -e "出站文件：${ob}"
    echo -e "路由文件：${rt}"
    echo "------------------------------------------"
    if [[ ! -f "$ob" || ! -f "$rt" ]]; then
        echo -e "${yellow}配置文件缺失，请先「生成 N2X 配置文件」。${plain}"
        return 0
    fi
    if ! outbound_unlock_py list "$ob" "$rt" 2>/dev/null; then
        echo -e "${red}配置解析失败，请检查这两个文件是否为合法 JSON。${plain}"
        return 1
    fi
    return 0
}

# ---- 写 -------------------------------------------------------------------

# outbound_unlock_add <tag> <http|socks> <address> <port> <user> <pass> \
#                     <tls:0|1> <serverName> <allowInsecure:0|1> <domain>...
# 纯函数：只改文件不碰服务，交互层负责重启。任一校验不过就整个不写。
outbound_unlock_add() {
    local tag="$1" protocol="$2" address="$3" port="$4" user="$5" password="$6"
    local use_tls="$7" server_name="$8" allow_insecure="$9"
    shift 9
    local ob rt entry

    if [[ $# -eq 0 ]]; then
        echo -e "${red}至少要有一个解锁域名条目。${plain}" >&2
        return 1
    fi

    ob="$(outbound_unlock_outbound_path)"
    rt="$(outbound_unlock_route_path)"

    if ! outbound_unlock_python_bin >/dev/null; then
        echo -e "${red}未检测到 python3/python，无法安全地修改 JSON 配置。${plain}" >&2
        echo -e "${yellow}请先安装 python3（Debian/Ubuntu: apt-get install -y python3；CentOS: yum install -y python3）。${plain}" >&2
        return 1
    fi
    for entry in "$ob" "$rt"; do
        if [[ ! -f "$entry" ]]; then
            echo -e "${red}未找到 ${entry}。${plain}" >&2
            echo -e "${yellow}请先使用「生成 N2X 配置文件」创建初始配置。${plain}" >&2
            return 1
        fi
    done

    outbound_unlock_validate_tag "$tag" || return 1
    outbound_unlock_validate_protocol "$protocol" || return 1
    outbound_unlock_validate_address "$address" || return 1
    outbound_unlock_validate_port "$port" || return 1
    if [[ -n "$user" && -z "$password" ]]; then
        echo -e "${red}填了用户名就必须填密码。${plain}" >&2
        return 1
    fi
    if [[ -z "$user" && -n "$password" ]]; then
        echo -e "${red}填了密码就必须填用户名。${plain}" >&2
        return 1
    fi
    if [[ "$use_tls" == "1" && -n "$server_name" ]]; then
        outbound_unlock_validate_address "$server_name" || return 1
    fi
    for entry in "$@"; do
        outbound_unlock_validate_domain_entry "$entry" || return 1
    done

    outbound_unlock_py add "$ob" "$rt" "$tag" "$protocol" "$address" "$port" \
        "$user" "$password" "$use_tls" "$server_name" "$allow_insecure" "$@" || return 1
    return 0
}

# 清除 = 把两个文件恢复成 config_gen.sh 里的默认内容。备份先行，因为这会连带抹掉
# 用户在这两个文件里做过的任何手改，不只是解锁配置。
outbound_unlock_clear() {
    local ob rt stamp entry traffic_state domain_state

    ob="$(outbound_unlock_outbound_path)"
    rt="$(outbound_unlock_route_path)"

    if ! declare -F write_default_custom_outbound_json >/dev/null \
       || ! declare -F write_default_route_json >/dev/null; then
        echo -e "${red}未找到 config_gen.sh 或其版本过旧，无法恢复默认配置。${plain}" >&2
        return 1
    fi

    # 恢复默认会把下载拦截的三条规则一并写回开启状态。用户特意关掉的分组不该因为
    # 清理解锁配置就被打开，所以先记下来，恢复完再按原状态应用一遍。
    traffic_state=""
    domain_state=""
    if declare -F download_block_state >/dev/null && [[ -f "$rt" ]]; then
        traffic_state="$(download_block_state traffic)"
        domain_state="$(download_block_state domain)"
    fi

    stamp="$(date +%Y%m%d%H%M%S)"
    for entry in "$ob" "$rt"; do
        if [[ -f "$entry" ]]; then
            cp "$entry" "${entry}.bak.${stamp}" || {
                echo -e "${red}备份 ${entry} 失败，已中止，未做任何改动。${plain}" >&2
                return 1
            }
        fi
    done

    write_default_custom_outbound_json "$ob" || {
        echo -e "${red}恢复 ${ob} 失败。${plain}" >&2
        return 1
    }
    write_default_route_json "$rt" || {
        echo -e "${red}恢复 ${rt} 失败。${plain}" >&2
        return 1
    }
    # 默认 route.json 是全开的，之前关着的分组重新关回去；停用存根也随之重建。
    rm -f "$(outbound_unlock_config_dir)/download-block.disabled.json"
    if declare -F download_block_apply >/dev/null; then
        [[ "$traffic_state" == "off" ]] && download_block_apply off traffic >/dev/null
        [[ "$domain_state" == "off" ]] && download_block_apply off domain >/dev/null
    fi
    return 0
}

# ---- 交互层 ---------------------------------------------------------------

outbound_unlock_restart_hint() {
    if declare -F restart >/dev/null && [[ -f /usr/local/N2X/N2X ]]; then
        echo -e "${yellow}正在重启 N2X 以使改动生效...${plain}"
        restart 0
    else
        echo -e "${yellow}请手动重启 N2X 使改动生效。${plain}"
    fi
}

# 反复问同一个问题直到校验通过；输入 q 放弃整条。返回 1 表示用户放弃。
outbound_unlock_prompt() {
    local __var="$1" prompt="$2" default="$3" validator="$4" value
    while true; do
        if [[ -n "$default" ]]; then
            read -rp "$(echo -e "${prompt} [默认 ${default}，q 放弃]: ")" value
        else
            read -rp "$(echo -e "${prompt} [q 放弃]: ")" value
        fi
        [[ "$value" == "q" ]] && return 1
        [[ -z "$value" && -n "$default" ]] && value="$default"
        if [[ -z "$validator" ]]; then
            printf -v "$__var" '%s' "$value"
            return 0
        fi
        if "$validator" "$value"; then
            printf -v "$__var" '%s' "$value"
            return 0
        fi
    done
}

outbound_unlock_add_interactive() {
    local tag protocol address port user password use_tls server_name allow_insecure
    local answer entry domains

    if [[ ! -f "$(outbound_unlock_outbound_path)" || ! -f "$(outbound_unlock_route_path)" ]]; then
        echo -e "${red}未找到 custom_outbound.json 或 route.json。${plain}"
        echo -e "${yellow}请先使用「生成 N2X 配置文件」创建初始配置。${plain}"
        return 1
    fi

    while true; do
        domains=()
        echo -e "\n${green}添加一条自定义解锁出站${plain}（任意一步输入 q 放弃本条）"
        echo "------------------------------------------"

        outbound_unlock_prompt tag "出站标签（英文，如 http-unlock）" "" \
            outbound_unlock_validate_tag || return 0
        outbound_unlock_prompt protocol "协议（http / socks）" "http" \
            outbound_unlock_validate_protocol || return 0
        outbound_unlock_prompt address "服务器地址（域名或 IP）" "" \
            outbound_unlock_validate_address || return 0
        outbound_unlock_prompt port "端口" "" outbound_unlock_validate_port || return 0
        outbound_unlock_prompt user "用户名（没有就直接回车）" "" "" || return 0
        if [[ -n "$user" ]]; then
            outbound_unlock_prompt password "密码" "" "" || return 0
            if [[ -z "$password" ]]; then
                echo -e "${red}填了用户名就必须填密码，本条放弃。${plain}"
                return 0
            fi
        else
            password=""
        fi

        read -rp "$(echo -e "是否启用 TLS？[y/N]: ")" answer
        if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
            use_tls=1
            outbound_unlock_prompt server_name "TLS SNI" "$address" \
                outbound_unlock_validate_address || return 0
            read -rp "$(echo -e "是否允许不安全证书 allowInsecure？[y/N]: ")" answer
            if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
                allow_insecure=1
            else
                allow_insecure=0
            fi
        else
            use_tls=0
            server_name=""
            allow_insecure=0
        fi

        echo -e "\n${yellow}逐条输入要走这个出站的域名，每输入一条回车，空行结束。${plain}"
        echo -e "${yellow}写法：geosite:openai、domain:openai.com、full:chat.openai.com、regexp:.*openai.*，或直接 openai.com${plain}"
        while true; do
            read -rp "  域名条目 #$(( ${#domains[@]} + 1 ))（空行结束）: " entry
            [[ -z "$entry" ]] && break
            if outbound_unlock_validate_domain_entry "$entry"; then
                domains+=("$entry")
            fi
        done
        if [[ ${#domains[@]} -eq 0 ]]; then
            echo -e "${red}一个域名条目都没有，本条放弃。${plain}"
        else
            echo -e "\n${green}即将写入：${plain}"
            echo "  标签    ${tag}"
            echo "  协议    ${protocol}"
            echo "  服务器  ${address}:${port}"
            if [[ -n "$user" ]]; then
                echo "  账号    ${user} / ${password}"
            else
                echo "  账号    （无）"
            fi
            if [[ "$use_tls" == "1" ]]; then
                echo "  TLS     开启，SNI=${server_name:-$address}，allowInsecure=$([[ "$allow_insecure" == 1 ]] && echo true || echo false)"
            else
                echo "  TLS     关闭"
            fi
            printf '  域名    %s\n' "${domains[@]}"
            read -rp "$(echo -e "确认写入？[Y/n]: ")" answer
            if [[ "$answer" == "n" || "$answer" == "N" ]]; then
                echo -e "${yellow}已放弃本条。${plain}"
            elif outbound_unlock_add "$tag" "$protocol" "$address" "$port" "$user" \
                    "$password" "$use_tls" "$server_name" "$allow_insecure" "${domains[@]}"; then
                echo -e "${green}已添加：${tag}${plain}"
                outbound_unlock_restart_hint
            else
                echo -e "${red}添加失败，两个配置文件都未改动。${plain}"
            fi
        fi

        read -rp "$(echo -e "\n继续添加下一条？[Y/n]: ")" answer
        [[ "$answer" == "n" || "$answer" == "N" ]] && break
    done
    return 0
}

outbound_unlock_clear_interactive() {
    local answer
    echo -e "${red}清除会把这两个文件恢复成默认内容：${plain}"
    echo "  $(outbound_unlock_outbound_path)"
    echo "  $(outbound_unlock_route_path)"
    echo -e "${yellow}不只是自定义解锁——你在这两个文件里做过的任何手改都会一并消失${plain}"
    echo -e "${yellow}（socks5-unlock 里填过的账号、自己加的路由规则等）。${plain}"
    echo -e "${yellow}清除前会各备份一份 .bak.<时间戳> 到同目录。${plain}"
    echo -e "${yellow}下载拦截两组的开关状态会被保留。${plain}"
    echo
    read -rp "$(echo -e "确认清除？输入大写 YES 继续: ")" answer
    if [[ "$answer" != "YES" ]]; then
        echo -e "${yellow}已取消，未做任何改动。${plain}"
        return 0
    fi
    if outbound_unlock_clear; then
        echo -e "${green}已恢复默认配置，备份保留在 $(outbound_unlock_config_dir)。${plain}"
        outbound_unlock_restart_hint
    else
        echo -e "${red}清除失败。${plain}"
        return 1
    fi
    return 0
}

before_outbound_unlock_menu() {
    echo && echo -n -e "${yellow}按回车返回出口解锁菜单: ${plain}" && read temp
    outbound_unlock_menu
}

outbound_unlock_menu() {
    local current
    current="$(outbound_unlock_tags)"
    [[ -z "$current" ]] && current="（无）"
    echo -e "
  ${green}出口解锁设置${plain}   当前自定义：${current}
————————————————
  ${green}1.${plain} 添加自定义解锁（可连续添加）
  ${green}2.${plain} 查看当前自定义解锁
  ${green}3.${plain} 清除自定义（恢复两个文件为默认）
  ${green}4.${plain} 返回 N2X 主菜单
 "
    read -rp "请输入选择 [1-4]: " num
    case "${num}" in
        1) outbound_unlock_add_interactive; before_outbound_unlock_menu ;;
        2) outbound_unlock_list; before_outbound_unlock_menu ;;
        3) outbound_unlock_clear_interactive; before_outbound_unlock_menu ;;
        4) show_menu ;;
        *) echo -e "${red}请输入正确的数字 [1-4]${plain}"; before_outbound_unlock_menu ;;
    esac
}

outbound_unlock_command() {
    case "${1:-list}" in
        add)        outbound_unlock_add_interactive ;;
        list|"")    outbound_unlock_list ;;
        clear)      outbound_unlock_clear_interactive ;;
        menu)       outbound_unlock_menu ;;
        *)
            echo "N2X unlock add   - 交互式添加自定义解锁出站"
            echo "N2X unlock list  - 查看当前自定义解锁"
            echo "N2X unlock clear - 清除自定义（恢复两个文件为默认，会先备份）"
            return 1
            ;;
    esac
}
