#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_dir" <<'PY'
from pathlib import Path
import sys

repo = Path(sys.argv[1])
install = (repo / "install.sh").read_text()
manager = (repo / "N2X.sh").read_text()

install_flow = install[install.index("install_N2X() {"):install.index('\necho -e "${green}开始安装${plain}"')]
first_install = install_flow.index("if [[ ! -f /etc/N2X/config.json ]]; then")
existing_install = install_flow.index("\n    else\n", first_install)
env_setup = install_flow.index("ensure_env_file")
assert first_install < env_setup < existing_install, (
    "ensure_env_file must run only inside the first-install branch"
)

generate_flow = manager[manager.index("generate_config_file() {"):manager.index("\n# 放开防火墙端口")]
assert "ensure_env_file" not in generate_flow
assert "manage_env_file" not in generate_flow
PY
