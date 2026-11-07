#!/usr/bin/env bash
# Exercise downloads, rollback and command routing only in a temporary tree.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$repo_dir/geodata.sh"
mkdir "$work_dir/remote"
printf 'new geoip\n' > "$work_dir/remote/geoip.dat"
printf 'new geosite\n' > "$work_dir/remote/geosite.dat"
fixture_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for name in geoip.dat geosite.dat; do
    printf '%s  %s\n' "$(geodata_sha256 "$work_dir/remote/$name")" "$name" > "$work_dir/remote/${name}.sha256sum"
done

reset_case() {
    local name="$1"
    case_dir="$work_dir/$name"
    mkdir -p "$case_dir/assets"
    export N2X_GEODATA_DIR="$case_dir/assets"
    export N2X_MAINTENANCE_DIR="$N2X_GEODATA_DIR"
    unset N2X_GEODATA_REVISION
    fault=none running=1 mock_instance='boot 101 1'
    printf 'old geoip\n' > "$N2X_GEODATA_DIR/geoip.dat"
    printf 'old geosite\n' > "$N2X_GEODATA_DIR/geosite.dat"
    printf 'old revision\n' > "$N2X_GEODATA_DIR/geodata.revision.txt"
    : > "$case_dir/downloads"
    : > "$case_dir/restarts"
}

