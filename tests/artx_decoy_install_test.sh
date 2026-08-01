#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

export ARTX_DECOY_ROOT="$fixture_root"
export ARTX_DECOY_SKIP_SERVICE_ACTIONS=1

# shellcheck source=../artx_decoy.sh
source "$repo_dir/artx_decoy.sh"

artx_decoy_ensure_env
env_path="$fixture_root/etc/N2X/artx-decoy.env"
grep -Fqx 'N2X_ARTX_DECOY_LISTEN=127.0.0.1:60443' "$env_path"
grep -Fqx 'N2X_ARTX_DECOY_PROFILE=balanced' "$env_path"

printf '%s\n' 'N2X_ARTX_DECOY_LISTEN=127.0.0.1:61443' > "$env_path"
artx_decoy_ensure_env
grep -Fqx 'N2X_ARTX_DECOY_LISTEN=127.0.0.1:61443' "$env_path"
if grep -Fq 'N2X_ARTX_DECOY_PROFILE' "$env_path"; then
    echo 'ensure_env must not rewrite an existing env file' >&2
    exit 1
fi

artx_decoy_install_service systemd
unit_path="$fixture_root/etc/systemd/system/N2X-artx-decoy.service"
grep -Fq 'EnvironmentFile=-/etc/N2X/artx-decoy.env' "$unit_path"
grep -Fq 'ExecStart=/usr/local/N2X/N2X decoy serve' "$unit_path"
if grep -Fq '60443' "$unit_path"; then
    echo 'systemd unit must not hardcode the default port' >&2
    exit 1
fi

artx_decoy_install_service alpine
openrc_path="$fixture_root/etc/init.d/N2X-artx-decoy"
grep -Fq 'command_args="decoy serve"' "$openrc_path"
grep -Fq 'start_pre()' "$openrc_path"
if grep -Fq 'env_file=' "$openrc_path"; then
    echo 'OpenRC must explicitly export the decoy environment' >&2
    exit 1
fi

# The generated OpenRC loader accepts a path only for fixture execution. OpenRC
# calls it without arguments and therefore uses /etc/N2X/artx-decoy.env.
# shellcheck disable=SC1090
source "$openrc_path"
unset N2X_ARTX_DECOY_LISTEN
start_pre "$env_path"
[[ "$N2X_ARTX_DECOY_LISTEN" == '127.0.0.1:61443' ]]
unset N2X_ARTX_DECOY_LISTEN
start_pre "$fixture_root/missing-decoy.env"
[[ -z "${N2X_ARTX_DECOY_LISTEN:-}" ]]

# systemd reads the whole env file, but OpenRC only gets what start_pre
# exports, so the profile has to be exported there too or Alpine nodes would
# silently ignore it.
printf '%s\n' \
    'N2X_ARTX_DECOY_LISTEN=127.0.0.1:61443' \
    'N2X_ARTX_DECOY_PROFILE=media' > "$env_path"
unset N2X_ARTX_DECOY_LISTEN N2X_ARTX_DECOY_PROFILE
start_pre "$env_path"
[[ "$N2X_ARTX_DECOY_LISTEN" == '127.0.0.1:61443' ]]
[[ "$N2X_ARTX_DECOY_PROFILE" == 'media' ]]

unset N2X_ARTX_DECOY_LISTEN N2X_ARTX_DECOY_PROFILE
printf '%s\n' 'N2X_ARTX_DECOY_LISTEN=127.0.0.1:61443' > "$env_path"
start_pre "$env_path"
[[ -z "${N2X_ARTX_DECOY_PROFILE:-}" ]]

eerror() { :; }
printf '%s\n' \
    'N2X_ARTX_DECOY_LISTEN=127.0.0.1:61443' \
    'N2X_ARTX_DECOY_LISTEN=127.0.0.1:62443' > "$env_path"
