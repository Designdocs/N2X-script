#!/usr/bin/env bash
# 端到端跑一遍 config_append.sh：在已有配置上追加协议必须只做加法——原有节点、
# 原有核心的自定义参数、Log 与 _help 都要原样保留，缺哪个核心才补哪个，新增
# xray 核心时要补齐 xray 会直接 panic 的那几个配套文件。
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# check_ipv6_support 会调 `ip`，macOS 和精简容器里没有，跟协议矩阵测试一样打桩。
stub_dir="$(mktemp -d)"
work_root="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$work_root"' EXIT
cat >"${stub_dir}/ip" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "${stub_dir}/ip"
PATH="${stub_dir}:${PATH}"

# shellcheck source=../config_gen.sh
source "${repo_dir}/config_gen.sh"
# shellcheck source=../config_append.sh
source "${repo_dir}/config_append.sh"

red="" green="" yellow="" plain=""

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# 一个已经配好的 xray 配置：核心参数被改过（bufferSize=999），节点填了真实的
# 证书信息。追加协议之后这些都必须原封不动。
xray_config='{
    "Log": {
        "Level": "warn",
        "Output": "/var/log/n2x.log"
    },
    "Cores": [
        {
            "Type": "xray",
            "Log": {
                "Level": "error",
                "ErrorPath": "/etc/N2X/error.log"
            },
            "ConnectionConfig": {
                "bufferSize": 999
            },
            "DnsConfigPath": "/etc/N2X/dns.json",
            "OutboundConfigPath": "/etc/N2X/custom_outbound.json",
            "RouteConfigPath": "/etc/N2X/route.json",
            "EnableBTExtraSniffing": true
        }
    ],
    "Nodes": [
        {
            "Core": "xray",
            "ApiHost": "https://panel.example.com",
            "ApiKey": "secretkey123",
            "NodeID": 11,
            "NodeType": "vless",
            "EnableDNS": true,
            "DNSType": "UseIP",
            "CertConfig": {
                "CertMode": "dns",
                "CertDomain": "n1.example.com",
                "CertFile": "/etc/N2X/fullchain-n1.cer",
                "KeyFile": "/etc/N2X/cert-n1.key",
                "Email": "ops@example.com",
                "Provider": "alidns",
                "DNSEnv": {
                    "ALICLOUD_ACCESS_KEY": "real-key"
                }
            }
        }
    ],
    "_help": {
        "Log": "保留我"
    }
}'

sing_config='{
    "Log": {
        "Level": "error",
        "Output": ""
    },
    "Cores": [
        {
            "Type": "sing",
            "Log": {
                "Disable": false,
                "Level": "error",
                "Output": "",
                "Timestamp": true
            },
            "NTP": {
                "Enable": true,
                "Server": "time.apple.com",
                "ServerPort": 0
            },
            "OriginalPath": ""
        }
    ],
    "Nodes": [
        {
            "Core": "sing",
            "ApiHost": "${N2X_API_HOST}",
            "ApiKey": "${N2X_API_KEY}",
            "NodeID": 21,
            "NodeType": "hysteria",
            "CertConfig": {
                "CertMode": "http",
                "CertDomain": "hy.example.com"
            }
        }
    ]
}'

# 起一个干净的配置目录，返回值放在 N2X_CONFIG_DIR（config_append.sh 读它）。
new_case() {
    N2X_CONFIG_DIR="$(mktemp -d "${work_root}/case.XXXXXX")"
    printf '%s\n' "$1" > "${N2X_CONFIG_DIR}/config.json"
}

# 用 ';' 分隔的对话喂给 append_node_configs，空串代表直接回车。
#
# 对话对不上时 add_node_config 的 NodeID 循环会在 EOF 上空转，所以放到子 shell
# 里跑并加看门狗——测试要报错，不能挂住。产出都落在磁盘上，子 shell 不影响断言。
run_append() {
    local dialogue="$1" input_file pid waited=0 rc
    input_file="$(mktemp "${work_root}/input.XXXXXX")"
    printf '%s\n' "$dialogue" | tr ';' '\n' > "$input_file"

    set +e
    ( append_node_configs >/dev/null 2>&1 <"$input_file" ) &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= 200 )); then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            set -e
            fail "对话 '${dialogue}' 卡住了（20 秒没结束），提示顺序对不上"
            return 99
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    wait "$pid"
    rc=$?
    set -e
    return "$rc"
}

