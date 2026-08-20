#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# download_block.sh 只负责改 route.json，不碰 systemd；重启由菜单层做。所以这里
# 可以直接 source 出来跑，断言落在真实写出的 JSON 上。
# shellcheck source=/dev/null
source "${repo_dir}/config_gen.sh"
# shellcheck source=/dev/null
source "${repo_dir}/download_block.sh"

for fn in download_block_state download_block_apply download_block_group_tags \
          download_block_menu download_block_command; do
    declare -F "$fn" >/dev/null || fail "download_block.sh 未定义 ${fn}"
done

cfg_dir="$work_dir/etc/N2X"
mkdir -p "$cfg_dir"
export N2X_CONFIG_DIR="$cfg_dir"
route="$cfg_dir/route.json"
stash="$cfg_dir/download-block.disabled.json"

assert_json() {
    python3 -m json.tool "$1" >/dev/null 2>&1 || fail "$1 不是合法 JSON"
}

# 断言兜底规则永远是最后一条——它一旦被挤到前面，后面的规则就全部失效。
assert_fallback_last() {
    python3 - "$route" <<'PY' || exit 1
import json, sys
rules = json.load(open(sys.argv[1]))["rules"]
assert rules[-1].get("outboundTag") == "IPv4_out", "IPv4_out 兜底规则必须是最后一条"
assert rules[-1].get("network") == "udp,tcp"
PY
}

# route.json 里现存的 download-block-* 标记，按字母序、空格分隔
present_tags() {
    python3 - "$route" <<'PY'
import json, sys
rules = json.load(open(sys.argv[1]))["rules"]
tags = sorted(str(r.get("ruleTag", "")) for r in rules
              if str(r.get("ruleTag", "")).startswith("download-block"))
print(" ".join(tags))
PY
}

# 停用存根里的标记
stashed_tags() {
    [[ -f "$stash" ]] || { echo ""; return 0; }
    python3 - "$stash" <<'PY'
import json, sys
rules = json.load(open(sys.argv[1]))
print(" ".join(sorted(str(r.get("ruleTag", "")) for r in rules)))
PY
}

expect_tags() {
    local want="$1" got
    got="$(present_tags)"
    [[ "$got" == "$want" ]] || fail "route.json 标记应为 [$want]，实得 [$got]"
}

expect_state() {
    local group="$1" want="$2" got
    got="$(download_block_state "$group")"
    [[ "$got" == "$want" ]] || fail "${group} 状态应为 ${want}，实得 ${got}"
}

TRAFFIC="download-block-port download-block-protocol"
DOMAIN="download-block-domain"
ALL="download-block-domain download-block-port download-block-protocol"

# --- 0. 分组定义：两组互不重叠，合起来正好是全部 ----------------------------
[[ "$(download_block_group_tags traffic | tr ' ' '\n' | sort | tr '\n' ' ')" == "download-block-port download-block-protocol " ]] \
    || fail "traffic 组应为 protocol + port"
[[ "$(download_block_group_tags domain | tr ' ' '\n' | sort | tr '\n' ' ')" == "download-block-domain " ]] \
    || fail "domain 组应只含 domain"
download_block_group_tags bogus >/dev/null 2>&1 && fail "未知分组必须返回非零"

# --- 1. 默认 route.json：两组都开 -------------------------------------------
write_default_route_json "$route"
assert_json "$route"
expect_tags "$ALL"
expect_state traffic on
expect_state domain on
expect_state all on

# --- 2. 只关 traffic：domain 不受影响 ---------------------------------------
download_block_apply off traffic || fail "关闭 traffic 返回非零"
assert_json "$route"
assert_fallback_last
expect_tags "$DOMAIN"
expect_state traffic off
expect_state domain on
expect_state all off
[[ "$(stashed_tags)" == "$TRAFFIC" ]] || fail "存根应只含 traffic 两条，实得 [$(stashed_tags)]"

