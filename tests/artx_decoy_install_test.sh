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

printf '%s\n' 'N2X_ARTX_DECOY_LISTEN=127.0.0.1:61443' > "$env_path"
artx_decoy_ensure_env
grep -Fqx 'N2X_ARTX_DECOY_LISTEN=127.0.0.1:61443' "$env_path"

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
grep -Fq 'env_file="/etc/N2X/artx-decoy.env"' "$openrc_path"

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
assert '/etc/caddy/Caddyfile' not in (repo / "artx_decoy.sh").read_text()
PY