assert_config() {
    local label="$1" script="$2"
    if ! python3 -c "$script" "${N2X_CONFIG_DIR}/config.json" 2>&1; then
        fail "$label"
    fi
}

# --- 1. xray 配置上追加一个 sing 协议 --------------------------------------
new_case "$xray_config"
# 沿用 ApiHost/ApiKey；NodeID 4242；协议 8=hysteria；证书 1=http；不再继续添加
if ! run_append ";4242;8;1;n"; then
    fail "在 xray 配置上追加 sing 节点失败"
fi

assert_config "追加 sing 节点后的配置不符合预期" '
import json, sys
d = json.load(open(sys.argv[1]))

assert [c["Type"] for c in d["Cores"]] == ["xray", "sing"], d["Cores"]
xray = d["Cores"][0]
assert xray["ConnectionConfig"]["bufferSize"] == 999, "已有核心的自定义参数被改写了"
assert xray["DnsConfigPath"] == "/etc/N2X/dns.json"

assert d["Log"] == {"Level": "warn", "Output": "/var/log/n2x.log"}, "Log 被改写了"
assert d["_help"] == {"Log": "保留我"}, "_help 被改写了"

assert [n["NodeID"] for n in d["Nodes"]] == [11, 4242], d["Nodes"]
old, new = d["Nodes"]
assert old["NodeType"] == "vless" and old["CertConfig"]["CertDomain"] == "n1.example.com"
assert new["NodeType"] == "hysteria" and new["Core"] == "sing"
assert new["ApiHost"] == "https://panel.example.com" and new["ApiKey"] == "secretkey123"
assert new["EnableSniff"] is True and "DNSType" not in new

cert = new["CertConfig"]
assert cert["CertMode"] == "http"
assert cert["CertDomain"] == "n1.example.com", "证书域名没有从现有节点继承：%r" % cert
assert cert["Email"] == "ops@example.com", cert
assert cert["Provider"] == "alidns", cert
assert cert["DNSEnv"] == {"ALICLOUD_ACCESS_KEY": "real-key"}, cert
'

if [[ ! -f "${N2X_CONFIG_DIR}/config.json.bak" ]]; then
    fail "没有备份 config.json.bak"
elif ! diff -q <(printf '%s\n' "$xray_config") "${N2X_CONFIG_DIR}/config.json.bak" >/dev/null; then
    fail "config.json.bak 不是原始配置"
fi

# --- 2. 重复节点不写入 ------------------------------------------------------
before="$(cat "${N2X_CONFIG_DIR}/config.json")"
if run_append ";4242;8;1;n"; then
    fail "重复节点应当被拒绝并返回非 0"
fi
if [[ "$before" != "$(cat "${N2X_CONFIG_DIR}/config.json")" ]]; then
    fail "重复节点被拒绝后配置不应有任何改动"
fi

# 同 NodeID 但换个协议是合法的（面板里 ID 按协议各排各的）
if ! run_append ";4242;9;1;n"; then
    fail "同 NodeID 不同协议应当允许追加"
fi
assert_config "同 NodeID 不同协议追加后不符合预期" '
import json, sys
d = json.load(open(sys.argv[1]))
assert [(n["NodeID"], n["NodeType"]) for n in d["Nodes"]] == [
    (11, "vless"), (4242, "hysteria"), (4242, "tuic")], d["Nodes"]
assert [c["Type"] for c in d["Cores"]] == ["xray", "sing"], "核心不该重复追加"
'

# --- 3. sing 配置上追加 xray 协议，并补齐配套文件 ---------------------------
new_case "$sing_config"
# 现有节点用的是 ${N2X_API_HOST} 占位符，不会问是否沿用；先问自定义 DNS(y)，
# 再 NodeID 7；协议 2=vless；不是 reality(n)；不配 TLS(n)；不再继续(n)
if ! run_append "y;7;2;n;n;n"; then
    fail "在 sing 配置上追加 xray 节点失败"
fi

assert_config "追加 xray 节点后的配置不符合预期" '
import json, sys
d = json.load(open(sys.argv[1]))
assert [c["Type"] for c in d["Cores"]] == ["sing", "xray"], d["Cores"]
assert d["Cores"][0]["NTP"]["Enable"] is True, "已有 sing 核心的参数被改写了"
new = d["Nodes"][1]
assert new["NodeID"] == 7 and new["NodeType"] == "vless" and new["Core"] == "xray"
assert new["ApiHost"] == "${N2X_API_HOST}", "占位符没有沿用：%r" % new["ApiHost"]
assert new["EnableDNS"] is True and new["DNSType"] == "UseIP", new
assert new["CertConfig"]["CertMode"] == "none"
assert new["CertConfig"]["CertDomain"] == "all.example.com", "CertMode=none 不该继承证书"
'

