#!/bin/bash
# 下载拦截（BT / P2P）的启停开关，分两组独立控制。
#
#   traffic  download-block-protocol  协议嗅探判定为 bittorrent 的流量
#            download-block-port      BT 常用端口 6881-6889,6969,2710,51413
#   domain   download-block-domain    bittorrent/utorrent、xunlei/sandai、ed2k/announce 域名
#
# 分成两组是因为两者的误伤面完全不同：traffic 认的是流量特征，几乎不会错杀；domain
# 认的是域名字样，torrentmac、torrentfreak 这类资讯/软件站会跟着一起被拦。想放行这
# 类站点又要继续拦 BT 流量时，只关 domain 组即可。
#
# 规则默认内容由 config_gen.sh 的 write_default_route_json 提供，本文件不再抄一份；
# 需要「恢复默认」时是现生成一份默认 route.json 再把带标记的规则取出来用。调用方
# （N2X.sh）先 source config_gen.sh 再 source 本文件。
#
# 关闭时把摘下来的规则原样存到 /etc/N2X/download-block.disabled.json（一个数组，两
# 组混放，靠 ruleTag 区分），开启时再放回去——这样用户手改过的规则（比如自己加的
# 域名）关一次再开不会丢。存根被删了也能自愈：回落到内置默认。

# 颜色变量由 N2X.sh 在 source 本文件之前定义。被 tests/ 单独 source 时它们不存在，
# set -u 下引用未定义变量会直接中断整个脚本，所以补一个空值兜底（已定义则不覆盖）。
: "${red:=}" "${green:=}" "${yellow:=}" "${plain:=}"

# 分组 -> ruleTag 列表。未知分组返回非零，这是唯一一处定义，菜单和命令行都查这里。
download_block_group_tags() {
    case "$1" in
        traffic) printf 'download-block-protocol download-block-port\n' ;;
        domain)  printf 'download-block-domain\n' ;;
        all|"")  printf 'download-block-protocol download-block-port download-block-domain\n' ;;
        *)       return 1 ;;
    esac
}

download_block_group_label() {
    case "$1" in
        traffic) printf 'BT 协议/端口拦截' ;;
        domain)  printf '下载站域名拦截' ;;
        all|"")  printf '下载拦截（全部）' ;;
        *)       printf '%s' "$1" ;;
    esac
}

# 配置目录。默认 /etc/N2X，测试用 N2X_CONFIG_DIR 覆盖（与 config_append.sh 一致）。
download_block_config_dir() {
    printf '%s\n' "${N2X_CONFIG_DIR:-/etc/N2X}"
}

download_block_route_path() {
    printf '%s/route.json\n' "$(download_block_config_dir)"
}

download_block_stash_path() {
    printf '%s/download-block.disabled.json\n' "$(download_block_config_dir)"
}

