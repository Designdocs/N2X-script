#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck source=/dev/null
source "${repo_dir}/config_gen.sh"
# shellcheck source=/dev/null
source "${repo_dir}/download_block.sh"

declare -F download_block_migrate >/dev/null || fail "download_block.sh 未定义 download_block_migrate"

cfg_dir="$work_dir/etc/N2X"
mkdir -p "$cfg_dir"
export N2X_CONFIG_DIR="$cfg_dir"
route="$cfg_dir/route.json"
stash="$cfg_dir/download-block.disabled.json"

# 升级前的样子：没有 ruleTag，torrent 正则还是那条宽泛的旧版，域名黑名单 21 条。
write_legacy_route() {
    cat > "$route" <<'JSON'
{
    "domainStrategy": "AsIs",
    "rules": [
        {"type": "field", "outboundTag": "block", "ip": ["geoip:private"]},
        {
            "type": "field",
            "outboundTag": "block",
            "domain": [
                "regexp:(^|[.])(360|so)[.](cn|com)",
                "regexp:(^|[^a-zA-Z]|bit|u)torrent",
                "regexp:(^|[.])(xunlei|sandai)",
                "regexp:(^|[.])(ed2k|announce)([.]|$)",
                "regexp:(^|[.])(taobao)[.](com)"
            ]
        },
        {"type": "field", "outboundTag": "block", "ip": ["127.0.0.1/32", "10.0.0.0/8"]},
        {"type": "field", "outboundTag": "block", "protocol": ["bittorrent"]},
        {"type": "field", "outboundTag": "block", "network": "tcp,udp", "port": "6881-6889,6969,2710,51413"},
        {"type": "field", "outboundTag": "socks5-unlock", "domain": ["domain:socks5-unlock.invalid"]},
        {"type": "field", "outboundTag": "IPv4_out", "network": "udp,tcp"}
    ]
}
JSON
}

present_tags() {
    python3 - "$route" <<'PY'
import json, sys
rules = json.load(open(sys.argv[1]))["rules"]
print(" ".join(sorted(str(r.get("ruleTag", "")) for r in rules
                      if str(r.get("ruleTag", "")).startswith("download-block"))))
PY
}

ALL="download-block-domain download-block-port download-block-protocol"

# --- 1. 老配置：三条规则全部打上标记 ----------------------------------------
write_legacy_route
[[ "$(present_tags)" == "" ]] || fail "前置条件错了，老配置不该有标记"

download_block_migrate || fail "迁移返回非零"
python3 -m json.tool "$route" >/dev/null 2>&1 || fail "迁移后不是合法 JSON"
[[ "$(present_tags)" == "$ALL" ]] || fail "迁移后应有三条标记，实得 [$(present_tags)]"

python3 - "$route" <<'PY' || fail "迁移结果不对"
import json, sys
rules = json.load(open(sys.argv[1]))["rules"]

# 兜底仍在最后
assert rules[-1].get("outboundTag") == "IPv4_out"

# 协议/端口规则是就地打标，不该被挪走或复制
proto = [r for r in rules if r.get("ruleTag") == "download-block-protocol"]
port = [r for r in rules if r.get("ruleTag") == "download-block-port"]
assert len(proto) == 1 and proto[0]["protocol"] == ["bittorrent"]
assert len(port) == 1 and port[0]["port"] == "6881-6889,6969,2710,51413"

# 域名黑名单被拆开：认识的下载类正则移出去，不认识的原样留下
general = [r for r in rules if r.get("outboundTag") == "block"
           and r.get("domain") and not r.get("ruleTag")]
assert len(general) == 1, f"常规黑名单应剩 1 条，实得 {len(general)}"
assert general[0]["domain"] == [
    "regexp:(^|[.])(360|so)[.](cn|com)",
    "regexp:(^|[.])(taobao)[.](com)",
], general[0]["domain"]

# 老的宽泛正则要换成当前默认那条收窄版，否则升级完 torrentmac 还是被拦
dom = [r for r in rules if r.get("ruleTag") == "download-block-domain"]
assert len(dom) == 1
joined = " ".join(dom[0]["domain"])
assert "(^|[^a-zA-Z]|bit|u)torrent" not in joined, "旧的宽泛 torrent 正则没被替换"
assert "regexp:(^|[.])(bittorrent|utorrent)([.]|$)" in dom[0]["domain"]
assert "regexp:(^|[.])(xunlei|sandai)" in dom[0]["domain"]
assert "regexp:(^|[.])(ed2k|announce)([.]|$)" in dom[0]["domain"]