for side_file in dns.json custom_outbound.json route.json; do
    if [[ ! -f "${N2X_CONFIG_DIR}/${side_file}" ]]; then
        fail "新增 xray 核心后缺少 ${side_file}（xray 读不到会直接 panic）"
    elif ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${N2X_CONFIG_DIR}/${side_file}"; then
        fail "${side_file} 不是合法 JSON"
    fi
done

# 已存在的配套文件不能被覆盖（此时两个核心都在了，不会再问自定义 DNS）
printf '%s\n' '{"servers": ["9.9.9.9"], "tag": "dns_inbound"}' > "${N2X_CONFIG_DIR}/dns.json"
if ! run_append "8;3;n;n"; then
    fail "追加第二个节点失败"
fi
if ! grep -q '9.9.9.9' "${N2X_CONFIG_DIR}/dns.json"; then
    fail "已有的 dns.json 被默认内容覆盖了"
fi

# --- 4. 带注释的配置（N2X 能读，标准 JSON 不能）----------------------------
# 注释、块注释、尾逗号，外加字符串里就带 // 和逗号的值——清理器不能把它们当注释。
new_case '{
    // 这是我的配置, 里面有逗号
    "Log": {"Level": "error", "Output": ""},   /* 块注释
       跨行 */
    "Cores": [
        {"Type": "sing", "OriginalPath": ""},
    ],
    "Nodes": [
        {"Core": "sing", "ApiHost": "https://p.example.com/api//x", "ApiKey": "a,b//c", "NodeID": 5, "NodeType": "tuic"},
    ],
}'
before="$(cat "${N2X_CONFIG_DIR}/config.json")"

# 不同意丢注释就什么都不做
if run_append "n"; then
    fail "拒绝「注释会丢失」的确认后应当返回非 0"
fi
if [[ "$before" != "$(cat "${N2X_CONFIG_DIR}/config.json")" ]]; then
    fail "拒绝确认后不应改动配置"
fi

# 同意之后正常合并：y=确认丢注释；回车沿用 API；n=不开自定义 DNS；
# NodeID 9；协议 9=tuic；证书 1=http；n=结束
if ! run_append "y;;n;9;9;1;n"; then
    fail "带注释的配置应当在确认后可以追加"
fi
assert_config "带注释的配置合并后不符合预期" '
import json, sys
d = json.load(open(sys.argv[1]))
assert [n["NodeID"] for n in d["Nodes"]] == [5, 9], d["Nodes"]
assert [c["Type"] for c in d["Cores"]] == ["sing"], d["Cores"]
old, new = d["Nodes"]
assert old["ApiHost"] == "https://p.example.com/api//x", "字符串里的 // 被当成注释删了：%r" % old
assert old["ApiKey"] == "a,b//c", old
assert new["ApiHost"] == old["ApiHost"] and new["ApiKey"] == old["ApiKey"], new
'

# --- 5. 缺少配置文件时明确失败 ---------------------------------------------
N2X_CONFIG_DIR="$(mktemp -d "${work_root}/case.XXXXXX")"
if run_append ";1;1;1;n"; then
    fail "没有 config.json 时应当直接失败并提示先生成配置"
fi

# --- 6. 语法坏掉的配置绝不能被覆盖 -----------------------------------------
new_case '{"Nodes": [ this is not json'
before="$(cat "${N2X_CONFIG_DIR}/config.json")"
if run_append ";1;1;1;n"; then
    fail "配置解析失败时应当返回非 0"
fi
if [[ "$before" != "$(cat "${N2X_CONFIG_DIR}/config.json")" ]]; then
    fail "配置解析失败时不应改动原文件"
fi
if [[ -f "${N2X_CONFIG_DIR}/config.json.bak" ]]; then
    fail "配置解析失败时不应产生备份"
fi

if (( failures > 0 )); then
    echo "${failures} append-protocol check(s) failed" >&2
    exit 1
fi

echo "append protocol flow is aligned (merge keeps existing nodes, cores and side files)"
