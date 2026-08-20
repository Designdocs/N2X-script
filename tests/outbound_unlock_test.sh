#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=/dev/null
source "${repo_dir}/config_gen.sh"
# shellcheck source=/dev/null
source "${repo_dir}/download_block.sh"
# shellcheck source=/dev/null
source "${repo_dir}/outbound_unlock.sh"

for fn in outbound_unlock_validate_tag outbound_unlock_validate_port \
          outbound_unlock_validate_address outbound_unlock_validate_domain_entry \
          outbound_unlock_add outbound_unlock_tags outbound_unlock_clear \
          outbound_unlock_parse_url outbound_unlock_add_raw \
          outbound_unlock_menu outbound_unlock_command; do
    declare -F "$fn" >/dev/null || fail "outbound_unlock.sh 未定义 ${fn}"
done

cfg_dir="$work_dir/etc/N2X"
mkdir -p "$cfg_dir"
export N2X_CONFIG_DIR="$cfg_dir"
outbound="$cfg_dir/custom_outbound.json"
route="$cfg_dir/route.json"

reset_files() {
    write_default_custom_outbound_json "$outbound"
    write_default_route_json "$route"
    rm -f "$cfg_dir"/*.bak.* "$cfg_dir/download-block.disabled.json"
}

assert_json() { python3 -m json.tool "$1" >/dev/null 2>&1 || fail "$1 不是合法 JSON"; }

# --- 1. 校验函数 ------------------------------------------------------------
reset_files

for good in unlock1 http-unlock my_unlock a1; do
    outbound_unlock_validate_tag "$good" || fail "标签 ${good} 应通过"
done
for bad in "" "有中文" "with space" "-leading" "a/b" "a\"b"; do
    outbound_unlock_validate_tag "$bad" 2>/dev/null && fail "标签 [${bad}] 应被拒绝"
done
# 保留标签与已存在标签都不能用
for reserved in IPv4_out IPv6_out block socks5-unlock; do
    outbound_unlock_validate_tag "$reserved" 2>/dev/null && fail "保留标签 ${reserved} 应被拒绝"
done

for good in 1 80 10003 65535; do
    outbound_unlock_validate_port "$good" || fail "端口 ${good} 应通过"
done
for bad in 0 65536 -1 "" abc 1.5 " 80"; do
    outbound_unlock_validate_port "$bad" 2>/dev/null && fail "端口 [${bad}] 应被拒绝"
done

for good in abc.decodo.com 1.2.3.4 example.com "::1" 2001:db8::1; do
    outbound_unlock_validate_address "$good" || fail "地址 ${good} 应通过"
done
for bad in "" "has space" "http://a.com" "a.com:80" "-a.com"; do
    outbound_unlock_validate_address "$bad" 2>/dev/null && fail "地址 [${bad}] 应被拒绝"
done

for good in geosite:openai domain:openai.com full:chat.openai.com "regexp:.*openai.*" openai.com ext:geoip.dat:cn; do
    outbound_unlock_validate_domain_entry "$good" || fail "域名条目 ${good} 应通过"
done
for bad in "" "has space" "geosite:" "domain:" "有中文.com"; do
    outbound_unlock_validate_domain_entry "$bad" 2>/dev/null && fail "域名条目 [${bad}] 应被拒绝"
done

# --- 2. 添加一条带 TLS 与账号密码的 http 解锁 -------------------------------
reset_files
outbound_unlock_add "http-unlock" http abc.decodo.com 10003 spvtsramrb 'B8sd"as\efs' \
    1 abc.decodo.com 0 geosite:anthropic geosite:openai geosite:google-deepmind \
    || fail "添加失败"
assert_json "$outbound"; assert_json "$route"

python3 - "$outbound" "$route" <<'PY' || fail "写入内容不对"
import json, sys
outbounds = json.load(open(sys.argv[1]))
rules = json.load(open(sys.argv[2]))["rules"]

tags = [o.get("tag") for o in outbounds]
assert "http-unlock" in tags, tags
# 新出站排在 IPv4_out / IPv6_out 之后、block 之前。
assert tags.index("IPv4_out") < tags.index("http-unlock"), tags
assert tags.index("IPv6_out") < tags.index("http-unlock"), tags
assert tags.index("http-unlock") < tags.index("block"), tags
# 列表第一条会被 xray 当默认出站，自定义解锁绝不能占这个位置
assert tags[0] == "IPv4_out", tags
# 原有出站一个不少、顺序不乱
assert tags == ["IPv4_out", "IPv6_out", "socks5-unlock", "http-unlock", "block"], tags

ob = next(o for o in outbounds if o["tag"] == "http-unlock")
assert ob["protocol"] == "http"
srv = ob["settings"]["servers"]
assert len(srv) == 1
assert srv[0]["address"] == "abc.decodo.com" and srv[0]["port"] == 10003
assert isinstance(srv[0]["port"], int), "端口必须是数字而不是字符串"
# 密码里的引号和反斜杠必须被正确转义（靠 json 库，不能拼字符串）
assert srv[0]["users"] == [{"user": "spvtsramrb", "pass": 'B8sd"as\\efs'}], srv[0]["users"]
assert ob["streamSettings"]["security"] == "tls"
assert ob["streamSettings"]["tlsSettings"]["serverName"] == "abc.decodo.com"
assert ob["streamSettings"]["tlsSettings"]["allowInsecure"] is False

hits = [r for r in rules if r.get("outboundTag") == "http-unlock"]
assert len(hits) == 1
rule = hits[0]
assert rule["type"] == "field"
assert rule["ruleTag"] == "custom-unlock-http-unlock"
# 统一用 domain（domains 也被核心接受，但文件里其它规则都是 domain）
assert "domains" not in rule
assert rule["domain"] == ["geosite:anthropic", "geosite:openai", "geosite:google-deepmind"]
# 必须排在兜底规则之前，否则永远匹配不到
fallback = next(i for i, r in enumerate(rules) if r.get("outboundTag") == "IPv4_out"
                and r.get("network") == "udp,tcp")
assert rules.index(rule) < fallback
assert fallback == len(rules) - 1, "兜底规则必须仍是最后一条"
PY

[[ "$(outbound_unlock_tags)" == "http-unlock" ]] || fail "tags 应为 http-unlock，实得 [$(outbound_unlock_tags)]"

# --- 3. 无账号密码、无 TLS 的 socks 解锁 ------------------------------------
outbound_unlock_add "sk5-unlock" socks 1.2.3.4 1080 "" "" 0 "" 0 domain:netflix.com \
    || fail "添加第二条失败"
python3 - "$outbound" <<'PY' || fail "无账号/无 TLS 的写入不对"
import json, sys
outbounds = json.load(open(sys.argv[1]))
ob = next(o for o in outbounds if o["tag"] == "sk5-unlock")
assert ob["protocol"] == "socks", ob["protocol"]
srv = ob["settings"]["servers"][0]
assert "users" not in srv, "没填账号就不该写空的 users"
assert "streamSettings" not in ob, "没开 TLS 就不该写 streamSettings"
tags = [o.get("tag") for o in outbounds]
assert tags.index("IPv4_out") < tags.index("sk5-unlock") < tags.index("block"), tags
assert tags[0] == "IPv4_out", tags
PY
[[ "$(outbound_unlock_tags)" == "http-unlock sk5-unlock" ]] \
    || fail "两条都应在，实得 [$(outbound_unlock_tags)]"

# --- 4. allowInsecure 与自定义 SNI ------------------------------------------
outbound_unlock_add "tls-unlock" http h.example.com 443 u p 1 sni.example.com 1 geosite:google \
    || fail "添加第三条失败"
python3 - "$outbound" <<'PY' || fail "TLS 参数不对"
import json, sys
ob = next(o for o in json.load(open(sys.argv[1])) if o["tag"] == "tls-unlock")
t = ob["streamSettings"]["tlsSettings"]
assert t["serverName"] == "sni.example.com"
assert t["allowInsecure"] is True
PY

# --- 4b. 畸形出站文件：block 排在最前时也不能占掉默认出站的位置 -------------
saved_ob="$(cat "$outbound")"
python3 - "$outbound" <<'PY'
import json, sys
path = sys.argv[1]
outbounds = json.load(open(path))
block = next(o for o in outbounds if o.get("tag") == "block")
outbounds.remove(block)
json.dump([block] + outbounds, open(path, "w"), ensure_ascii=False, indent=4)
PY
outbound_unlock_add "edge-unlock" http e.example.com 8080 "" "" 0 "" 0 geosite:e     || fail "畸形出站文件下添加失败"
python3 - "$outbound" <<'PY' || fail "畸形配置下的插入位置不对"
import json, sys
tags = [o.get("tag") for o in json.load(open(sys.argv[1]))]
assert tags[0] == "block", tags          # 原有顺序不擅自重排
assert tags.index("edge-unlock") != 0, "自定义解锁不能成为默认出站"
PY
printf '%s' "$saved_ob" > "$outbound"
python3 - "$route" <<'PY'
import json, sys
path = sys.argv[1]
route = json.load(open(path))
route["rules"] = [r for r in route["rules"]
                  if r.get("ruleTag") != "custom-unlock-edge-unlock"]
json.dump(route, open(path, "w"), ensure_ascii=False, indent=4)
PY

# --- 5. 标签冲突：已存在的标签不能再加 --------------------------------------
outbound_unlock_validate_tag "http-unlock" 2>/dev/null && fail "已存在的标签应被拒绝"
if outbound_unlock_add "http-unlock" http a.com 1 "" "" 0 "" 0 geosite:x 2>/dev/null; then
    fail "重复标签添加必须失败"
fi
[[ "$(outbound_unlock_tags)" == "http-unlock sk5-unlock tls-unlock" ]] || fail "失败的添加不该改文件"

# --- 6. 参数非法时不写任何文件 ----------------------------------------------
before_ob="$(cat "$outbound")"; before_rt="$(cat "$route")"
if outbound_unlock_add "bad tag" http a.com 1 "" "" 0 "" 0 geosite:x 2>/dev/null; then
    fail "非法标签必须失败"
fi
if outbound_unlock_add "ok1" http a.com 99999 "" "" 0 "" 0 geosite:x 2>/dev/null; then
    fail "非法端口必须失败"
fi
if outbound_unlock_add "ok2" ftp a.com 80 "" "" 0 "" 0 geosite:x 2>/dev/null; then
    fail "非法协议必须失败"
fi
if outbound_unlock_add "ok3" http a.com 80 "" "" 0 "" 0 2>/dev/null; then
    fail "没有域名条目必须失败"
fi
if outbound_unlock_add "ok4" http a.com 80 "" "" 0 "" 0 "bad entry" 2>/dev/null; then
    fail "非法域名条目必须失败"
fi
[[ "$(cat "$outbound")" == "$before_ob" ]] || fail "失败时 custom_outbound.json 被改动了"
[[ "$(cat "$route")" == "$before_rt" ]] || fail "失败时 route.json 被改动了"

# --- 7. 清除：恢复默认 + 备份 -----------------------------------------------
count_bak() { ls "$cfg_dir" | grep -c '\.bak\.' || true; }
[[ "$(count_bak)" == "0" ]] || fail "前置条件：不该已有备份"

outbound_unlock_clear || fail "清除失败"
assert_json "$outbound"; assert_json "$route"
[[ "$(outbound_unlock_tags)" == "" ]] || fail "清除后不该还有自定义解锁"

python3 - "$outbound" "$route" "$repo_dir" <<'PY' || fail "清除后与默认文件不一致"
import json, subprocess, sys, tempfile, os
ob_path, rt_path, repo = sys.argv[1:4]
tmp = tempfile.mkdtemp()
subprocess.run(["bash", "-c",
                f'source "{repo}/config_gen.sh"; '
                f'write_default_custom_outbound_json "{tmp}/ob.json"; '
                f'write_default_route_json "{tmp}/rt.json"'], check=True)
assert json.load(open(ob_path)) == json.load(open(f"{tmp}/ob.json")), "custom_outbound.json 未恢复默认"
assert json.load(open(rt_path)) == json.load(open(f"{tmp}/rt.json")), "route.json 未恢复默认"
PY

[[ "$(count_bak)" == "2" ]] || fail "清除前应各备份一份，实得 $(count_bak)"

# --- 8. 清除要保住下载拦截的开关状态 ----------------------------------------
reset_files
outbound_unlock_add "u1" http a.com 80 "" "" 0 "" 0 geosite:x || fail "准备用例失败"
download_block_apply off domain || fail "准备用例失败"
[[ "$(download_block_state domain)" == "off" ]] || fail "准备用例失败"
[[ "$(download_block_state traffic)" == "on" ]] || fail "准备用例失败"

outbound_unlock_clear || fail "清除失败"
[[ "$(outbound_unlock_tags)" == "" ]] || fail "清除后不该还有自定义解锁"
[[ "$(download_block_state domain)" == "off" ]] \
    || fail "清除把用户关掉的下载域名拦截又打开了"
[[ "$(download_block_state traffic)" == "on" ]] || fail "traffic 组状态被改了"

# --- 9. 文件损坏：报错且不写 ------------------------------------------------
reset_files
printf '{ not json' > "$outbound"
if outbound_unlock_add "x" http a.com 80 "" "" 0 "" 0 geosite:x 2>/dev/null; then
    fail "custom_outbound.json 损坏时必须失败"
fi
[[ "$(cat "$outbound")" == '{ not json' ]] || fail "损坏时不得改写原文件"

reset_files
printf '{ not json' > "$route"
if outbound_unlock_add "x" http a.com 80 "" "" 0 "" 0 geosite:x 2>/dev/null; then
    fail "route.json 损坏时必须失败"
fi
[[ "$(cat "$route")" == '{ not json' ]] || fail "损坏时不得改写原文件"
python3 - "$outbound" <<'PY' || fail "route.json 写不成时 custom_outbound.json 也不能留下半截改动"
import json, sys
tags = [o.get("tag") for o in json.load(open(sys.argv[1]))]
assert "x" not in tags, "两个文件必须同成同败，实得 " + str(tags)
PY

# --- 10. 文件缺失：明确报错 -------------------------------------------------
reset_files; rm -f "$outbound"
if outbound_unlock_add "x" http a.com 80 "" "" 0 "" 0 geosite:x 2>/dev/null; then
    fail "custom_outbound.json 缺失时必须失败"
fi

# --- 11. 粘贴代理链接：解析出各字段 -----------------------------------------
reset_files

# 期望输出：protocol<TAB>address<TAB>port<TAB>user<TAB>pass<TAB>tls
expect_url() {
    local url="$1" want="$2" got
    got="$(outbound_unlock_parse_url "$url")" \
        || fail "链接应能解析：${url}"
    [[ "$got" == "$want" ]] || fail "链接 ${url} 解析为 [${got}]，期望 [${want}]"
}

expect_url "socks5://user:pass@1.2.3.4:1080" \
    "$(printf 'socks	1.2.3.4	1080	user	pass	0')"
# socks5h 只是让代理端做 DNS，xray 的 socks 出站本来就把域名发给代理，同等对待
expect_url "socks5h://u:p@host.example.com:1080" \
    "$(printf 'socks	host.example.com	1080	u	p	0')"
expect_url "socks://host.example.com:1080" \
    "$(printf 'socks	host.example.com	1080			0')"
expect_url "http://spvtsramrb:B8sd@abc.decodo.com:10003" \
    "$(printf 'http	abc.decodo.com	10003	spvtsramrb	B8sd	0')"
# https 映射成 http 协议 + TLS
expect_url "https://u:p@abc.decodo.com:443" \
    "$(printf 'http	abc.decodo.com	443	u	p	1')"
# 百分号编码要还原，否则带 @ : / 的密码全错
expect_url "http://us%40er:p%3Ap%2Fs@h.example.com:80" \
    "$(printf 'http	h.example.com	80	us@er	p:p/s	0')"
# IPv6 要脱掉方括号
expect_url "socks5://[2001:db8::1]:1080" \
    "$(printf 'socks	2001:db8::1	1080			0')"
# 省略端口时按协议给默认值
expect_url "http://h.example.com" "$(printf 'http	h.example.com	80			0')"
expect_url "https://h.example.com" "$(printf 'http	h.example.com	443			1')"
expect_url "socks5://h.example.com" "$(printf 'socks	h.example.com	1080			0')"
# 路径和查询串直接丢掉
expect_url "socks5://u:p@h.example.com:1080/foo?x=1" \
    "$(printf 'socks	h.example.com	1080	u	p	0')"

for bad in "" "notaurl" "ftp://a.com:21" "http://" "http://h.example.com:99999" \
           "http://h.example.com:abc" "vmess://abcdef" "http://:8080"; do
    outbound_unlock_parse_url "$bad" >/dev/null 2>&1 && fail "链接 [${bad}] 应被拒绝"
done

# 解析出来的字段要能直接喂给 outbound_unlock_add
IFS=$'\t' read -r u_proto u_addr u_port u_user u_pass u_tls \
    < <(outbound_unlock_parse_url "https://spvtsramrb:B8sd@abc.decodo.com:10003")
outbound_unlock_add "from-url" "$u_proto" "$u_addr" "$u_port" "$u_user" "$u_pass" \
    "$u_tls" "" 0 geosite:openai || fail "用链接解析结果添加失败"
python3 - "$outbound" <<'PY' || fail "链接添加的内容不对"
import json, sys
ob = next(o for o in json.load(open(sys.argv[1])) if o["tag"] == "from-url")
srv = ob["settings"]["servers"][0]
assert ob["protocol"] == "http"
assert srv["address"] == "abc.decodo.com" and srv["port"] == 10003
assert srv["users"] == [{"user": "spvtsramrb", "pass": "B8sd"}]
# 没给 SNI 时回落到地址本身
assert ob["streamSettings"]["tlsSettings"]["serverName"] == "abc.decodo.com"
PY

# --- 12. 粘贴完整出站 JSON --------------------------------------------------
reset_files

raw='{"tag":"raw-unlock","protocol":"http","settings":{"servers":[{"address":"r.example.com","port":8080,"users":[{"user":"a","pass":"b"}]}]},"streamSettings":{"security":"tls","tlsSettings":{"serverName":"r.example.com","allowInsecure":false}}}'
outbound_unlock_add_raw "raw-unlock" "$raw" geosite:openai domain:claude.ai \
    || fail "粘贴 JSON 添加失败"
assert_json "$outbound"; assert_json "$route"

python3 - "$outbound" "$route" <<'PY' || fail "粘贴 JSON 的写入结果不对"
import json, sys
outbounds = json.load(open(sys.argv[1]))
rules = json.load(open(sys.argv[2]))["rules"]
tags = [o.get("tag") for o in outbounds]
assert tags == ["IPv4_out", "IPv6_out", "socks5-unlock", "raw-unlock", "block"], tags

ob = next(o for o in outbounds if o["tag"] == "raw-unlock")
# 原样写入，不做重建：streamSettings 等字段要一字不差地保留
assert ob["streamSettings"]["tlsSettings"]["allowInsecure"] is False
assert ob["settings"]["servers"][0]["port"] == 8080

rule = next(r for r in rules if r.get("ruleTag") == "custom-unlock-raw-unlock")
assert rule["outboundTag"] == "raw-unlock"
assert rule["domain"] == ["geosite:openai", "domain:claude.ai"]
PY

# JSON 里没有 tag 时，用传进来的标签补上
reset_files
outbound_unlock_add_raw "no-tag" '{"protocol":"socks","settings":{"servers":[{"address":"n.example.com","port":1080}]}}' geosite:x     || fail "无 tag 的 JSON 应能添加"
python3 - "$outbound" <<'PY' || fail "未补上 tag"
import json, sys
ob = next(o for o in json.load(open(sys.argv[1])) if o.get("tag") == "no-tag")
assert ob["protocol"] == "socks"
PY

# JSON 里的 tag 与传进来的不一致：以 JSON 里的为准会让菜单和文件对不上，必须拒绝
reset_files
if outbound_unlock_add_raw "mine" '{"tag":"theirs","protocol":"http","settings":{"servers":[{"address":"a.com","port":1}]}}' geosite:x 2>/dev/null; then
    fail "JSON 里的 tag 与指定标签不一致时必须拒绝"
fi

# 各种坏 JSON
reset_files
before_ob="$(cat "$outbound")"
for bad in \
    'not json' \
    '[]' \
    '"just a string"' \
    '{"tag":"x"}' \
    '{"protocol":"","settings":{}}' \
    '{"protocol":"http"}' \
    '{"protocol":"http","settings":{"servers":[]}}' \
    '{"protocol":"http","settings":{"servers":[{"port":80}]}}' \
    '{"protocol":"http","settings":{"servers":[{"address":"a.com"}]}}'
do
    if outbound_unlock_add_raw "bad-$RANDOM" "$bad" geosite:x 2>/dev/null; then
        fail "坏 JSON 应被拒绝：${bad}"
    fi
done
[[ "$(cat "$outbound")" == "$before_ob" ]] || fail "坏 JSON 不该改动文件"

# 保留标签与重名同样适用
reset_files
if outbound_unlock_add_raw "block" '{"protocol":"http","settings":{"servers":[{"address":"a.com","port":1}]}}' geosite:x 2>/dev/null; then
    fail "保留标签必须被拒绝"
fi
outbound_unlock_add_raw "dup" '{"protocol":"http","settings":{"servers":[{"address":"a.com","port":1}]}}' geosite:x     || fail "准备用例失败"
if outbound_unlock_add_raw "dup" '{"protocol":"http","settings":{"servers":[{"address":"a.com","port":1}]}}' geosite:x 2>/dev/null; then
    fail "重名标签必须被拒绝"
fi

# 域名条目照样要校验
reset_files
if outbound_unlock_add_raw "d" '{"protocol":"http","settings":{"servers":[{"address":"a.com","port":1}]}}' "bad entry" 2>/dev/null; then
    fail "非法域名条目必须被拒绝"
fi
if outbound_unlock_add_raw "d" '{"protocol":"http","settings":{"servers":[{"address":"a.com","port":1}]}}' 2>/dev/null; then
    fail "没有域名条目必须被拒绝"
fi

# --- 12b. 多行 JSON 读取：提示语不能混进返回值 ------------------------------
# 这个函数是在 $( ) 里被调用的，提示语要是打到 stdout 就会被一起捕获、混进 JSON。
declare -F outbound_unlock_read_json_block >/dev/null \
    || fail "outbound_unlock.sh 未定义 outbound_unlock_read_json_block"
got="$(printf '{\n  "protocol": "http"\n}\n\n' | outbound_unlock_read_json_block 2>/dev/null)"
[[ "$got" == '{
  "protocol": "http"
}' ]] || fail "读到的 JSON 不干净：[${got}]"
python3 -c "import json,sys; json.loads(sys.argv[1])" "$got" \
    || fail "读到的内容不是合法 JSON"

# --- 13. 接线 ---------------------------------------------------------------
python3 - "$repo_dir" <<'WIRING' || fail "N2X.sh / install.sh 未正确接入 outbound_unlock.sh"
from pathlib import Path
import sys
repo = Path(sys.argv[1])
n2x = (repo / "N2X.sh").read_text()
install = (repo / "install.sh").read_text()

assert 'source "$SCRIPT_DIR/outbound_unlock.sh"' in n2x, "N2X.sh 未 source outbound_unlock.sh"
assert "source /usr/local/N2X/outbound_unlock.sh" in n2x, "缺少已安装路径的兜底 source"
assert "21.${plain} 出口解锁设置" in n2x, "主菜单没有出口解锁入口"
assert "21) outbound_unlock_menu ;;" in n2x, "主菜单 21 未接到 outbound_unlock_menu"
assert "22) exit ;;" in n2x, "退出项应顺延到 22"
assert "[0-22]" in n2x and "[0-21]" not in n2x, "菜单编号范围未同步更新"
assert "outbound_unlock_command" in n2x, "缺少 N2X unlock 子命令"
import re
modules = re.search(r"for module in ([^;]+); do", n2x)
assert modules, "update_shell 里找不到模块列表"
assert "outbound_unlock.sh" in modules.group(1).split(), \
    "update_shell 未一并更新 outbound_unlock.sh"
assert "/usr/local/N2X/outbound_unlock.sh" in install, "install.sh 未安装 outbound_unlock.sh"
assert "chmod +x /usr/local/N2X/outbound_unlock.sh" in install, "install.sh 未给模块加执行位"
WIRING

echo "出口解锁设置行为正确"
