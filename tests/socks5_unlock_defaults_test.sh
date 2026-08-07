#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# config_gen.sh 是 dns.json / custom_outbound.json / route.json 默认内容的唯一
# 实现；initconfig.sh、N2X.sh、config_append.sh 都调用它的 write_default_*_json。
# 这里直接 source 出来跑，断言的是实际写出的文件，而不是源码里的 heredoc 文本。
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# shellcheck source=/dev/null
source "${repo_dir}/config_gen.sh"

for fn in write_default_dns_json write_default_custom_outbound_json write_default_route_json; do
    if ! declare -F "$fn" >/dev/null; then
        echo "config_gen.sh does not define ${fn}" >&2
        exit 1
    fi
done

write_default_dns_json "${work_dir}/dns.json"
write_default_custom_outbound_json "${work_dir}/custom_outbound.json"
write_default_route_json "${work_dir}/route.json"

python3 - "$repo_dir" "$work_dir" <<'PY'
from pathlib import Path
import json
import sys

repo = Path(sys.argv[1])
work = Path(sys.argv[2])


def generated_json(name):
    return json.loads((work / name).read_text())


outbounds = generated_json("custom_outbound.json")
unlock = [outbound for outbound in outbounds if outbound.get("tag") == "socks5-unlock"]
assert len(unlock) == 1
server = unlock[0]["settings"]["servers"]
assert unlock[0]["protocol"] == "socks" and len(server) == 1
assert server[0] == {
    "address": "socks5.example.invalid",
    "port": 1080,
    "users": [{"user": "USERNAME", "pass": "PASSWORD"}],
}

# 出站里必须同时有 block 和 IPv4_out，route.json 的规则才有对应的落点。
tags = {outbound.get("tag") for outbound in outbounds}
assert {"IPv4_out", "IPv6_out", "socks5-unlock", "block"} <= tags, tags

route = generated_json("route.json")
rules = route["rules"]

unlock_rules = [rule for rule in rules if rule.get("outboundTag") == "socks5-unlock"]
assert len(unlock_rules) == 1
assert unlock_rules[0]["domain"] == ["domain:socks5-unlock.invalid"]

# 兜底规则必须存在且排在 socks5-unlock 之后，否则解锁规则永远匹配不到。
fallback = next(i for i, rule in enumerate(rules) if rule.get("outboundTag") == "IPv4_out")
assert rules.index(unlock_rules[0]) < fallback
assert fallback == len(rules) - 1, "IPv4_out 兜底规则必须是最后一条"
assert rules[fallback]["network"] == "udp,tcp"

# 合并后的唯一默认：initconfig.sh 的完整规则集（含 21 条域名黑名单），
# 并给每条规则补上 xray 唯一认识的 "type": "field"。
assert all(rule.get("type") == "field" for rule in rules), "每条规则都要带 type=field"
blocklist = [
    rule for rule in rules if rule.get("outboundTag") == "block" and rule.get("domain")
]
assert len(blocklist) == 1 and len(blocklist[0]["domain"]) == 21, "域名黑名单不完整"
assert any(
    rule.get("outboundTag") == "block" and rule.get("protocol") == ["bittorrent"]
    for rule in rules
)
assert any(
    rule.get("outboundTag") == "block" and "127.0.0.1/32" in (rule.get("ip") or [])
    for rule in rules
)
assert any(
    rule.get("outboundTag") == "block" and rule.get("ip") == ["geoip:private"]
    for rule in rules
)

assert generated_json("dns.json")["tag"] == "dns_inbound"

# 调用方不得再长回自己的那份 heredoc。
for caller in ("initconfig.sh", "N2X.sh", "config_append.sh"):
    text = (repo / caller).read_text()
    for path in ("custom_outbound.json", "route.json", "dns.json"):
        assert f"> /etc/N2X/{path}" not in text, f"{caller} still writes {path} inline"
    assert "socks5.example.invalid" not in text, f"{caller} carries a duplicate outbound block"
    assert "geoip:private" not in text, f"{caller} carries a duplicate route block"

for caller in ("initconfig.sh", "N2X.sh"):
    text = (repo / caller).read_text()
    assert (
        "SOCKS5 解锁，可编辑 /etc/N2X/dns.json、/etc/N2X/custom_outbound.json 与 /etc/N2X/route.json"
        in text
    ), caller
PY

echo "SOCKS5 unlock defaults are aligned"
