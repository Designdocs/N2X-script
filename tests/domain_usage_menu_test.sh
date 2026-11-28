#!/usr/bin/env bash
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export N2X_CONFIG_DIR="$work/config"
marker="$N2X_CONFIG_DIR/domain-usage.disabled"
sed -n '/^domain_usage_menu() {/,/^}/p' "$repo/N2X.sh" >"$work/functions"
source "$work/functions"
show_menu(){ :; }
domain_usage_menu <<< $'2\n0' >"$work/out"
test -f "$marker"
grep -Fq '当前设置：开启' "$work/out"
grep -Fq '当前设置：关闭' "$work/out"
domain_usage_menu <<< $'2\n1\n0' >"$work/out"
test ! -e "$marker"
grep -Fq '26) check_install && domain_usage_menu ;;' "$repo/N2X.sh"