python3 - "$route" <<'PY' || fail "关 traffic 误伤了域名规则"
import json, sys
rules = json.load(open(sys.argv[1]))["rules"]
dom = [r for r in rules if r.get("ruleTag") == "download-block-domain"]
assert len(dom) == 1, "下载域名规则应仍在"
assert "bittorrent|utorrent" in " ".join(dom[0]["domain"])
assert not any(r.get("protocol") == ["bittorrent"] for r in rules), "BT 协议规则未移除"
assert not any("6881-6889" in str(r.get("port", "")) for r in rules), "BT 端口规则未移除"
# 常规黑名单与解锁规则一条不能少
assert any(r.get("ip") == ["geoip:private"] for r in rules)
assert any(r.get("outboundTag") == "socks5-unlock" for r in rules)
general = [r for r in rules if r.get("outboundTag") == "block"
           and r.get("domain") and not r.get("ruleTag")]
assert len(general) == 1 and len(general[0]["domain"]) == 18
PY

# --- 3. 再关 domain：两组都进存根 -------------------------------------------
download_block_apply off domain || fail "关闭 domain 返回非零"
expect_tags ""
expect_state traffic off
expect_state domain off
[[ "$(stashed_tags)" == "$ALL" ]] || fail "存根应含全部三条，实得 [$(stashed_tags)]"
assert_fallback_last

# --- 4. 幂等：重复关同一组不报错、不写重复 ----------------------------------
download_block_apply off domain || fail "重复关闭应幂等返回 0"
[[ "$(stashed_tags)" == "$ALL" ]] || fail "重复关闭把存根写重了"

# --- 5. 只开 traffic：domain 仍关，存根只剩 domain --------------------------
download_block_apply on traffic || fail "开启 traffic 返回非零"
assert_json "$route"
assert_fallback_last
expect_tags "$TRAFFIC"
expect_state traffic on
expect_state domain off
[[ "$(stashed_tags)" == "$DOMAIN" ]] || fail "存根应只剩 domain，实得 [$(stashed_tags)]"

download_block_apply on traffic || fail "重复开启应幂等返回 0"
expect_tags "$TRAFFIC"

# --- 6. 再开 domain：全部恢复，存根清空删除 ---------------------------------
download_block_apply on domain || fail "开启 domain 返回非零"
expect_tags "$ALL"
expect_state all on
[[ ! -f "$stash" ]] || fail "存根空了就该删掉"
assert_fallback_last

python3 - "$route" <<'PY' || fail "恢复后规则内容不对"
import json, sys
rules = json.load(open(sys.argv[1]))["rules"]
tagged = [r for r in rules if str(r.get("ruleTag", "")).startswith("download-block")]
assert len(tagged) == 3
assert all(r.get("outboundTag") == "block" for r in tagged)
assert all(r.get("type") == "field" for r in tagged), "每条规则都要带 type=field"
PY

# --- 7. all 组：一次开关两组 ------------------------------------------------
download_block_apply off all || fail "关闭 all 返回非零"
expect_tags ""
download_block_apply on all || fail "开启 all 返回非零"
expect_tags "$ALL"
# 省略分组时默认按 all 处理
download_block_apply off || fail "省略分组时应等价于 all"
expect_tags ""
download_block_apply on || fail "省略分组时应等价于 all"
expect_tags "$ALL"

# --- 8. 部分缺失时开启：只补缺的那条，不写重复 ------------------------------
download_block_apply off traffic || fail "准备用例失败"
rm -f "$stash"
expect_tags "$DOMAIN"
download_block_apply on all || fail "部分缺失时开启失败"
expect_tags "$ALL"        # domain 本就在，不该被插第二遍
assert_fallback_last