# 其它规则一条不能少
assert any(r.get("ip") == ["geoip:private"] for r in rules)
assert any("127.0.0.1/32" in (r.get("ip") or []) for r in rules)
assert any(r.get("outboundTag") == "socks5-unlock" for r in rules)
PY

# --- 2. 幂等：再跑一次不改任何东西 ------------------------------------------
before="$(cat "$route")"
download_block_migrate || fail "重复迁移返回非零"
[[ "$(cat "$route")" == "$before" ]] || fail "重复迁移不该改动文件"

# --- 3. 迁移完就能正常开关 --------------------------------------------------
download_block_apply off domain || fail "迁移后关闭 domain 失败"
[[ "$(present_tags)" == "download-block-port download-block-protocol" ]] \
    || fail "迁移后分组开关不生效"
download_block_apply on domain || fail "迁移后开启 domain 失败"
[[ "$(present_tags)" == "$ALL" ]] || fail "迁移后开启 domain 未恢复"

# --- 4. 当前默认配置：已带标记，迁移是空操作 --------------------------------
write_default_route_json "$route"
before="$(cat "$route")"
download_block_migrate || fail "对新配置迁移返回非零"
[[ "$(cat "$route")" == "$before" ]] || fail "新配置不该被迁移改动"

# --- 5. 用户已关掉某组：迁移不得把规则塞回来 --------------------------------
write_default_route_json "$route"
download_block_apply off domain || fail "准备用例失败"
[[ -f "$stash" ]] || fail "准备用例失败：应有存根"
download_block_migrate || fail "迁移返回非零"
[[ "$(present_tags)" == "download-block-port download-block-protocol" ]] \
    || fail "迁移把用户关掉的 domain 组塞回来了"

# --- 6. 部分迁移：只补没打上的那条 ------------------------------------------
python3 - "$route" <<'PY'
import json, sys
path = sys.argv[1]
route = json.load(open(path))
for rule in route["rules"]:
    if rule.get("ruleTag") == "download-block-port":
        del rule["ruleTag"]          # 模拟只迁了一半
json.dump(route, open(path, "w"), ensure_ascii=False, indent=4)
PY
[[ "$(present_tags)" == "download-block-protocol" ]] || fail "准备用例失败"
download_block_migrate || fail "部分迁移返回非零"
[[ "$(present_tags)" == "download-block-port download-block-protocol" ]] \
    || fail "未补上缺失的 port 标记"

# --- 7. 与本功能无关的配置：不动 --------------------------------------------
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
before="$(cat "$route")"
download_block_migrate || fail "无关配置迁移返回非零"
[[ "$(cat "$route")" == "$before" ]] || fail "没有 BT 规则时不该改动文件"

# --- 8. route.json 缺失：空操作，不报错（还没装配置的机器也会走升级流程）----
rm -f "$route"
download_block_migrate || fail "route.json 不存在时应静默成功"
[[ ! -f "$route" ]] || fail "route.json 不存在时不该凭空创建"

# --- 9. route.json 损坏：报错且不写坏文件 -----------------------------------
printf '{ this is not json' > "$route"
if download_block_migrate 2>/dev/null; then
    fail "route.json 损坏时必须返回非零"
fi
[[ "$(cat "$route")" == '{ this is not json' ]] || fail "解析失败时不得改写原文件"

# --- 10. 接线：升级流程要调用迁移 -------------------------------------------
python3 - "$repo_dir" <<'WIRING' || fail "升级流程未接入迁移"
from pathlib import Path
import sys

repo = Path(sys.argv[1])
install = (repo / "install.sh").read_text()
n2x = (repo / "N2X.sh").read_text()

# install.sh 在装完配套文件后跑迁移：升级走的也是这条路径。
assert "download_block_migrate" in install, "install.sh 未调用 download_block_migrate"
assert "install_xray_side_files" in install
assert install.index("install_xray_side_files() {") < install.index("run_download_block_migration")

# 只升脚本（update_shell）同样要迁移，否则 config_gen.sh 新了、route.json 还是旧的。
assert "download_block_migrate" in n2x, "N2X.sh update_shell 未调用迁移"
WIRING

echo "旧配置迁移行为正确"
