#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT
cd -- "$work_dir"
eval "$(awk '/^download_file\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
eval "$(awk '/^download_verified_release\(\) \{$/,/^\}$/' "$repo_dir/install.sh")"
eval "$(awk '/^run_initial_config_wizard\(\) \($/,/^\)$/' "$repo_dir/install.sh")"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
printf 'dummy release\n' > archive.fixture
digest="$(sha256sum archive.fixture)"
digest="${digest%% *}"
mode=ok
curl() {
    [[ "$1" == -q && "$2" == --proto && "$3" == '=https' &&
        "$4" == --proto-redir && "$5" == '=https' ]] || fail "HTTPS policy missing"
    local output=""
    while [[ $# -gt 1 ]]; do
        if [[ "$1" == -o ]]; then
            output="$2"
            shift
        fi
        shift
    done
    [[ -n "$output" ]] || fail "output path missing"
    case "$1" in
        *.zip) cp archive.fixture "$output" ;;
        *.dgst)
            case "$mode" in
                missing) return 1 ;;
                wrong) printf 'SHA2-256= %064d\n' 0 > "$output" ;;
                *) printf 'SHA2-256= %s\n' "$digest" > "$output" ;;
            esac
            ;;
        */initconfig.sh)
            [[ "$mode" == ok ]] || return 1
            printf '%s\n' 'generate_config_file() { printf "trusted fixture\n"; }' > "$output"
            ;;
        *) fail "unexpected URL" ;;
    esac
}

url=https://release.invalid/N2X.zip
download_verified_release "$url" accepted.zip || fail "valid release was refused"
cmp archive.fixture accepted.zip
for mode in missing wrong; do
    if download_verified_release "$url" rejected.zip; then
        fail "unverified release was accepted ($mode)"
    fi
done
if download_file http://release.invalid/N2X.zip rejected.zip; then
    fail "plain HTTP was accepted"
fi

printf '%s\n' 'generate_config_file() { printf "untrusted working-directory fixture\n"; }' > initconfig.sh
mode=missing
if output="$(run_initial_config_wizard)"; then
    fail "wizard continued after download failed: $output"
fi
mode=ok
[[ "$(run_initial_config_wizard)" == 'trusted fixture' ]] || fail "freshly downloaded wizard did not run"
[[ -f initconfig.sh ]] || fail "installer changed the caller's file"
printf 'install_trust_test: OK\n'
