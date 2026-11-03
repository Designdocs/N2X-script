#!/bin/bash
# Independent Xray geodata updates; source this module from the manager.

geodata_download() {
    local url="$1" output="$2"
    [[ "$url" == https://* ]] || return 1
    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
            --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 \
            -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --timeout=30 --tries=3 -q -O "$output" "$url"
    else
        echo "Geo 更新需要 curl 或 wget。" >&2
        return 1
    fi
}

geodata_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        echo "Geo 更新需要 sha256sum、shasum 或 openssl 校验文件。" >&2
        return 1
    fi
}

geodata_service_running() {
    if [[ "${release:-}" == alpine ]]; then
        service N2X status >/dev/null 2>&1
    else
        systemctl is-active --quiet N2X
    fi
}

geodata_restart_service() {
    if [[ "${release:-}" == alpine ]]; then
        service N2X restart && service N2X status >/dev/null 2>&1
    else
        systemctl restart N2X && systemctl is-active --quiet N2X
    fi
}

geodata_update() (
    # The subshell keeps traps and temporary state out of the interactive menu.
    local restart_requested=0 arg
    for arg in "$@"; do
        case "$arg" in
            -r|--restart) restart_requested=1 ;;
            *) echo "用法：N2X update geodata [-r|--restart]" >&2; return 1 ;;
        esac
    done

    local asset_dir="${N2X_GEODATA_DIR:-/etc/N2X}"
    local revision="${N2X_GEODATA_REVISION:-}" base_url file expected actual
    local stage='' rollback=0 restart_attempted=0
    local lock="${asset_dir}/.geodata-update.lock"
    local directory_lock=0
    local files=(geoip.dat geosite.dat geodata.revision.txt)
    mkdir -p "$asset_dir" || return 1
    if command -v flock >/dev/null 2>&1; then
        # Do not unlink this file: all contenders must lock the same inode.
        # The kernel releases the lock even after SIGKILL or an OOM kill.
        exec 9>"$lock" || return 1
        if ! flock -n 9; then
            echo "另一个 Geo 更新任务正在运行。" >&2
            return 1
        fi
    else
        if ! mkdir "$lock" 2>/dev/null; then
            echo "另一个 Geo 更新任务正在运行或上次异常退出遗留锁：${lock}" >&2
            return 1
        fi
        directory_lock=1
    fi

    geodata_cleanup() {
        local geo_exit_code="$1" name recovery_failed=0
        if [[ "$rollback" == 1 ]]; then
            for name in "${files[@]}"; do
                if [[ -f "$stage/old/$name" ]]; then
                    mv -f "$stage/old/$name" "$asset_dir/$name" || recovery_failed=1
                else
                    rm -f "$asset_dir/$name" || recovery_failed=1
                fi
            done
            if [[ "$recovery_failed" == 0 ]]; then
                echo "Geo 更新未完成，已恢复原数据。" >&2
                if [[ "$restart_attempted" == 1 ]]; then
                    geodata_restart_service || echo "原数据已恢复，但 N2X 重新启动失败，请检查服务日志。" >&2
                fi
            else
                echo "恢复原数据失败，备份保留在 ${stage}/old，请检查磁盘和权限。" >&2
            fi
        fi
        if [[ -n "$stage" && "$recovery_failed" == 0 ]]; then
            rm -rf "$stage"
        fi
        if [[ "$directory_lock" == 1 ]]; then
            rmdir "$lock" 2>/dev/null || true
        fi
        return "$geo_exit_code"
    }
    trap 'geodata_cleanup "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Stage on the destination filesystem so each replacement is a rename.
    stage="$(mktemp -d "${asset_dir}/.geodata.XXXXXX")" || return 1
    mkdir "$stage/old" || return 1
    if [[ -z "$revision" ]]; then
        if ! geodata_download \
            https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/git/ref/heads/release \
            "$stage/release.json"; then
            echo "获取 Geo 数据版本失败，原数据未改动。" >&2
            return 1
        fi
        revision="$(sed -nE 's/^[[:space:]]*"sha":[[:space:]]*"([[:xdigit:]]{40})".*/\1/p' "$stage/release.json")"
    fi
    if [[ ! "$revision" =~ ^[[:xdigit:]]{40}$ ]]; then
        echo "Geo 数据版本不是有效的提交 SHA，原数据未改动。" >&2
        return 1
    fi
    # Pin every file and checksum to the same snapshot, even during a release.
    base_url="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/${revision}"
    for file in geoip.dat geosite.dat; do
        if ! geodata_download "$base_url/$file" "$stage/$file" \
            || ! geodata_download "$base_url/${file}.sha256sum" "$stage/${file}.sha256sum"; then
            echo "下载 ${file} 或校验文件失败，原数据未改动。" >&2
            return 1
        fi
        expected="$(awk 'NR == 1 {print tolower($1)}' "$stage/${file}.sha256sum")"
        actual="$(geodata_sha256 "$stage/$file")" || return 1
        if [[ ! -s "$stage/$file" || ! "$expected" =~ ^[0-9a-f]{64}$ || "$actual" != "$expected" ]]; then
            echo "${file} 的 SHA-256 校验失败，原数据未改动。" >&2
            return 1
        fi
    done

    if cmp -s "$stage/geoip.dat" "$asset_dir/geoip.dat" \
        && cmp -s "$stage/geosite.dat" "$asset_dir/geosite.dat"; then
        echo "Geo 数据已是最新，无需重启。"
        return 0
    fi
    printf '%s\n' "$revision" > "$stage/geodata.revision.txt" || return 1
    for file in "${files[@]}"; do
        if [[ -e "$asset_dir/$file" || -L "$asset_dir/$file" ]]; then
            if [[ ! -f "$asset_dir/$file" || -L "$asset_dir/$file" ]]; then
                echo "拒绝替换非普通文件：${asset_dir}/${file}" >&2
                return 1
            fi
            cp -p "$asset_dir/$file" "$stage/old/$file" || return 1
        fi
        chmod 644 "$stage/$file" || return 1
    done
    rollback=1
    for file in "${files[@]}"; do
        mv -f "$stage/$file" "$asset_dir/$file" || return 1
    done

    if [[ "$restart_requested" == 1 ]] && geodata_service_running; then
        restart_attempted=1
        if ! geodata_restart_service; then
            echo "应用 Geo 数据时 N2X 重启失败，准备恢复原数据。" >&2
            return 1
        fi
        echo "Geo 数据已更新，N2X 已重启。"
    else
        echo "Geo 数据已更新；下次启动或重启 N2X 时生效。"
    fi
    rollback=0
)
