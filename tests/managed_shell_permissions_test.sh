#!/usr/bin/env bash
# 仅在临时目录测试脚本替换，不访问网络或系统安装路径。
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
log_error() { :; }
red='' plain=''
SCRIPT_DIR="$work_dir/source"
mkdir -p "$SCRIPT_DIR" "$work_dir/bin"
payload="$SCRIPT_DIR/N2X.sh"
target="$work_dir/bin/N2X"

write_payload() {
    printf '%s\n' '#!/bin/bash' 'echo new' > "$payload"
    command chmod 644 "$payload"
}

reset_target() {
    printf '%s\n' '#!/bin/bash' 'echo old' > "$target"
    command chmod 755 "$target"
}

# 下载使用本地夹具。
curl() {
    local output=''
    [[ "$failure" != download ]] || return 1
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -o ]]; then
            output="$2"
            shift
        fi
        shift
    done
    cp "$payload" "$output"
}
chmod() {
    [[ "$failure" != chmod ]] || return 1
    command chmod "$@"
}
mv() {
    # 替换发生的瞬间就必须可执行，不能依赖调用方事后补权限。
    [[ -x "$2" ]] || fail "替换前没有设置执行权限：$script / $backend"
    [[ "$failure" != mv ]] || return 1
    command mv "$@"
}

assert_old_preserved() {
    [[ "$("$target")" == old ]] || fail "失败后旧入口被改动"
    local leftovers=("${target}.tmp."*)
    [[ ! -e "${leftovers[0]}" ]] || fail "失败后未清理临时文件"
}

for script in install.sh N2X.sh; do
    eval "$(awk '/^download_managed_shell_file\(\) \{$/,/^\}$/' "$repo_dir/$script")"
    if [[ "$script" == install.sh ]]; then
        eval "$(awk '/^download_file\(\) \{$/,/^\}$/' "$repo_dir/$script")"
        eval "$(awk '/^install_managed_shell_file\(\) \{$/,/^\}$/' "$repo_dir/$script")"
        backends='local curl'
    else
        backends='curl'
    fi

    for backend in $backends; do
        publish() {
            if [[ "$backend" == local ]]; then
                install_managed_shell_file N2X.sh "$target" https://example.invalid/N2X.sh
            else
                download_managed_shell_file https://example.invalid/N2X.sh "$target"
            fi
        }

        failure=none
        write_payload
        reset_target
        publish || fail "替换失败：$script / $backend"
        [[ "$("$target")" == new ]] || fail "新入口无法直接运行"

        rm "$target"
        publish || fail "首次安装失败：$script / $backend"
        [[ "$("$target")" == new ]] || fail "首次安装的入口无法直接运行"

        for failure in chmod mv syntax download; do
            [[ "$backend" != local || "$failure" != download ]] || continue
            reset_target
            write_payload
            if [[ "$failure" == syntax ]]; then
                printf '%s\n' 'if then' > "$payload"
            fi
            if publish 2>/dev/null; then
                fail "$failure 失败时未返回错误：$script / $backend"
            fi
            assert_old_preserved
        done
    done
done

# 还原真实安装顺序：入口替换成功、第二个模块下载失败，入口仍应能运行。
script=install.sh backend=curl failure=none
write_payload
eval "$(awk '/^download_managed_shell_file\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
eval "$(awk '/^install_managed_shell_file\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
support_body="$(awk '/^install_support_scripts\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
support_body="${support_body//\/usr\/bin\/N2X/$target}"
support_body="${support_body//\/usr\/local\/N2X/$work_dir/support}"
eval "$support_body"
reset_target
failure=download
if install_support_scripts; then
    fail "第二个模块下载失败时安装应返回错误"
fi
[[ "$("$target")" == new ]] || fail "后续模块失败导致入口不可执行"

echo 'managed_shell_permissions_test: OK'
