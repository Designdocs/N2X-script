#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_dir}/config_gen.sh"

core_xray=true
core_sing=true
generated_cores="$(build_cores_config)"
GENERATED_CORES="$generated_cores" python3 - "$repo_dir" <<'PY'
import json
import os
from pathlib import Path
import re
import sys

repo = Path(sys.argv[1])
cores = json.loads(os.environ['GENERATED_CORES'])
generated = next(core for core in cores if core['Type'] == 'xray')['ConnectionConfig']
program_repo = repo.parent / 'N2X'
# This repository can be tested alone. Also compare the program/example when
# the usual sibling checkout is available.
has_program = (program_repo / 'conf/xray.go').is_file()
if has_program:
    example = json.loads((program_repo / 'example/config.json').read_text())
    example = next(core for core in example['Cores'] if core['Type'] == 'xray')['ConnectionConfig']
    source = (program_repo / 'conf/xray.go').read_text()
for key, field, expected in [('connIdle', 'ConnIdle', 300),
                             ('handshake', 'Handshake', 4),
                             ('uplinkOnly', 'UplinkOnly', 2),
                             ('downlinkOnly', 'DownlinkOnly', 5)]:
    assert generated[key] == expected, key
    if has_program:
        match = re.search(r'\b' + field + r':\s*(\d+)', source)
        assert match, f'missing program default {field}'
        assert int(match.group(1)) == example[key] == expected, key
print('connection defaults verified' + (' against program and example' if has_program else ''))
PY