# route.json 是用户可能手改过的，字段顺序和缩进都不确定，只能用真正的解析器。
# config_append.sh 里已有同样的探测，被 source 进来时直接复用，避免两份实现漂移。
download_block_python_bin() {
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

download_block_py() {
    local py
    py="$(download_block_python_bin)" || return 127
    "$py" - "$@" <<'PY'
import json
import os
import sys

TAG_PREFIX = "download-block"


def load(path):
    with open(path, "r") as handle:
        return json.load(handle)


def rule_tag(rule):
    return str(rule.get("ruleTag", ""))


def is_tagged(rule):
    return rule_tag(rule).startswith(TAG_PREFIX)


# 兜底规则没有任何匹配条件，插在它后面的规则永远轮不到。开启时就插在第一条这样的
# 规则之前；一条都没有（用户自己删了兜底）就追加到末尾。
MATCH_KEYS = (
    "domain", "ip", "port", "sourcePort", "protocol", "source",
    "user", "inboundTag", "attrs", "domainMatcher",
)


def insert_index(rules):
    for index, rule in enumerate(rules):
        if not any(key in rule for key in MATCH_KEYS):
            return index
    return len(rules)


def write_atomic(path, payload):
    tmp = path + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=4)
        handle.write("\n")
    os.replace(tmp, path)


def load_stash(path):
    try:
        stash = load(path)
    except Exception:
        return []
    if not isinstance(stash, list):
        return []
    return [rule for rule in stash if is_tagged(rule)]


def save_stash(path, rules):
    if rules:
        write_atomic(path, rules)
        return
    try:
        os.remove(path)       # 空了就删掉，别留个空数组让人以为还有东西停用着
    except OSError:
        pass


# 升级用：老 route.json 里这几条规则没有 ruleTag，靠形状把它们认出来再打标。
# 只认得出这些确定的老默认值，认不出的一律不碰——宁可少迁，不能改坏用户手写的规则。
LEGACY_DOWNLOAD_DOMAINS = {
    "regexp:(^|[^a-zA-Z]|bit|u)torrent",            # 收窄前的宽泛版
    "regexp:(^|[.])(bittorrent|utorrent)([.]|$)",   # 收窄后、加 ruleTag 前
    "regexp:(^|[.])(xunlei|sandai)",
    "regexp:(^|[.])(ed2k|announce)([.]|$)",
}


def is_legacy_protocol(rule):
    return (rule.get("outboundTag") == "block"
            and not rule.get("ruleTag")
            and rule.get("protocol") == ["bittorrent"])


def is_legacy_port(rule):
    return (rule.get("outboundTag") == "block"
            and not rule.get("ruleTag")
            and "6881" in str(rule.get("port", "")))


mode = sys.argv[1]

if mode == "migrate":
    route_path, defaults_path = sys.argv[2:4]
    try:
        route = load(route_path)
    except Exception as exc:
        sys.stderr.write("route.json 解析失败：%s\n" % exc)
        sys.exit(2)
    if not isinstance(route.get("rules"), list):
        sys.stderr.write("route.json 里没有 rules 数组\n")
        sys.exit(2)

    rules = route["rules"]
    present = {rule_tag(r) for r in rules if is_tagged(r)}
    changed = []

    # 协议与端口规则就地打标，不挪位置、不复制。
    if "download-block-protocol" not in present:
        for rule in rules:
            if is_legacy_protocol(rule):
                rule["ruleTag"] = "download-block-protocol"
                changed.append("download-block-protocol")
                break
    if "download-block-port" not in present:
        for rule in rules:
            if is_legacy_port(rule):
                rule["ruleTag"] = "download-block-port"
                changed.append("download-block-port")
                break

    # 域名黑名单要拆：认识的下载类正则从常规规则里摘出来，另立一条带标记的规则，
    # 内容用当前默认（老的宽泛 torrent 正则就是在这一步被换成收窄版的）。
    if "download-block-domain" not in present:
        hit_index = None
        for index, rule in enumerate(rules):
            if rule.get("ruleTag") or rule.get("outboundTag") != "block":
                continue
            domains = rule.get("domain")
            if not isinstance(domains, list):
                continue
            if any(d in LEGACY_DOWNLOAD_DOMAINS for d in domains):
                hit_index = index
                break
        if hit_index is not None:
            rule = rules[hit_index]
            rule["domain"] = [d for d in rule["domain"]
                              if d not in LEGACY_DOWNLOAD_DOMAINS]
            try:
                defaults = load(defaults_path)
            except Exception as exc:
                sys.stderr.write("无法读取默认规则：%s\n" % exc)
                sys.exit(2)
            new_rule = next((r for r in defaults.get("rules", [])
                             if rule_tag(r) == "download-block-domain"), None)
            if new_rule is None:
                sys.stderr.write("默认规则里没有 download-block-domain\n")
                sys.exit(2)
            insert_at = hit_index + 1
            if not rule["domain"]:      # 摘完空了就别留个空规则
                rules.pop(hit_index)
                insert_at = hit_index
            rules.insert(insert_at, new_rule)
            changed.append("download-block-domain")

    if not changed:
        sys.exit(3)                     # 无需迁移，一个字节都不写
    write_atomic(route_path, route)
    print(" ".join(changed))
    sys.exit(0)

if mode == "state":
    tags = set(sys.argv[3].split())
    try:
        route = load(sys.argv[2])
    except Exception:
        print("unknown")
        sys.exit(0)
    present = {rule_tag(r) for r in route.get("rules", []) if is_tagged(r)}
    # 整组齐了才算开启：少一条就是残缺状态，按关闭报，开启时只补缺的那条。
    print("on" if tags <= present else "off")
    sys.exit(0)

if mode == "apply":
    want, route_path, stash_path, defaults_path = sys.argv[2:6]
    tags = set(sys.argv[6].split())
    try:
        route = load(route_path)
    except Exception as exc:
        sys.stderr.write("route.json 解析失败：%s\n" % exc)
        sys.exit(2)
    if not isinstance(route.get("rules"), list):
        sys.stderr.write("route.json 里没有 rules 数组\n")
        sys.exit(2)

    rules = route["rules"]
    stash = load_stash(stash_path)

    if want == "off":
        moving = [r for r in rules if rule_tag(r) in tags]
        if not moving:
            sys.exit(3)          # 该组已是关闭态，不写文件
        kept_stash = [r for r in stash if rule_tag(r) not in tags]
        save_stash(stash_path, kept_stash + moving)
        route["rules"] = [r for r in rules if rule_tag(r) not in tags]
        write_atomic(route_path, route)
        sys.exit(0)

    if want == "on":
        present = {rule_tag(r) for r in rules if is_tagged(r)}
        missing = tags - present
        if not missing:
            sys.exit(3)          # 该组已齐，不重复插入
        restored = [r for r in stash if rule_tag(r) in missing]
        still_missing = missing - {rule_tag(r) for r in restored}
        if still_missing:        # 存根缺失或损坏，这几条回落到内置默认
            try:
                defaults = load(defaults_path)
            except Exception as exc:
                sys.stderr.write("无法读取默认规则：%s\n" % exc)
                sys.exit(2)
            restored += [r for r in defaults.get("rules", [])
                         if rule_tag(r) in still_missing]
        if not restored:
            sys.stderr.write("找不到可恢复的规则：%s\n" % " ".join(sorted(missing)))
            sys.exit(2)
        index = insert_index(rules)
        route["rules"] = rules[:index] + restored + rules[index:]
        write_atomic(route_path, route)
        save_stash(stash_path, [r for r in stash if rule_tag(r) not in missing])
        sys.exit(0)

sys.stderr.write("unknown mode: %s\n" % mode)
sys.exit(2)
PY
}