# --- 9. 存根丢失时自愈：按分组回落到内置默认 --------------------------------
download_block_apply off domain || fail "自愈用例：关闭失败"
rm -f "$stash"
expect_state domain off
download_block_apply on domain || fail "存根丢失时开启应回落到内置默认"
expect_tags "$ALL"
python3 - "$route" <<'PY' || fail "自愈插入的域名规则内容不对"
import json, sys
rules = json.load(open(sys.argv[1]))["rules"]
dom = [r for r in rules if r.get("ruleTag") == "download-block-domain"]
assert len(dom) == 1 and len(dom[0]["domain"]) == 3
PY

# --- 10. 用户自定义 route.json：只开域名组也能插到兜底之前 ------------------
cat > "$route" <<'JSON'
{
    "domainStrategy": "AsIs",
    "rules": [
        {"type": "field", "outboundTag": "block", "ip": ["geoip:private"]},
        {"type": "field", "outboundTag": "IPv4_out", "network": "udp,tcp"}
    ]
}
JSON
rm -f "$stash"
expect_state domain off
expect_state traffic off
download_block_apply on domain || fail "自定义 route.json 开启 domain 失败"
assert_json "$route"
assert_fallback_last
expect_tags "$DOMAIN"
expect_state traffic off

python3 - "$route" <<'PY' || fail "插入位置不对"
import json, sys
rules = json.load(open(sys.argv[1]))["rules"]
tags = [str(r.get("ruleTag", "")) for r in rules]
first = next(i for i, t in enumerate(tags) if t.startswith("download-block"))
fallback = next(i for i, r in enumerate(rules) if r.get("outboundTag") == "IPv4_out")
assert first < fallback, "下载拦截规则必须排在兜底规则之前，否则永远匹配不到"
assert rules[0].get("ip") == ["geoip:private"], "用户原有规则的顺序被打乱"
PY

# --- 11. 非法分组 / route.json 缺失 / 损坏：报错而不写坏文件 ----------------
if download_block_apply on bogus 2>/dev/null; then
    fail "未知分组必须返回非零"
fi

rm -f "$route" "$stash"
if download_block_apply on traffic 2>/dev/null; then
    fail "route.json 不存在时必须返回非零"
fi

printf '{ this is not json' > "$route"
if download_block_apply off domain 2>/dev/null; then
    fail "route.json 损坏时必须返回非零"
fi
[[ "$(cat "$route")" == '{ this is not json' ]] || fail "解析失败时不得改写原文件"
expect_state traffic unknown
expect_state domain unknown

# --- 12. 接线：菜单、子命令、安装与升级都要带上新模块 -----------------------
python3 - "$repo_dir" <<'WIRING' || fail "N2X.sh / install.sh 未正确接入 download_block.sh"
from pathlib import Path
import sys

repo = Path(sys.argv[1])
n2x = (repo / "N2X.sh").read_text()
install = (repo / "install.sh").read_text()

# N2X.sh 只是壳，功能在被 source 的模块里；漏了 source 菜单就会调到不存在的函数。
assert 'source "$SCRIPT_DIR/download_block.sh"' in n2x, "N2X.sh 未 source download_block.sh"
assert "source /usr/local/N2X/download_block.sh" in n2x, "N2X.sh 缺少已安装路径的兜底 source"

assert "20.${plain} 下载拦截管理" in n2x, "主菜单没有下载拦截入口"
assert "20) download_block_menu ;;" in n2x, "主菜单 20 未接到 download_block_menu"
assert "21) exit ;;" in n2x, "退出项应顺延到 21"
assert "[0-21]" in n2x and "[0-20]" not in n2x, "菜单编号范围未同步更新"

assert "download_block_command" in n2x, "缺少 N2X download 子命令"

# 只更新壳会让新菜单调到旧模块，升级时必须一起拉。
assert "config_append.sh download_block.sh; do" in n2x, "update_shell 未一并更新 download_block.sh"

assert "/usr/local/N2X/download_block.sh" in install, "install.sh 未安装 download_block.sh"
assert "chmod +x /usr/local/N2X/download_block.sh" in install, "install.sh 未给模块加执行位"
WIRING

echo "下载拦截分组启停行为正确"
