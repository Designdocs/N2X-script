#!/usr/bin/env bash
# install.sh 的 xray 配套文件写入。
#
# 这里守的是一个真出过的 bug：全新安装原本用 `cp route.json /etc/N2X/` 从解压出
# 来的发行包里拷，拷不到也没有任何检查，装完 /etc/N2X 里就少了 route.json 和
# custom_outbound.json，而 config.json 的 Cores.Paths 指着它们——xray 读不到会直
# 接 panic。
#
# install.sh 整个文件不能 source（末尾会真的执行 install_N2X），所以这里把函数
# 正文抠出来 eval。
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# install.sh 里的日志函数用了颜色变量，这里给个不带颜色的替身，顺带把错误信息
# 收集起来供断言。
log_error() { printf '%s\n' "$*" >> "$work_dir/errors.log"; }
: > "$work_dir/errors.log"

function_body="$(awk '/^install_xray_side_files\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
if [[ -z "$function_body" ]]; then
    fail "没能从 install.sh 里取出 install_xray_side_files（函数被改名或格式变了？）"
fi
eval "$function_body"

cfg_dir="$work_dir/etc/N2X"
mkdir -p "$cfg_dir"

# --- 1. 全新安装：三份配套文件都要落盘，且是合法 JSON ----------------------
if ! install_xray_side_files "$cfg_dir" "$repo_dir/config_gen.sh"; then
    fail "全新安装路径写入配套文件失败：$(cat "$work_dir/errors.log")"
fi

for side_file in dns.json custom_outbound.json route.json; do
    if [[ ! -f "${cfg_dir}/${side_file}" ]]; then
        fail "缺少 ${side_file}（xray 读不到会直接 panic）"
    fi
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${cfg_dir}/${side_file}"; then
        fail "${side_file} 不是合法 JSON"
    fi
done

# Cores.Paths 指向的三个路径必须和这里写出的文件名一一对应，改了任一边都要一起改。
python3 - "$repo_dir/config_gen.sh" <<'PY'
import re, sys

config_gen = open(sys.argv[1]).read()
paths = dict(re.findall(r'\\"(\w+ConfigPath)\\": \\"([^\\]+)\\"', config_gen))
expected = {
    "DnsConfigPath": "/etc/N2X/dns.json",
    "OutboundConfigPath": "/etc/N2X/custom_outbound.json",
    "RouteConfigPath": "/etc/N2X/route.json",
}
assert paths == expected, f"Cores.Paths 和配套文件对不上：{paths}"
PY

# --- 2. 升级：已有文件不能被默认内容覆盖 -----------------------------------
printf '%s\n' '{"servers": ["9.9.9.9"], "tag": "dns_inbound"}' > "${cfg_dir}/dns.json"
if ! install_xray_side_files "$cfg_dir" "$repo_dir/config_gen.sh"; then
    fail "配套文件已存在时不该失败：$(cat "$work_dir/errors.log")"
fi
if ! grep -q '9.9.9.9' "${cfg_dir}/dns.json"; then
    fail "已有的 dns.json 被默认内容覆盖了"
fi

# --- 3. config_gen.sh 缺失：报错，不能静默 ---------------------------------
: > "$work_dir/errors.log"
if install_xray_side_files "$work_dir/etc/N2X-missing" "$work_dir/nope/config_gen.sh"; then
    fail "config_gen.sh 不存在时必须返回非零"
fi
if ! grep -q '未找到' "$work_dir/errors.log"; then
    fail "config_gen.sh 不存在时必须报错，实际输出：$(cat "$work_dir/errors.log")"
fi

# --- 4. config_gen.sh 过旧（没有 write_default_*_json）：报错 --------------
: > "$work_dir/errors.log"
old_config_gen="$work_dir/old_config_gen.sh"
printf '%s\n' '#!/bin/bash' 'N2X_CONFIG_GEN_VERSION=3' > "$old_config_gen"
# 上面的用例已经把真的 config_gen.sh source 进当前 shell 了，函数还在。装机时是
# 全新进程，不会有这种残留，所以在子 shell 里先卸掉再验版本检查。
if (
    unset -f write_default_dns_json write_default_custom_outbound_json write_default_route_json
    install_xray_side_files "$cfg_dir" "$old_config_gen"
); then
    fail "config_gen.sh 过旧时必须返回非零"
fi
if ! grep -q '版本过旧' "$work_dir/errors.log"; then
    fail "config_gen.sh 过旧时必须报错，实际输出：$(cat "$work_dir/errors.log")"
fi

# --- 5. 写入失败（目录不存在）：报错，不能静默 -----------------------------
: > "$work_dir/errors.log"
if install_xray_side_files "$work_dir/no/such/dir" "$repo_dir/config_gen.sh" 2>/dev/null; then
    fail "写入失败时必须返回非零"
fi
if ! grep -q '失败' "$work_dir/errors.log"; then
    fail "写入失败时必须报错，实际输出：$(cat "$work_dir/errors.log")"
fi

# --- 6. install.sh 不该再从发行包 cp 这些文件 ------------------------------
if grep -nE '^\s*cp (dns|route|custom_outbound|custom_inbound)\.json ' "$repo_dir/install.sh"; then
    fail "install.sh 又在 cp 配套文件了；默认内容只该来自 config_gen.sh"
fi

# custom_inbound.json 全仓库无人引用（Cores.Paths 里也没有对应项），不该复活。
if grep -rn --exclude-dir=.git --exclude-dir=.claude --exclude-dir=tests \
    'custom_inbound' "$repo_dir"; then
    fail "custom_inbound.json 没有任何消费方，不该再出现"
fi

echo "install_side_files_test: OK"
