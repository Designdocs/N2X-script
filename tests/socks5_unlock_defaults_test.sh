#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_dir" <<'PY'
from pathlib import Path
import json
import sys

repo = Path(sys.argv[1])
for name in ("initconfig.sh", "N2X.sh"):
    text = (repo / name).read_text()

    def generated_json(path):
        marker = f"cat <<EOF > /etc/N2X/{path}\n"
        start = text.index(marker) + len(marker)
        return json.loads(text[start:text.index("\nEOF", start)])

    outbounds = generated_json("custom_outbound.json")
    unlock = [outbound for outbound in outbounds if outbound.get("tag") == "socks5-unlock"]
    assert len(unlock) == 1, name
    server = unlock[0]["settings"]["servers"]
    assert unlock[0]["protocol"] == "socks" and len(server) == 1, name
    assert server[0] == {
        "address": "socks5.example.invalid",
        "port": 1080,
        "users": [{"user": "USERNAME", "pass": "PASSWORD"}],
    }, name

    rules = generated_json("route.json")["rules"]
    unlock_rules = [rule for rule in rules if rule.get("outboundTag") == "socks5-unlock"]
    assert len(unlock_rules) == 1, name
    assert unlock_rules[0]["domain"] == ["domain:socks5-unlock.invalid"], name
    fallback = next((i for i, rule in enumerate(rules) if rule.get("outboundTag") == "IPv4_out"), None)
    assert fallback is None or rules.index(unlock_rules[0]) < fallback, name
    assert "SOCKS5 解锁，可编辑 /etc/N2X/dns.json、/etc/N2X/custom_outbound.json 与 /etc/N2X/route.json" in text, name
PY

echo "SOCKS5 unlock defaults are aligned"