unset N2X_ARTX_DECOY_LISTEN
if start_pre "$env_path"; then
    echo 'OpenRC loader must reject duplicate decoy listen values' >&2
    exit 1
fi
printf '%s\n' 'N2X_ARTX_DECOY_LISTEN=127.0.0.1:61443' > "$env_path"

service_log="$fixture_root/service-actions.log"
systemctl() {
    printf '%s\n' "$*" >> "$service_log"
}
curl() {
    printf '%s\n' "curl $*" >> "$service_log"
}
export -f systemctl curl

ARTX_DECOY_SKIP_SERVICE_ACTIONS=0
artx_decoy_restart systemd
[[ "$(sed -n '1p' "$service_log")" == 'restart N2X-artx-decoy' ]]
[[ "$(sed -n '2p' "$service_log")" == curl*'http://127.0.0.1:61443/'* ]]
[[ "$(sed -n '3p' "$service_log")" == 'restart N2X' ]]

: > "$service_log"
service() {
    printf '%s\n' "$*" >> "$service_log"
}
export -f service
artx_decoy_restart alpine
[[ "$(sed -n '1p' "$service_log")" == 'N2X-artx-decoy restart' ]]
[[ "$(sed -n '2p' "$service_log")" == curl*'http://127.0.0.1:61443/'* ]]
[[ "$(sed -n '3p' "$service_log")" == 'N2X restart' ]]

health_attempts=0
curl() {
    health_attempts=$((health_attempts + 1))
    echo 'transient curl failure' >&2
    ((health_attempts >= 3))
}
sleep() {
    :
}
export -f curl sleep
health_error_log="$fixture_root/health-error.log"
artx_decoy_health 2> "$health_error_log"
[[ "$health_attempts" -eq 3 ]]
[[ ! -s "$health_error_log" ]]

: > "$service_log"
health_attempts=0
curl() {
    health_attempts=$((health_attempts + 1))
    echo 'persistent curl failure' >&2
    return 1
}
export -f curl
if artx_decoy_restart systemd 2> "$health_error_log"; then
    echo 'restart must fail when the decoy never becomes healthy' >&2
    exit 1
fi
[[ "$health_attempts" -eq 20 ]]
[[ "$(grep -Fc '诱饵 Web 服务在 http://127.0.0.1:61443/ 未通过健康检查' "$health_error_log")" -eq 1 ]]
[[ "$(grep -Fc 'restart N2X-artx-decoy' "$service_log")" -eq 1 ]]
if grep -Fxq 'restart N2X' "$service_log"; then
    echo 'N2X must not restart after an unhealthy decoy restart' >&2
    exit 1
fi

artx_decoy_uninstall systemd
[[ ! -e "$unit_path" ]]
[[ -e "$env_path" ]]

python3 - "$repo_dir" <<'PY'
from pathlib import Path
import sys

repo = Path(sys.argv[1])
install = (repo / "install.sh").read_text()
manager = (repo / "N2X.sh").read_text()

assert 'EnvironmentFile=-/etc/N2X/artx-decoy.env' in install
assert 'artx_decoy_install_service "$release"' in install
assert '"artx_decoy.sh"' in install
assert '"decoy") decoy_command' in manager
assert 'main/artx_decoy.sh' in manager[manager.index("update_shell() {"):]
assert install.count('start_pre()') >= 1, "main OpenRC service must load the decoy env"
assert "cat <<'EOF' > /etc/init.d/N2X" in install
assert 'env_file="/etc/N2X/artx-decoy.env"' not in install
assert '--no-check-certificate' not in install[install.index('install_managed_shell_file() {'):install.index('install_support_scripts() {')]
update_shell = manager[manager.index("update_shell() {"):manager.index("\n# 0: running")]
assert '--no-check-certificate' not in update_shell
assert update_shell.count('download_managed_shell_file') == 2
assert '/etc/caddy/Caddyfile' not in (repo / "artx_decoy.sh").read_text()
PY
