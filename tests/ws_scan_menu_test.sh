#!/usr/bin/env bash
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
source "$repo/config_append.sh"
sed -n '/^ws_scan_menu() {/,/^}/p' "$repo/N2X.sh" >"$work/menu.sh"
source "$work/menu.sh"
export N2X_CONFIG_DIR="$work" N2X_WS_SCAN_STATE_DIR="$work/state"
config_apply_saved() { n2x_config_py ws-setting "$1" status >>"$work/applied"; }
show_menu() { :; }
cat >"$work/config.json" <<'JSON'
{ // keep this comment and placeholder
  "Nodes": [{"ApiHost": "${N2X_API_HOST}"}],
  "WSScanGuard": { "LogMaxMB": 8, }, /* untouched */
}
JSON
mkdir -p "$work/state"
echo '{"node":"node-two","rule":"environment","time":"2026-01-02T02:00:00Z","path":"/.env"}' >"$work/state/intercepts.jsonl"
mkdir -p "$work/state/bans/test"
echo '{"time":"2026-01-02T03:00:00Z","node":"node-two","visitor":"192.0.2.7"}' >"$work/state/bans/test/192.0.2.7"
echo '{"node":"node-two","rule":"wordpress","time":"2026-01-02T03:00:00Z","path":"/wp-admin","visitor":"192.0.2.7","action":"node-ban"}' >>"$work/state/intercepts.jsonl"
ws_scan_menu >"$work/result" <<'CHOICES'
1
3
4
2
0
CHOICES
test "$(cat "$work/applied")" = "$(printf '已开启\n已关闭')"
for text in 'node-two' '/.env' 'environment' '已永久封禁此节点' '访客 192.0.2.7' '2026-01-02T02:00:00Z'; do
    grep -Fq "$text" "$work/result"
done
grep -Fq '"LogMaxMB": 8, }, /* untouched */' "$work/config.json"
grep -Fq '${N2X_API_HOST}' "$work/config.json"
echo '{"Cores":[]}' >"$work/config.json"
n2x_config_py ws-setting "$work/config.json" on
test "$(n2x_config_py ws-setting "$work/config.json" status)" = '已开启'
echo 'WS menu OK'
