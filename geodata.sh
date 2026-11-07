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

geodata_service_instance() {
    local pid stat boot
    local -a fields
    if [[ "${release:-}" == alpine ]]; then
        read -r pid 2>/dev/null < /run/N2X.pid || return 1
    else
        pid="$(systemctl show -p MainPID N2X)" || return 1
        pid="${pid#MainPID=}"
    fi
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    read -r stat 2>/dev/null < "/proc/$pid/stat" || return 1
    read -r boot < /proc/sys/kernel/random/boot_id || return 1
    # Field 22 is the process start time, after the parenthesized command name.
    read -r -a fields <<< "${stat##*) }"
    [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s %s\n' "$boot" "$pid" "${fields[19]}"
}

geodata_restart_service() {
    if [[ "${release:-}" == alpine ]]; then
        rc-service --ifstarted N2X restart && service N2X status >/dev/null 2>&1
    else
        systemctl try-restart N2X && systemctl is-active --quiet N2X
    fi
}

geodata_lock() {
    # Called in a subshell with lock/directory_lock local to the caller.
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
}

geodata_slot() {
    local day minute date
    # Shanghai is UTC+8 year-round. POSIX TZ also works without tzdata on Alpine.
    read -r day minute date <<< "$(LC_ALL=C TZ=CST-8 date '+%w %H%M %Y-%m-%d')"
    [[ "$day" == 0 ]] || return 1
    case "$1:$minute" in
        update:030[0-4]|apply:03[3-5][0-9]) printf '%s\n' "$date" ;;
        *) return 1 ;;
    esac
}

geodata_claim_slot() {
    local stamp="$asset_dir/.geodata-$1-date" last=''
    if [[ -f "$stamp" ]]; then
        read -r last < "$stamp" || true
        [[ "$last" < "$2" ]] || return 1
    fi
    printf '%s\n' "$2" > "$stamp"
}

geodata_update() (
    # The subshell keeps traps and temporary state out of the interactive menu.
    local defer_apply=0 scheduled=0 arg slot instance=''
    for arg in "$@"; do
        case "$arg" in
            -r|--restart) defer_apply=1 ;;
            --weekly) scheduled=1; defer_apply=1 ;;
            *) echo "用法：N2X update geodata [-r|--restart]" >&2; return 1 ;;
        esac
    done
    if [[ "$scheduled" == 1 ]]; then
        slot="$(geodata_slot update)" || return 0
    fi

    local asset_dir="${N2X_GEODATA_DIR:-/etc/N2X}"
    local revision="${N2X_GEODATA_REVISION:-}" base_url file expected actual installed=''
    local stage='' rollback=0
    local lock="${asset_dir}/.geodata-update.lock" directory_lock=0
    local files=(geoip.dat geosite.dat geodata.revision.txt)
    geodata_lock || return 1

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

    if [[ "$scheduled" == 1 ]]; then
        geodata_claim_slot update "$slot" || return 0
    fi

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
    if [[ -f "$asset_dir/geodata.revision.txt" && ! -L "$asset_dir/geodata.revision.txt" ]]; then
        read -r installed < "$asset_dir/geodata.revision.txt" || true
    fi
    if [[ "$revision" == "$installed" && -s "$asset_dir/geoip.dat" && ! -L "$asset_dir/geoip.dat" \
        && -s "$asset_dir/geosite.dat" && ! -L "$asset_dir/geosite.dat" ]]; then
        echo "Geo 数据已是最新。"
        return 0
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

    if [[ ! -L "$asset_dir/geoip.dat" && ! -L "$asset_dir/geosite.dat" ]] \
        && cmp -s "$stage/geoip.dat" "$asset_dir/geoip.dat" \
        && cmp -s "$stage/geosite.dat" "$asset_dir/geosite.dat"; then
        # Remember the new upstream SHA even when only upstream metadata changed.
        files=(geodata.revision.txt)
    elif [[ "$defer_apply" == 1 ]] && instance="$(geodata_service_instance)"; then
        printf '%s\n' "$instance" > "$stage/.geodata-pending" || return 1
        files+=(.geodata-pending)
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

    rollback=0
    if [[ "${#files[@]}" == 1 ]]; then
        echo "Geo 文件内容未变化。"
    elif [[ -n "$instance" ]]; then
        echo "Geo 数据已替换；如当前进程仍在运行，将于上海时间周日 03:30 重启生效。"
    else
        echo "Geo 数据已更新；下次启动或重启 N2X 时生效。"
    fi
)