# download_block_state [traffic|domain|all]
# 打印 on / off / unknown（unknown = route.json 缺失或解析不了）。始终返回 0，
# 方便直接嵌在提示串里。整组规则齐了才算 on。
download_block_state() {
    local group="${1:-all}" tags route
    if ! tags="$(download_block_group_tags "$group")"; then
        printf 'unknown\n'
        return 0
    fi
    route="$(download_block_route_path)"
    if [[ ! -f "$route" ]]; then
        printf 'unknown\n'
        return 0
    fi
    if ! download_block_py state "$route" "$tags" 2>/dev/null; then
        printf 'unknown\n'
    fi
    return 0
}

# 给菜单用的带颜色状态串。
download_block_state_label() {
    case "$(download_block_state "${1:-all}")" in
        on)  printf '%b' "${green}已开启${plain}" ;;
        off) printf '%b' "${red}已关闭${plain}" ;;
        *)   printf '%b' "${yellow}未知（route.json 缺失或无法解析）${plain}" ;;
    esac
}

# download_block_apply <on|off> [traffic|domain|all]
# 只改 route.json，不碰服务；重启由菜单层负责，测试才能直接调这个函数。
# 返回 0 = 已改写或本就是目标状态，非 0 = 失败。
download_block_apply() {
    local want="$1" group="${2:-all}" tags route stash tmp_dir defaults status
    if [[ "$want" != "on" && "$want" != "off" ]]; then
        echo -e "${red}用法：download_block_apply on|off [traffic|domain|all]${plain}" >&2
        return 1
    fi
    if ! tags="$(download_block_group_tags "$group")"; then
        echo -e "${red}未知分组：${group}（可用：traffic / domain / all）${plain}" >&2
        return 1
    fi

    route="$(download_block_route_path)"
    stash="$(download_block_stash_path)"

    if ! download_block_python_bin >/dev/null; then
        echo -e "${red}未检测到 python3/python，无法安全地修改 route.json。${plain}" >&2
        echo -e "${yellow}请先安装 python3（Debian/Ubuntu: apt-get install -y python3；CentOS: yum install -y python3）。${plain}" >&2
        return 1
    fi

    if [[ ! -f "$route" ]]; then
        echo -e "${red}未找到 ${route}。${plain}" >&2
        echo -e "${yellow}请先使用「生成 N2X 配置文件」创建初始配置。${plain}" >&2
        return 1
    fi

    if ! declare -F write_default_route_json >/dev/null; then
        echo -e "${red}未找到 config_gen.sh 或其版本过旧，无法取得默认规则。${plain}" >&2
        return 1
    fi

    tmp_dir="$(mktemp -d)" || return 1
    defaults="$tmp_dir/route.default.json"
    write_default_route_json "$defaults" || { rm -rf "$tmp_dir"; return 1; }

    download_block_py apply "$want" "$route" "$stash" "$defaults" "$tags"
    status=$?
    rm -rf "$tmp_dir"

    case "$status" in
        0) return 0 ;;   # 已改写
        3) return 0 ;;   # 本就是目标状态，幂等
        *) return 1 ;;
    esac
}

