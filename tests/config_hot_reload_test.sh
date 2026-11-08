#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

export N2X_CONFIG_DIR="$work_dir/etc"
export N2X_RUNTIME_CONFIG="$work_dir/run/config.json"
export N2X_BIN="$work_dir/N2X"
export check_log="$work_dir/checks"
mkdir -p "$N2X_CONFIG_DIR" "$(dirname "$N2X_RUNTIME_CONFIG")"

sed -n '/^config_apply_saved() (/,/^uninstall() {/p' "$SCRIPT_DIR/N2X.sh" | sed '$d' > "$work_dir/config-functions.sh"
source "$work_dir/config-functions.sh"

red='' green='' yellow='' plain=''
release=debian
service_status=0
menu_returns=0
ensure_vim_editor() { :; }
vim() { cp "$work_dir/edited.json" "$1"; }
check_status() { return "$service_status"; }
before_show_menu() { menu_returns=$((menu_returns + 1)); }
restart() { touch "$work_dir/restarted"; }

cat > "$N2X_BIN" <<'STUB'
#!/bin/sh
[ "$1" = check ] && [ "$2" = -c ] || exit 1
printf '%s\n' "$3" >> "$check_log"
python3 -m json.tool "$3" >/dev/null
STUB
chmod +x "$N2X_BIN"

printf '%s\n' 'N2X_API_KEY=local-token' > "$N2X_CONFIG_DIR/.env"
printf '%s\n' '{"ApiKey":"previous"}' > "$N2X_RUNTIME_CONFIG"
printf '%s\n' '{"ApiKey":"${N2X_API_KEY}"}' > "$work_dir/edited.json"
config > "$work_dir/output"
[[ "$menu_returns" == 1 ]]
grep -q '等待 N2X 热重载' "$work_dir/output"
grep -q 'local-token' "$N2X_RUNTIME_CONFIG"
[[ "$(cat "$check_log")" == "$N2X_RUNTIME_CONFIG".* ]]
[[ ! -e "$(cat "$check_log")" ]]

# An unchanged render should not generate another save of the running file.
config 0 > "$work_dir/output"
[[ "$menu_returns" == 1 ]]
grep -q '运行配置没有变化' "$work_dir/output"
[[ "$(wc -l < "$check_log")" -eq 1 ]]

cp "$N2X_RUNTIME_CONFIG" "$work_dir/runtime-before"
printf '%s\n' '{invalid' > "$work_dir/edited.json"
if config 0 > "$work_dir/output" 2>&1; then
    echo 'Invalid config should fail validation' >&2
    exit 1
fi
cmp -s "$N2X_RUNTIME_CONFIG" "$work_dir/runtime-before"
grep -q '配置检查失败' "$work_dir/output"
[[ ! -e "$(tail -n 1 "$check_log")" ]]

# OpenRC reads the edited source directly. A stopped service saves for next start.
release=alpine
printf '%s\n' '{"ApiKey":"updated"}' > "$work_dir/edited.json"
config 0 > "$work_dir/output"
[[ "$(tail -n 1 "$check_log")" == "$N2X_CONFIG_DIR/config.json" ]]
cmp -s "$N2X_RUNTIME_CONFIG" "$work_dir/runtime-before"
release=debian
service_status=1
config 0 > "$work_dir/output"
grep -q '下次启动时会读取' "$work_dir/output"
cmp -s "$N2X_RUNTIME_CONFIG" "$work_dir/runtime-before"
[[ ! -e "$work_dir/restarted" ]]

echo '手动修改配置保存后由 N2X 热重载'