geodata_apply_pending() (
    local asset_dir="${N2X_GEODATA_DIR:-/etc/N2X}"
    local lock="${asset_dir}/.geodata-update.lock" directory_lock=0
    local pending="$asset_dir/.geodata-pending" slot previous current
    slot="$(geodata_slot apply)" || return 0
    [[ -f "$pending" ]] || return 0
    geodata_lock || return 1
    trap 'if [[ "$directory_lock" == 1 ]]; then rmdir "$lock" 2>/dev/null || true; fi' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    [[ -f "$pending" && ! -L "$pending" ]] || return 0
    read -r previous < "$pending" || return 1
    current="$(geodata_service_instance)" || return 0
    if [[ "$previous" != "$current" ]]; then
        # A normal service restart or host boot already loaded the new files.
        rm -f "$pending"
        return
    fi
    maintenance_check_config || return 1
    [[ "$(geodata_slot apply)" == "$slot" ]] || return 0
    geodata_claim_slot apply "$slot" || return 0
    if ! geodata_restart_service; then
        echo "N2X 在 Geo 维护窗口内重启失败，请检查服务日志。" >&2
        return 1
    fi
    rm -f "$pending" || return 1
    echo "N2X 已在上海时间周日凌晨的维护窗口重启，Geo 数据已生效。"
)

geodata_weekly() {
    if geodata_slot update >/dev/null; then
        geodata_update --weekly
    elif maintenance_apply_slot >/dev/null; then
        maintenance_apply
    fi
}

maintenance_clock() {
    LC_ALL=C TZ=CST-8 date '+%Y-%m-%d %H%M'
}

maintenance_apply_slot() {
    local day minute
    read -r day minute <<< "$(maintenance_clock)"
    [[ "$minute" == 033[0-4] ]] && printf '%s\n' "$day"
}

maintenance_apply_window() {
    local day minute
    read -r day minute <<< "$(maintenance_clock)"
    [[ "$day" == "$1" && "$minute" == 03[3-5][0-9] ]]
}

maintenance_check_config() {
    if ! "${N2X_BIN:-/usr/local/N2X/N2X}" check -c "${N2X_MAINTENANCE_DIR:-/etc/N2X}/config.json"; then
        echo "配置校验失败，跳过计划重启，继续使用运行中的配置。" >&2
        return 1
    fi
}

maintenance_monthly_update() {
    local slot="$1" stage
    [[ "$slot" == *-01 ]] || return 0
    # Never start a service that the administrator stopped.
    geodata_service_instance >/dev/null || return 0
    (
        stage="$(mktemp -d)" || return 1
        trap 'rm -rf "$stage"' EXIT
        curl -fsSL --connect-timeout 10 --max-time 30 -o "$stage/install.sh" \
            https://raw.githubusercontent.com/Designdocs/N2X-script/main/install.sh \
            && [[ -s "$stage/install.sh" ]] && bash "$stage/install.sh" --scheduled
    )
}

maintenance_apply() (
    local slot asset_dir="${N2X_MAINTENANCE_DIR:-/etc/N2X}" directory_lock=0 failed=0
    local lock="$asset_dir/.maintenance-apply.lock"
    slot="$(maintenance_apply_slot)" || return 0
    if [[ "$slot" != *-01 ]]; then
        [[ "${1:-}" != monthly ]] && geodata_slot apply >/dev/null || return 0
    fi
    geodata_lock || return 1
    trap 'if [[ "$directory_lock" == 1 ]]; then rmdir "$lock" 2>/dev/null || true; fi' EXIT
    geodata_claim_slot maintenance "$slot" || return 0
    # A real program upgrade also loads new Geo files on a coinciding Sunday.
    maintenance_monthly_update "$slot" || failed=1
    geodata_apply_pending || return 1
    return "$failed"
)