# 升级用的一次性迁移：给老 route.json 里没有 ruleTag 的 BT 规则补上标记，分组开关
# 才能认出它们。幂等，可以每次升级都跑。
#
# 只认得出确定的老默认值：认不出的规则一律不碰，用户关掉的分组也不会被塞回来
# （规则不在 route.json 里就没得打标）。route.json 不存在时静默成功——还没生成过
# 配置的机器同样会走升级流程。
#
# 返回 0 = 已迁移或无需迁移，非 0 = 失败（失败时不写文件）。
download_block_migrate() {
    local route tmp_dir defaults status changed
    route="$(download_block_route_path)"

    [[ -f "$route" ]] || return 0

    if ! download_block_python_bin >/dev/null; then
        echo -e "${yellow}未检测到 python3/python，跳过 route.json 的下载拦截标记迁移。${plain}" >&2
        echo -e "${yellow}装好 python3 后执行 N2X download status 可再次触发。${plain}" >&2
        return 0
    fi
    if ! declare -F write_default_route_json >/dev/null; then
        echo -e "${yellow}未找到 config_gen.sh，跳过下载拦截标记迁移。${plain}" >&2
        return 0
    fi

    tmp_dir="$(mktemp -d)" || return 1
    defaults="$tmp_dir/route.default.json"
    write_default_route_json "$defaults" || { rm -rf "$tmp_dir"; return 1; }

    changed="$(download_block_py migrate "$route" "$defaults")"
    status=$?
    rm -rf "$tmp_dir"

    case "$status" in
        0)
            echo -e "${green}已为 ${route} 中的下载拦截规则补上标记：${changed}${plain}"
            echo -e "${yellow}现在可用「20. 下载拦截管理」或 N2X download 分组开关它们。${plain}"
            return 0
            ;;
        3) return 0 ;;   # 无需迁移
        *) return 1 ;;
    esac
}

# 菜单层：改配置 + 重启服务。restart 由 N2X.sh 提供。
download_block_set() {
    local want="$1" group="${2:-all}" before label
    label="$(download_block_group_label "$group")"
    before="$(download_block_state "$group")"

    if [[ "$before" == "unknown" ]]; then
        echo -e "${red}route.json 缺失或无法解析，拒绝改动。${plain}"
        echo -e "${yellow}请先检查 $(download_block_route_path)。${plain}"
        return 1
    fi

    if ! download_block_apply "$want" "$group"; then
        echo -e "${red}操作失败，route.json 未被改动。${plain}"
        return 1
    fi

    if [[ "$before" == "$want" ]]; then
        echo -e "${yellow}${label}本就处于该状态，未做改动，无需重启。${plain}"
        return 0
    fi

    if [[ "$want" == "on" ]]; then
        echo -e "${green}${label}已开启。${plain}"
    else
        echo -e "${green}${label}已关闭。${plain}"
        echo -e "${yellow}被摘下的规则已存到 $(download_block_stash_path)，重新开启时会原样放回。${plain}"
    fi

    if declare -F restart >/dev/null && [[ -f /usr/local/N2X/N2X ]]; then
        echo -e "${yellow}正在重启 N2X 以使路由改动生效...${plain}"
        restart 0
    else
        echo -e "${yellow}请手动重启 N2X 使改动生效。${plain}"
    fi
    return 0
}

