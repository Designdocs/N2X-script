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
    unset N2X_GEODATA_REVISION
    fault=none running=1
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
geodata_service_running() { [[ "$running" == 1 ]]; }
geodata_restart_service() {
    printf 'restart\n' >> "$case_dir/restarts"
    if [[ "$fault" == restart && "$(wc -l < "$case_dir/restarts" | tr -d ' ')" == 1 ]]; then return 1; fi
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
[[ "$(wc -l < "$case_dir/restarts" | tr -d ' ')" == 1 ]] || fail 'service not restarted once'
assert_clean
# Identical files do not disconnect users, even with -r.
geodata_update -r >> "$case_dir/log" 2>&1 || fail 'unchanged update failed'
[[ "$(wc -l < "$case_dir/restarts" | tr -d ' ')" == 1 ]] || fail 'unchanged data restarted service'

for scenario in api api_json partial missing_checksum checksum mismatch empty replace restart; do
    reset_case "$scenario"
    fault="$scenario"
    if geodata_update -r > "$case_dir/log" 2>&1; then fail "$scenario unexpectedly succeeded"; fi
    assert_old
    assert_clean
    if [[ "$scenario" == restart ]]; then
        [[ "$(wc -l < "$case_dir/restarts" | tr -d ' ')" == 2 ]] || fail 'rollback did not restart old data'
    else
        [[ ! -s "$case_dir/restarts" ]] || fail "$scenario restarted service"
    fi
done

reset_case download_only
geodata_update > "$case_dir/log" 2>&1 || fail 'download-only update failed'
[[ ! -s "$case_dir/restarts" ]] || fail 'update without -r restarted service'
reset_case stopped
running=0
geodata_update --restart > "$case_dir/log" 2>&1 || fail 'stopped-service update failed'
[[ ! -s "$case_dir/restarts" ]] || fail 'stopped service was started'

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

# Verify real command routing with functions extracted from the manager.
eval "$(awk '/^update_command\(\) \{$/,/^\}$/' "$repo_dir/N2X.sh")"
red='' plain=''
geodata_update() { printf 'geo'; printf ' <%s>' "$@"; printf '\n'; return 7; }
update() { printf 'program'; printf ' <%s>' "$@"; printf '\n'; }
if output="$(update_command geodata -r)"; then fail 'Geo failure exit code was lost'; else geo_exit_code=$?; fi
[[ "$geo_exit_code" == 7 && "$output" == 'geo <-r>' ]] || fail "Geo routing failed: $geo_exit_code / $output"
[[ "$(update_command v0.17.12 -r)" == 'program <0> <v0.17.12>' ]] || fail 'version update routing changed'
[[ "$(update_command -r)" == 'program <0> <>' ]] || fail 'monthly latest update interpreted -r as a version'

# A released update_shell may not fetch new modules: lazily install once.
bootstrap_body="$(awk '/^update_command\(\) \{$/,/^\}$/' "$repo_dir/N2X.sh")"
bootstrap_body="${bootstrap_body//\/usr\/local\/N2X/$work_dir/bootstrap}"
mkdir "$work_dir/bootstrap"
eval "$bootstrap_body"
unset -f geodata_update
download_managed_shell_file() {
    [[ "$1" == https://raw.githubusercontent.com/Designdocs/N2X-script/main/geodata.sh ]] || fail 'wrong bootstrap URL'
    printf '%s\n' 'geodata_update() { printf "bootstrapped <%s>\\n" "$*"; }' > "$2"
}
[[ "$(update_command geodata -r)" == 'bootstrapped <-r>' ]] || fail 'old manager upgrade did not bootstrap the Geo module'
download_managed_shell_file() { return 1; }
if update_command geodata -r > "$work_dir/bootstrap-failure.log" 2>&1; then fail 'bootstrap failure was swallowed'; fi

# Program installation supplies missing data and keeps newer/custom files.
eval "$(awk '/^install_geodata_files\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
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
assert install.count('ensure_cron_job "0 4 * * 6"') == 1
assert '/usr/bin/N2X update geodata -r' in install
assert '--no-check-certificate' not in (repo / 'geodata.sh').read_text()
PY
echo 'geodata_update_test: OK (download, checksum, rollback, restart, dispatch)'
