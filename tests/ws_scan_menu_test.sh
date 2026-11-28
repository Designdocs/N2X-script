#!/usr/bin/env bash
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
source "$repo/config_append.sh"
sed -n -e '/^init_menu_colors() {/,/^}/p' -e '/^ws_scan_menu() {/,/^}/p' "$repo/N2X.sh" >"$work/menu.sh"
source "$work/menu.sh"
init_menu_colors > /dev/null
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
grep -Fq '"RelayCAFile": "builtin"' "$work/config.json"
n2x_config_py ws-setting "$work/config.json" off
! grep -q RelayCAFile "$work/config.json" || exit 1

for ca in '' builtin /etc/N2X/custom-ca.pem; do
    printf '{"WSScanGuard":{"Enabled":true,"DirectOnlyNodes":["direct-a"],"FeedbackCertFile":"cert","FeedbackKeyFile":"key","RelayCAFile":"%s"}}' "$ca" >"$work/config.json"
    for action in on on off off; do
        n2x_config_py ws-setting "$work/config.json" "$action"
        python3 - "$work/config.json" "$action" "$ca" <<'CHECK'
import json, sys
with open(sys.argv[1]) as f:
    actual = json.load(f)["WSScanGuard"]
on = sys.argv[2] == "on"
expected = dict(Enabled=on, DirectOnlyNodes=["direct-a"], FeedbackCertFile="cert", FeedbackKeyFile="key")
if on or sys.argv[3] not in ("", "builtin"):
    expected["RelayCAFile"] = sys.argv[3] or "builtin"
assert actual == expected, actual
CHECK
    done
done
echo '{"WSScanGuard":{"RelayCAFile":"builtin", /* keep */ }}' >"$work/config.json"
n2x_config_py ws-setting "$work/config.json" off
test "$(n2x_config_py ws-setting "$work/config.json" status)" = '已关闭'
grep -Fq '/* keep */' "$work/config.json"
echo 'WS menu OK'
