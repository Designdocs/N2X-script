#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
source "$repo_dir/config_gen.sh"
red="" green="" yellow="" plain=""
api_host_val='${N2X_API_HOST}'
api_key_val='${N2X_API_KEY}'
custom_dns_enabled=false
check_ipv6_support() { echo 0; }

# Capture prompts even with redirected stdin (bash otherwise hides read -p).
read() {
    if [[ "${1:-}" == "-rp" ]]; then
        printf '%s\n' "$2" >> "$work_dir/prompts"
    fi
    builtin read "$@"
}

run_case() {
    local label="$1" dialogue="$2" enabled="$3" provider="$4" prompts="$5" input leftover
    nodes_config=()
    core_xray=false
    core_sing=false
    : > "$work_dir/prompts"
    input="$(printf '%s\n' "$dialogue" | tr ';' '\n')"
    {
        add_node_config > "$work_dir/output"
        builtin read -r leftover
    } <<< "$input"
    [[ "$leftover" == END ]] || { echo "FAIL $label: wrong prompt order consumed the next answer" >&2; exit 1; }
    printf '%s' "${nodes_config[0]%,}" > "$work_dir/node.json"
    python3 - "$work_dir" "$label" "$enabled" "$provider" "$prompts" <<'PY'
import json, sys
from pathlib import Path
work, label, enabled, provider, expected_prompts = sys.argv[1:]
work = Path(work)
node = json.loads((work / "node.json").read_text())
ddns = node["DDNSConfig"]
assert ddns["Enabled"] == (enabled == "true"), label
assert ddns["Provider"] == provider, label
assert ddns["RecordType"] == "A" and ddns["Interval"] == 300, label
prompts = (work / "prompts").read_text()
assert prompts.count("是否开启 DDNS") == int(expected_prompts), label
if int(expected_prompts):
    assert prompts.index("是否开启 DDNS") > prompts.rfind("请输入："), label
    assert prompts.index("是否开启 DDNS") > prompts.index("请输入证书域名"), label
if enabled == "true" and provider == "alidns":
    assert set(ddns["DNSEnv"]) == {"ALICLOUD_ACCESS_KEY", "ALICLOUD_SECRET_KEY"}, label
elif enabled == "true":
    assert ddns["DNSEnv"] == {}, "Cloudflare should reuse matching certificate credentials"
PY
}

run_case default_off '100;8;edge.example.com;1;;END' false cloudflare 1
run_case explicit_no '100;8;edge.example.com;2;n;END' false cloudflare 1
run_case cloudflare '100;8;edge.example.com;2;y;1;END' true cloudflare 1
run_case alibaba_international '100;8;edge.example.com;2;yes;2;END' true alidns 1
run_case self_certificate '100;8;edge.example.com;3;n;END' false cloudflare 1
# These cases follow enabled cases to detect an enable-state leak across nodes.
run_case no_certificate '100;1;n;END' false cloudflare 0
run_case reality '100;2;y;END' false cloudflare 0
run_case shadowtls '100;10;;END' false cloudflare 0

echo "DDNS wizard defaults, provider choices, prompt order and certificate skips passed"