# 菜单里的「切换」：当前 on 就关，off 就开，unknown 拒绝动作。
download_block_flip() {
    local group="$1"
    case "$(download_block_state "$group")" in
        on)  download_block_set off "$group" ;;
        off) download_block_set on "$group" ;;
        *)
            echo -e "${red}route.json 缺失或无法解析，无法切换。${plain}"
            echo -e "${yellow}请先检查 $(download_block_route_path)。${plain}"
            return 1
            ;;
    esac
}

download_block_show_rules() {
    echo -e "配置文件：$(download_block_route_path)"
    echo "------------------------------------------"
    echo -e "${yellow}BT 协议/端口拦截${plain}   当前状态：$(download_block_state_label traffic)"
    echo "  download-block-protocol  协议嗅探判定为 bittorrent 的流量"
    echo "  download-block-port      BT 常用端口 6881-6889,6969,2710,51413"
    echo "  认流量特征，基本不会误伤正常网站。"
    echo "------------------------------------------"
    echo -e "${yellow}下载站域名拦截${plain}     当前状态：$(download_block_state_label domain)"
    echo "  download-block-domain    bittorrent/utorrent、xunlei/sandai、ed2k/announce 域名"
    echo "  认域名字样，torrentmac、torrentfreak 这类资讯/软件站会跟着被拦。"
    echo "------------------------------------------"
    echo -e "${yellow}不受本开关影响（始终生效）：${plain}"
    echo "  私有网段拦截、广告/风控类域名黑名单、socks5-unlock 分流"
    if [[ -f "$(download_block_stash_path)" ]]; then
        echo "------------------------------------------"
        echo -e "${yellow}停用存根：$(download_block_stash_path)${plain}"
    fi
}

before_download_block_menu() {
    echo && echo -n -e "${yellow}按回车返回下载拦截菜单: ${plain}" && read temp
    download_block_menu
}

download_block_menu() {
    echo -e "
  ${green}下载拦截管理${plain}
————————————————
  ${green}1.${plain} 切换 BT 协议/端口拦截    当前：$(download_block_state_label traffic)
  ${green}2.${plain} 切换 下载站域名拦截      当前：$(download_block_state_label domain)
————————————————
  ${green}3.${plain} 两组全部开启
  ${green}4.${plain} 两组全部关闭
  ${green}5.${plain} 查看拦截规则与状态
  ${green}6.${plain} 返回 N2X 主菜单
 "
    read -rp "请输入选择 [1-6]: " num
    case "${num}" in
        1) download_block_flip traffic; before_download_block_menu ;;
        2) download_block_flip domain; before_download_block_menu ;;
        3) download_block_set on all; before_download_block_menu ;;
        4) download_block_set off all; before_download_block_menu ;;
        5) download_block_show_rules; before_download_block_menu ;;
        6) show_menu ;;
        *) echo -e "${red}请输入正确的数字 [1-6]${plain}"; before_download_block_menu ;;
    esac
}

# N2X download [on|off|status] [traffic|domain|all]
download_block_command() {
    local action="${1:-status}" group="${2:-all}"
    case "$action" in
        on|enable)   download_block_set on "$group" ;;
        off|disable) download_block_set off "$group" ;;
        status|"")   download_block_show_rules ;;
        menu)        download_block_menu ;;
        *)
            echo "N2X download on  [traffic|domain]  - 开启下载拦截（省略分组=两组都开）"
            echo "N2X download off [traffic|domain]  - 关闭下载拦截（省略分组=两组都关）"
            echo "N2X download status                - 查看两组状态与规则"
            echo ""
            echo "  traffic  BT 协议 + BT 端口，认流量特征，基本不会误伤"
            echo "  domain   下载站域名，认域名字样，会误伤 torrentmac 这类站点"
            return 1
            ;;
    esac
}