geodata_download() {
    local url="$1" output="$2" name="${1##*/}"
    printf '%s\n' "$url" >> "$case_dir/downloads"
    if [[ "$name" == release ]]; then
        if [[ "$fault" == api ]]; then return 1; fi
        if [[ "$fault" == api_json ]]; then printf 'not json\n' > "$output"; return 0; fi
        printf '{\n  "object": {\n    "sha": "%s"\n  }\n}\n' "$fixture_revision" > "$output"
        return 0
    fi
    [[ "$url" == "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/$fixture_revision/"* ]] || fail "unpinned or unexpected download: $url"
    if [[ "$fault" == partial && "$name" == geosite.dat ]]; then
        printf 'partial' > "$output"
        return 1
    fi
    if [[ "$fault" == missing_checksum && "$name" == geosite.dat.sha256sum ]]; then return 1; fi
    cp "$work_dir/remote/$name" "$output"
    if [[ "$fault" == checksum && "$name" == geosite.dat.sha256sum ]]; then printf 'invalid checksum\n' > "$output"; fi
    if [[ "$fault" == mismatch && "$name" == geosite.dat ]]; then printf 'corrupt data\n' > "$output"; fi
    if [[ "$fault" == empty && "$name" == geosite.dat ]]; then : > "$output"; fi
}
geodata_service_instance() {
    [[ "$running" == 1 ]] || return 1
    if [[ -f "$case_dir/new-instance" ]]; then
        cat "$case_dir/new-instance"
        return
    fi
    printf '%s\n' "$mock_instance"
}
geodata_restart_service() {
    printf 'restart\n' >> "$case_dir/restarts"
    [[ "$fault" != restart ]] || return 1
    mock_instance='boot 102 2'
}
maintenance_check_config() {
    [[ "$fault" != invalid_config ]]
}
mv() {
    local previous='' last='' arg
    for arg in "$@"; do previous="$last"; last="$arg"; done
    if [[ "$fault" == replace && "$previous" == */.geodata.*/geosite.dat && "$previous" != */old/* && ! -f "$case_dir/replace_failed" ]]; then
        touch "$case_dir/replace_failed"
        return 1
    fi
    command mv "$@"
}
assert_old() {
    [[ "$(cat "$N2X_GEODATA_DIR/geoip.dat")" == 'old geoip' ]] || fail 'old geoip changed on failure'
    [[ "$(cat "$N2X_GEODATA_DIR/geosite.dat")" == 'old geosite' ]] || fail 'old geosite changed on failure'
    [[ "$(cat "$N2X_GEODATA_DIR/geodata.revision.txt")" == 'old revision' ]] || fail 'old revision changed on failure'
}
assert_clean() {
    [[ ! -d "$N2X_GEODATA_DIR/.geodata-update.lock" ]] || fail 'lock leaked'
    local candidate
    for candidate in "$N2X_GEODATA_DIR"/.geodata.*; do
        [[ ! -e "$candidate" ]] || fail "staging directory leaked: $candidate"
    done
}

reset_case success
geodata_update -r > "$case_dir/log" 2>&1 || fail "update failed: $(cat "$case_dir/log")"
cmp -s "$N2X_GEODATA_DIR/geoip.dat" "$work_dir/remote/geoip.dat" || fail 'new geoip missing'
cmp -s "$N2X_GEODATA_DIR/geosite.dat" "$work_dir/remote/geosite.dat" || fail 'new geosite missing'
[[ "$(cat "$N2X_GEODATA_DIR/geodata.revision.txt")" == "$fixture_revision" ]] || fail 'revision not recorded'
[[ ! -s "$case_dir/restarts" && -s "$N2X_GEODATA_DIR/.geodata-pending" ]] || fail 'legacy -r must only queue the restart'
assert_clean
# An already known revision requires one metadata request and no file transfers.
: > "$case_dir/downloads"
geodata_update -r >> "$case_dir/log" 2>&1 || fail 'unchanged update failed'
[[ "$(wc -l < "$case_dir/downloads" | tr -d ' ')" == 1 ]] || fail 'same revision re-downloaded data'
[[ ! -s "$case_dir/restarts" ]] || fail 'unchanged data restarted service'

for scenario in api api_json partial missing_checksum checksum mismatch empty replace; do
    reset_case "$scenario"
    fault="$scenario"
    if geodata_update -r > "$case_dir/log" 2>&1; then fail "$scenario unexpectedly succeeded"; fi
    assert_old
    assert_clean
    [[ ! -s "$case_dir/restarts" && ! -e "$N2X_GEODATA_DIR/.geodata-pending" ]] || fail "$scenario scheduled or restarted service"
done

reset_case download_only
geodata_update > "$case_dir/log" 2>&1 || fail 'download-only update failed'
[[ ! -s "$case_dir/restarts" && ! -e "$N2X_GEODATA_DIR/.geodata-pending" ]] || fail 'download-only update scheduled or restarted service'
reset_case stopped
running=0
geodata_update --restart > "$case_dir/log" 2>&1 || fail 'stopped-service update failed'
[[ ! -s "$case_dir/restarts" && ! -e "$N2X_GEODATA_DIR/.geodata-pending" ]] || fail 'stopped service was queued or started'

reset_case identical_files
cp "$work_dir/remote/"*.dat "$N2X_GEODATA_DIR/"
geodata_update -r > "$case_dir/log" 2>&1 || fail 'identical data from a new SHA failed'
[[ "$(cat "$N2X_GEODATA_DIR/geodata.revision.txt")" == "$fixture_revision" ]] || fail 'equivalent revision not recorded'
[[ ! -e "$N2X_GEODATA_DIR/.geodata-pending" ]] || fail 'identical data queued a restart'

reset_case first_install
rm "$N2X_GEODATA_DIR/geoip.dat" "$N2X_GEODATA_DIR/geosite.dat" "$N2X_GEODATA_DIR/geodata.revision.txt"
geodata_update > "$case_dir/log" 2>&1 || fail 'missing data could not be populated'
assert_clean
reset_case invalid_argument
if geodata_update --wrong > "$case_dir/log" 2>&1; then fail 'unknown flag accepted'; fi
assert_old
[[ ! -s "$case_dir/downloads" ]] || fail 'invalid flag triggered a download'
reset_case locked
mkdir "$N2X_GEODATA_DIR/.geodata-update.lock"
if geodata_update -r > "$case_dir/log" 2>&1; then fail 'concurrent update was allowed'; fi
assert_old
[[ ! -s "$case_dir/downloads" ]] || fail 'concurrent update downloaded data'
reset_case symlink
rm "$N2X_GEODATA_DIR/geosite.dat"
printf 'external data\n' > "$case_dir/external.dat"
ln -s "$case_dir/external.dat" "$N2X_GEODATA_DIR/geosite.dat"
if geodata_update -r > "$case_dir/log" 2>&1; then fail 'symlink target was replaced'; fi
[[ -L "$N2X_GEODATA_DIR/geosite.dat" && "$(cat "$case_dir/external.dat")" == 'external data' ]] || fail 'external file changed'
assert_clean

# Exercise the flock branch even on macOS, which lacks the Linux utility.
flock() { [[ "$*" == '-n 9' ]] || fail 'incorrect lock descriptor'; [[ "$fault" != flock_busy ]]; }
reset_case flock_success
geodata_update > "$case_dir/log" 2>&1 || fail 'flock update failed'
geodata_update >> "$case_dir/log" 2>&1 || fail 'persistent lock inode prevented the next update'
reset_case flock_busy
fault=flock_busy
if geodata_update -r > "$case_dir/log" 2>&1; then fail 'busy flock was ignored'; fi
assert_old
[[ ! -s "$case_dir/downloads" ]] || fail 'busy flock downloaded data'
unset -f flock

# Drive the clock from UTC instants, including the reported Pacific Friday 20:00.
# Use the real date utility to apply the production timezone.
epoch() { python3 -c 'from datetime import datetime; import sys; print(int(datetime.fromisoformat(sys.argv[1]).timestamp()))' "$1"; }
date() {
    if [[ "$(uname -s)" == Darwin ]]; then
        command date -r "$clock" "$@"
    else
        command date -d "@$clock" "$@"
    fi
}
friday_20="$(epoch 2026-11-06T20:00:01-08:00)"
update_time="$(epoch 2026-11-07T19:00:00+00:00)"
apply_time="$(epoch 2026-11-07T19:30:00+00:00)"
late_time="$(epoch 2026-11-07T20:00:00+00:00)"
export TZ=America/Los_Angeles

reset_case weekly
clock="$friday_20"
geodata_weekly || fail 'non-window invocation failed'
[[ ! -s "$case_dir/downloads" && ! -s "$case_dir/restarts" ]] || fail 'Pacific Friday 20:00 reached Geo work'
clock="$update_time"
geodata_weekly > "$case_dir/log" 2>&1 || fail 'Shanghai 03:00 update failed'
[[ "$(wc -l < "$case_dir/downloads" | tr -d ' ')" == 5 && ! -s "$case_dir/restarts" ]] || fail '03:00 did not only stage data'
geodata_weekly >> "$case_dir/log" 2>&1
[[ "$(wc -l < "$case_dir/downloads" | tr -d ' ')" == 5 ]] || fail 'same weekly slot checked twice'
for clock in "$friday_20" "$late_time"; do
    geodata_apply_pending
    [[ ! -s "$case_dir/restarts" ]] || fail 'pending data restarted outside Shanghai window'
done
clock="$apply_time"
geodata_weekly >> "$case_dir/log" 2>&1 || fail 'Shanghai 03:30 apply failed'
geodata_weekly >> "$case_dir/log" 2>&1
[[ "$(wc -l < "$case_dir/restarts" | tr -d ' ')" == 1 ]] || fail 'pending data did not restart exactly once'
[[ "$(wc -l < "$case_dir/downloads" | tr -d ' ')" == 5 ]] || fail 'restart slot contacted upstream'

for scenario in already_restarted stopped_before_apply failed_restart; do
    reset_case "$scenario"
    clock="$update_time"
    geodata_weekly > "$case_dir/log" 2>&1 || fail "$scenario could not stage data"
    clock="$apply_time"
    case "$scenario" in
        already_restarted) mock_instance='boot 102 2' ;;
        stopped_before_apply) running=0 ;;
        failed_restart) fault=restart ;;
    esac
    if geodata_weekly >> "$case_dir/log" 2>&1; then
        [[ "$scenario" != failed_restart && ! -s "$case_dir/restarts" ]] || fail "$scenario unexpectedly restarted"
        if [[ "$scenario" == already_restarted ]]; then
            [[ ! -e "$N2X_GEODATA_DIR/.geodata-pending" ]] || fail 'new process left pending state'
        fi
    else
        [[ "$scenario" == failed_restart ]] || fail "$scenario failed"
        geodata_weekly >> "$case_dir/log" 2>&1
        [[ "$(wc -l < "$case_dir/restarts" | tr -d ' ')" == 1 ]] || fail 'failed restart was retried in the same slot'
    fi
done

reset_case bad_config
clock="$update_time"
geodata_weekly > "$case_dir/log" 2>&1
clock="$apply_time"
fault=invalid_config
if geodata_weekly >> "$case_dir/log" 2>&1; then fail 'Geo restart accepted invalid config'; fi
[[ ! -s "$case_dir/restarts" && -s "$N2X_GEODATA_DIR/.geodata-pending" ]] || fail 'invalid config stopped the service or lost the Geo update'

# Exercise the monthly gate without contacting a network or running the installer.
curl() {
    local output
    while [[ $# -gt 1 ]]; do
        if [[ "$1" == -o ]]; then output="$2"; break; fi
        shift
    done
    [[ -n "${output:-}" ]] || fail 'monthly installer missing output path'
    cat > "$output" <<'EOF'
[[ "$*" == --scheduled ]] || exit 1
printf 'scheduled\n' >> "$MONTHLY_TEST_LOG"
if [[ -n "${MONTHLY_NEW_INSTANCE:-}" ]]; then
    printf 'boot 102 2\n' > "$MONTHLY_NEW_INSTANCE"
fi
EOF
}
reset_case monthly
export MONTHLY_TEST_LOG="$case_dir/monthly"
clock="$(epoch 2026-08-01T04:30:00-07:00)"
maintenance_apply monthly
[[ ! -e "$MONTHLY_TEST_LOG" ]] || fail 'legacy host-local slot ran the monthly installer'
clock="$(epoch 2026-08-01T03:30:00+08:00)"
maintenance_apply monthly
maintenance_apply monthly
[[ "$(cat "$MONTHLY_TEST_LOG")" == scheduled ]] || fail 'monthly update did not run exactly once'

reset_case overlap
export MONTHLY_TEST_LOG="$case_dir/monthly" MONTHLY_NEW_INSTANCE="$case_dir/new-instance"
clock="$(epoch 2026-11-01T03:00:00+08:00)"
geodata_weekly > "$case_dir/log" 2>&1
clock="$(epoch 2026-11-01T03:30:00+08:00)"
geodata_weekly >> "$case_dir/log" 2>&1
[[ "$(cat "$MONTHLY_TEST_LOG")" == scheduled && ! -s "$case_dir/restarts" ]] || fail 'Geo triggered a second restart after a monthly upgrade'
[[ ! -e "$N2X_GEODATA_DIR/.geodata-pending" ]] || fail 'monthly upgrade did not clear the pending Geo state'
unset MONTHLY_NEW_INSTANCE
unset -f curl
unset -f date

# Exercise migration against an isolated crontab and service manager.
schedule_dir="$work_dir/schedule"
mkdir -p "$schedule_dir/units"
crontab() {
    case "$1" in
        -l) cat "$schedule_dir/root.cron" ;;
        -) cat > "$schedule_dir/root.cron" ;;
        *) fail "unexpected crontab command: $*" ;;
    esac
}
systemctl() {
    case "$*" in
        'daemon-reload'|'enable N2X-geodata.timer'|'start N2X-geodata.timer') ;;
        *) fail "scheduler changed the main service: $*" ;;
    esac
}
systemd-analyze() { [[ "$backend" == systemd ]]; }
rc-update() { [[ "$*" == 'add crond default' ]] || fail "unexpected rc-update command: $*"; }
rc-service() { [[ "$*" == '--ifnotstarted crond start' ]] || fail "unexpected OpenRC command: $*"; }
cat > "$schedule_dir/expected.cron" <<'EOF'
# /usr/bin/N2X update geodata -r
MAILTO=""
0 3 * * 4 /usr/bin/N2X update v0.17.17
0 2 * * * /usr/local/bin/snapshot
EOF
cp "$schedule_dir/expected.cron" "$schedule_dir/root.cron"
cat >> "$schedule_dir/root.cron" <<'EOF'
0 4 * * 6 /usr/bin/N2X update geodata -r >/var/log/N2X-geodata.log 2>&1
0 4 * * Sat /usr/bin/N2X update geodata -r >/var/log/N2X-geodata.log 2>&1
@weekly N2X update geodata
30 4 1 * * /usr/bin/N2X update -r >/var/log/N2X-update.log 2>&1
EOF
backend=systemd release=debian
geodata_schedule_install "$schedule_dir/units" > "$schedule_dir/log"
cmp -s "$schedule_dir/root.cron" "$schedule_dir/expected.cron" || fail 'legacy cron migration removed unrelated entries or left an old Geo job'
grep -Fxq 'OnCalendar=Sun *-*-* 03:00,30:00 Asia/Shanghai' "$schedule_dir/units/N2X-geodata.timer" || fail 'missing Shanghai Geo timer'
grep -Fxq 'OnCalendar=*-*-01 03:30:00 Asia/Shanghai' "$schedule_dir/units/N2X-geodata.timer" || fail 'missing Shanghai monthly timer'
grep -Fxq 'Persistent=false' "$schedule_dir/units/N2X-geodata.timer" || fail 'timer catches up after a missed window'
backend=legacy
geodata_schedule_install "$schedule_dir/units" >> "$schedule_dir/log"
grep -Fxq 'OnCalendar=*-*-* *:00,15,30,45:00' "$schedule_dir/units/N2X-geodata.timer" || fail 'legacy systemd has no fallback'
release=alpine
geodata_schedule_install >> "$schedule_dir/log"
geodata_schedule_install >> "$schedule_dir/log"
[[ "$(grep -c 'N2X-geodata-weekly$' "$schedule_dir/root.cron")" == 1 ]] || fail 'fallback duplicated after upgrade'
geodata_schedule_remove
cmp -s "$schedule_dir/root.cron" "$schedule_dir/expected.cron" || fail 'fallback removal changed unrelated cron jobs'

# Verify real command routing with functions extracted from the manager.
eval "$(awk '/^ensure_geodata_module\(\) \{$/,/^\}$/' "$repo_dir/N2X.sh")"
eval "$(awk '/^update_command\(\) \{$/,/^\}$/' "$repo_dir/N2X.sh")"
red='' plain=''
geodata_update() { printf 'geo'; printf ' <%s>' "$@"; printf '\n'; return 7; }
update() { printf 'program'; printf ' <%s>' "$@"; printf '\n'; }
if output="$(update_command geodata -r)"; then fail 'Geo failure exit code was lost'; else geo_exit_code=$?; fi
[[ "$geo_exit_code" == 7 && "$output" == 'geo <-r>' ]] || fail "Geo routing failed: $geo_exit_code / $output"
[[ "$(update_command v0.17.12 -r)" == 'program <0> <v0.17.12>' ]] || fail 'version update routing changed'
maintenance_apply() { printf 'guarded <%s>\n' "$*"; }
[[ "$(update_command -r)" == 'guarded <monthly>' ]] || fail 'legacy cron can bypass the monthly gate'
[[ "$(update_command)" == 'program <0> <>' ]] || fail 'explicit program update was delayed'

# A released update_shell may not fetch new modules: lazily install once.
bootstrap_body="$(awk '/^ensure_geodata_module\(\) \{$/,/^\}$/' "$repo_dir/N2X.sh")"
bootstrap_body="${bootstrap_body//\/usr\/local\/N2X/$work_dir/bootstrap}"
mkdir "$work_dir/bootstrap"
eval "$bootstrap_body"
unset -f maintenance_apply
geodata_update() { fail 'legacy module can still restart immediately'; }
download_managed_shell_file() {
    [[ "$1" == https://raw.githubusercontent.com/Designdocs/N2X-script/main/geodata.sh ]] || fail 'wrong bootstrap URL'
    printf '%s\n' 'maintenance_apply() { :; }' 'geodata_update() { printf "bootstrapped <%s>\\n" "$*"; }' > "$2"
}
[[ "$(update_command geodata -r)" == 'bootstrapped <-r>' ]] || fail 'old manager upgrade did not bootstrap the Geo module'
download_managed_shell_file() { return 1; }
if update_command geodata -r > "$work_dir/bootstrap-failure.log" 2>&1; then fail 'bootstrap failure was swallowed'; fi

# Program installation supplies missing data and keeps newer/custom files.
eval "$(awk '/^install_geodata_files\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
eval "$(awk '/^scheduled_release_is_newer\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
scheduled_release_is_newer v0.17.10 v0.17.9 || fail 'monthly version comparison is not numeric'
if scheduled_release_is_newer v0.17.10 0.17.10; then fail 'monthly job reinstalls the current version'; fi
if scheduled_release_is_newer v0.17.10 v0.18.0; then fail 'monthly job downgrades N2X'; fi
if scheduled_release_is_newer v0.17.10 TempVersion; then fail 'monthly job replaces an unknown local build'; fi
log_error() { printf '%s\n' "$*" >&2; }
install_target="$work_dir/install-assets"
install_geodata_files "$install_target" "$work_dir/remote" || fail 'initial data install failed'
cmp -s "$install_target/geoip.dat" "$work_dir/remote/geoip.dat" || fail 'initial geoip not installed'
printf 'custom newer data\n' > "$install_target/geoip.dat"
install_geodata_files "$install_target" "$work_dir/remote" || fail 'program upgrade data install failed'
[[ "$(cat "$install_target/geoip.dat")" == 'custom newer data' ]] || fail 'program update downgraded Geo data'
: > "$install_target/geosite.dat"
install_geodata_files "$install_target" "$work_dir/remote" || fail 'empty data could not be restored'
cmp -s "$install_target/geosite.dat" "$work_dir/remote/geosite.dat" || fail 'empty geosite not replaced'
if install_geodata_files "$work_dir/missing-package" "$work_dir/absent" 2>/dev/null; then fail 'missing package data was ignored'; fi

python3 - "$repo_dir" <<'PY'
from pathlib import Path
import sys
repo = Path(sys.argv[1])
manager = (repo / 'N2X.sh').read_text()
install = (repo / 'install.sh').read_text()
assert '"update") check_install 0 && update_command "${@:2}" ;;' in manager
assert 'source /usr/local/N2X/geodata.sh' in manager
assert 'outbound_unlock.sh geodata.sh; do' in manager
assert '"geodata.sh" \\\n        "/usr/local/N2X/geodata.sh"' in install
assert 'geodata_schedule_install' in install
assert '/usr/bin/N2X update geodata -r' not in install
assert '--no-check-certificate' not in (repo / 'geodata.sh').read_text()
PY
echo 'geodata_update_test: OK (download, checksum, rollback, Shanghai schedule, deferred restart, dispatch)'