geodata_migrate_crontab() {
    local mode="$1" old updated
    if ! command -v crontab >/dev/null 2>&1; then
        [[ "$mode" == remove ]]
        return
    fi
    if ! old="$(LC_ALL=C crontab -l 2>&1)"; then
        case "$old" in
            *"no crontab for "*|*"No such file or directory"*) old='' ;;
            *) printf '%s\n' "$old" >&2; return 1 ;;
        esac
    fi
    updated="$(printf '%s\n' "$old" | awk '
        # Drop the old Geo/monthly jobs and prior fallback, preserving unrelated jobs.
        /^[[:space:]]*#/ { print; next }
        {
            task = $0
            if (!sub(/^[[:space:]]*@[[:alpha:]]+[[:space:]]+/, "", task)) {
                for (i = 0; i < 5; i++)
                    if (!sub(/^[[:space:]]*[[:alnum:]*,\/-]+[[:space:]]+/, "", task)) break
                if (i != 5) { print; next }
            }
            if (task ~ /^(N2X_GEODATA_(DIR|REVISION)=[^[:space:]]+[[:space:]]+)*(\/usr\/bin\/)?[Nn]2[Xx][[:space:]]+update[[:space:]]+geodata([[:space:]]+(-r|--restart))?([[:space:]]+>>?\/[^[:space:]]+([[:space:]]+2>&1)?)?[[:space:]]*$/)
                next
            if (task ~ /^(\/usr\/bin\/)?[Nn]2[Xx][[:space:]]+update[[:space:]]+(-r|--restart)([[:space:]]+>>?\/[^[:space:]]+([[:space:]]+2>&1)?)?[[:space:]]*$/)
                next
            if (task == "/usr/bin/N2X geodata weekly >>/var/log/N2X-geodata.log 2>&1 # N2X-geodata-weekly")
                next
            print
        }
    ')" || return 1
    if [[ "$mode" == fallback ]]; then
        # BusyBox cron has no per-job scheduling timezone. Only the local clock
        # is read outside the two Shanghai slots, with no upstream requests.
        updated="${updated:+$updated$'\n'}0,15,30,45 * * * * /usr/bin/N2X geodata weekly >>/var/log/N2X-geodata.log 2>&1 # N2X-geodata-weekly"
    fi
    if [[ "$old" != "$updated" ]]; then
        printf '%s\n' "$updated" | crontab - || return 1
    fi
}

geodata_schedule_install() {
    local unit_dir="${1:-/etc/systemd/system}"
    local calendar='Sun *-*-* 03:00,30:00 Asia/Shanghai'
    local apply_calendar='*-*-01 03:30:00 Asia/Shanghai'

    if [[ "${release:-}" == alpine ]]; then
        geodata_migrate_crontab fallback \
            && rc-update add crond default \
            && rc-service --ifnotstarted crond start || return 1
    else
        if ! systemd-analyze calendar "$calendar" "$apply_calendar" >/dev/null 2>&1; then
            # Old systemd releases (e.g. CentOS 7) lack named timezones.
            calendar='*-*-* *:00,15,30,45:00'
            apply_calendar=''
        fi
        geodata_migrate_crontab remove || return 1
        (
            umask 022
            cat > "$unit_dir/N2X-geodata.service" <<'EOF' || exit 1
[Unit]
Description=N2X Shanghai maintenance
After=network.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/N2X/geodata.env
UMask=0077
ExecStart=/usr/bin/N2X geodata weekly
EOF
            cat > "$unit_dir/N2X-geodata.timer" <<EOF || exit 1
[Unit]
Description=N2X Sunday Geo and monthly program maintenance in Shanghai time

[Timer]
OnCalendar=$calendar
${apply_calendar:+OnCalendar=$apply_calendar}
AccuracySec=1s
Persistent=false

[Install]
WantedBy=timers.target
EOF
        ) || return 1
        systemctl daemon-reload && systemctl enable N2X-geodata.timer \
            && systemctl start N2X-geodata.timer || return 1
    fi
    echo "上海维护计划已设置：每周日 03:00 检查 Geo、03:30 按需生效；每月 1 日 03:30 检查程序更新。"
}

geodata_schedule_remove() {
    geodata_migrate_crontab remove || return 1
    if [[ "${release:-}" != alpine && -f /etc/systemd/system/N2X-geodata.timer ]]; then
        systemctl stop N2X-geodata.timer N2X-geodata.service \
            && systemctl disable N2X-geodata.timer \
            && rm -f /etc/systemd/system/N2X-geodata.{timer,service} \
            && systemctl daemon-reload || return 1
    fi
}
