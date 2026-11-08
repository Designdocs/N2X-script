#!/usr/bin/env bash
# Run the real installer up to its first possible service stop, without network.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
source "$repo_dir/geodata.sh"
eval "$(awk '/^scheduled_release_is_newer\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
eval "$(awk '/^download_verified_release\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
eval "$(awk '/^install_N2X\(\) \{$/ { inside=1 } /^echo -e.*开始安装/ { exit } inside { print }' "$repo_dir/install.sh")"

export TEST_TRACE="$work_dir/trace"
export N2X_BIN="$work_dir/installed"
printf '%s\n' '#!/bin/sh' 'printf "N2X v0.17.10\n"' > "$N2X_BIN"
printf '%s\n' '#!/bin/sh' '[ "$1" = check ] && echo checked >> "$TEST_TRACE"' > "$work_dir/candidate"
chmod +x "$N2X_BIN" "$work_dir/candidate"
printf 'package\n' > "$work_dir/fixture.zip"
printf 'SHA2-256= %s\n' "$(geodata_sha256 "$work_dir/fixture.zip")" > "$work_dir/fixture.dgst"

SCRIPT_DIR="$repo_dir"
release=debian
scheduled_day=2026-08-01
fake_clock="$scheduled_day 0400"
maintenance_clock() { printf '%s\n' "$fake_clock"; }
log_info() { :; }
log_warn() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
curl() { printf '{ "tag_name": "%s" }\n' "$latest"; }
pick_asset_suffix() { printf 'linux-64\n'; }
download_file() {
    printf 'download\n' >> "$TEST_TRACE"
    case "$1" in
        *.zip) cp "$work_dir/fixture.zip" "$2" ;;
        *.dgst) cp "$work_dir/fixture.dgst" "$2" ;;
        *) fail "unexpected download: $1" ;;
    esac
}
unzip() { cp "$work_dir/candidate" "$4/N2X"; }
prepare_release_tree() { [[ -x "$1/N2X" ]]; }
stage_scheduled_support() { printf 'staged\n' >> "$TEST_TRACE"; }
geodata_service_instance() { printf 'boot 101 1\n'; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TEST_TRACE"; }
swap_installation_dir() { fail 'unexpected installation switch'; }

latest=v0.17.10
: > "$TEST_TRACE"
(install_N2X) || fail 'same version should skip successfully'
[[ ! -s "$TEST_TRACE" ]] || fail 'same version downloaded a release or touched the service'

latest=v0.17.11
(install_N2X) || fail 'late verified release should skip successfully'
[[ "$(cat "$TEST_TRACE")" == $'download\ndownload\nchecked\nstaged' ]] || fail 'late release stopped the running service'

: > "$TEST_TRACE"
printf 'SHA2-256= invalid\n' > "$work_dir/fixture.dgst"
if (install_N2X) 2> "$work_dir/rejected"; then fail 'bad checksum was accepted'; fi
[[ "$(cat "$TEST_TRACE")" == $'download\ndownload' ]] || fail 'unverified release reached config checks or service management'
echo 'scheduled_program_update_test: OK'
