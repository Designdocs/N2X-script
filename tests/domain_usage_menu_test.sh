#!/usr/bin/env bash
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export N2X_CONFIG_DIR="$work/config"
marker="$N2X_CONFIG_DIR/domain-usage.disabled"
sed -n -e '/^init_menu_colors() {/,/^}/p' -e '/^domain_usage_menu() {/,/^}/p' "$repo/N2X.sh" >"$work/functions"
source "$work/functions"
init_menu_colors > /dev/null
show_menu(){ :; }
domain_usage_menu <<< $'2\n0' >"$work/out"
test -f "$marker"
grep -Fq '当前设置：开启' "$work/out"
grep -Fq '当前设置：关闭' "$work/out"
domain_usage_menu <<< $'2\n1\n0' >"$work/out"
test ! -e "$marker"
grep -Fq '26) check_install && domain_usage_menu ;;' "$repo/N2X.sh"
export N2X_BIN="$work/binary"
cat > "$N2X_BIN" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == domain-usage-status ]]; then
    printf '统计占用：24.50 MiB / 128 MiB\n磁盘可用：850 MiB\n运行状态：自动暂停 · 磁盘空间不足，达到 1.25 GiB 后自动恢复\n'
    exit 0
fi
printf '%s\n' "$*" >> "$N2X_MENU_TEST_LOG"
STUB
chmod +x "$N2X_BIN"
export N2X_MENU_TEST_LOG="$work/calls"
domain_usage_menu <<< $'3\n42\n1\n3\n42\n2\n2026-11-27\n3\n-1\n0' > "$work/out"
diff -u <(printf '%s\n' 'domain-usage 42' 'domain-usage 42 --day 2026-11-27') "$work/calls"
grep -Fq '统计占用：24.50 MiB / 128 MiB' "$work/out"
grep -Fq '磁盘可用：850 MiB' "$work/out"
grep -Fq '自动暂停 · 磁盘空间不足' "$work/out"
