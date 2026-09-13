#!/usr/bin/env bash
# N2X check 要接到管理脚本上：命令行 `N2X check`、主菜单一项、使用说明一行。
# 脚本本身只转调二进制的 check 子命令，把结果和退出码原样交给用户，旧版二进制
# 没有 check 子命令时提示先更新 N2X。
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manager="${repo_dir}/N2X.sh"

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# --- 接线：子命令、菜单、使用说明 -------------------------------------------
python3 - "$manager" <<'WIRING' || fail "N2X.sh 未正确接入 N2X check"
from pathlib import Path
import sys

n2x = Path(sys.argv[1]).read_text()
dispatch = n2x[n2x.rindex('if [[ $# > 0 ]]; then'):]
assert '"check") check_install 0 && check_config_file 0 ;;' in dispatch, "缺少 N2X check 子命令"

menu = n2x[n2x.index("\nshow_menu() {"):n2x.rindex('if [[ $# > 0 ]]; then')]
assert "22.${plain} 检查配置文件" in menu, "主菜单没有检查配置文件入口"
assert "22) check_install && check_config_file ;;" in menu, "主菜单 22 未接到 check_config_file"
assert "23.${plain} 退出脚本" in menu and "23) exit ;;" in menu, "退出项应顺延到 23"
assert "[0-23]" in menu and "[0-22]" not in menu, "菜单编号范围未同步更新"

assert "N2X check" in n2x[n2x.index("\nshow_usage() {"):n2x.index("\nshow_menu() {")], "使用说明缺少 N2X check"
WIRING

# --- 行为：把函数单独拿出来，用假的二进制跑 ----------------------------------
function_file="${work_root}/check_config_file.sh"
python3 - "$manager" "$function_file" <<'EXTRACT'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
match = re.search(r"^check_config_file\(\) \{\n.*?^\}\n", text, re.S | re.M)
assert match, "N2X.sh 中没有 check_config_file 函数"
Path(sys.argv[2]).write_text(match.group(0))
EXTRACT

red="" green="" yellow="" plain=""
menu_returns=0
before_show_menu() { menu_returns=$((menu_returns + 1)); }
# shellcheck source=/dev/null
source "$function_file"

fake_binary() {
    local exit_code="$1" output="$2"
    N2X_BIN="${work_root}/N2X"
    printf '%s\n' "$output" >"${work_root}/output"
    cat >"$N2X_BIN" <<STUB
#!/bin/sh
echo "\$*" >"${work_root}/args"
cat "${work_root}/output"
exit ${exit_code}
STUB
    chmod +x "$N2X_BIN"
    export N2X_BIN
}

# 配置正确：透传二进制输出，返回 0，参数带上配置路径。
fake_binary 0 "OK: /etc/N2X/config.json is valid"
if ! out="$(check_config_file 0 2>&1)"; then
    fail "配置正确时 check_config_file 返回了非 0"
fi
[[ "$out" == *"OK: /etc/N2X/config.json is valid"* ]] || fail "没有显示二进制的检查结果: $out"
[[ "$(cat "${work_root}/args")" == "check -c /etc/N2X/config.json" ]] \
    || fail "调用参数不对: $(cat "${work_root}/args")"

# 配置有错：返回非 0，错误原样显示。
fake_binary 1 "Nodes[0].NodeTyp: unknown key"
if out="$(check_config_file 0 2>&1)"; then
    fail "配置有错时 check_config_file 返回了 0"
fi
[[ "$out" == *"Nodes[0].NodeTyp: unknown key"* ]] || fail "没有显示配置错误: $out"

# 旧版二进制没有 check 子命令：提示更新。
fake_binary 1 'Error: unknown command "check" for "N2X"'
if out="$(check_config_file 0 2>&1)"; then
    fail "旧版二进制时 check_config_file 返回了 0"
fi
[[ "$out" == *"N2X update"* ]] || fail "旧版二进制时没有提示更新 N2X: $out"

# 二进制本身跑不起来（缺失、无执行权限）不是配置问题，不能报成"检查未通过"。
N2X_BIN="${work_root}/missing-N2X"
export N2X_BIN
if out="$(check_config_file 0 2>&1)"; then
    fail "二进制不存在时 check_config_file 返回了 0"
fi
[[ "$out" == *"无法运行"* && "$out" != *"检查未通过"* ]] || fail "二进制无法运行时提示不对: $out"

# 从菜单进入（不带参数）时回到主菜单；命令行模式不回。
fake_binary 0 "OK"
menu_returns=0
check_config_file 0 >/dev/null 2>&1 || true
[[ "$menu_returns" == 0 ]] || fail "命令行模式不应回到主菜单"
check_config_file >/dev/null 2>&1 || true
[[ "$menu_returns" == 1 ]] || fail "菜单模式检查完应回到主菜单"

if ((failures > 0)); then
    exit 1
fi
echo "N2X check is wired into the manager script"
