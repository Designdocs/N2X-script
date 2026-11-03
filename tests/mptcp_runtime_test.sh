#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
cp "$repo_dir/run.sh" "$fixture_root/run.sh"
cat > "$fixture_root/N2X" <<'SH'
#!/bin/sh
printf '%s\n' "$GODEBUG"
printf '<%s>\n' "$@"
exit 23
SH
chmod +x "$fixture_root/N2X"
for inherited in '' 'tlssha1=1' 'multipathtcp=1,http2server=0' 'multipathtcp=2,multipathtcp=1'; do
    set +e
    output="$(GODEBUG="$inherited" sh "$fixture_root/run.sh" server 'argument with spaces')"
    result=$?
    set -e
    [[ "$result" == 23 ]]
    expected="${inherited:+${inherited},}multipathtcp=0"
    [[ "$output" == "$expected"$'\n<server>\n<argument with spaces>' ]]
done

# Validate generated main-service startup paths without executing the installer.
python3 - "$repo_dir" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
install = (root / 'install.sh').read_text()
assert '"run.sh" \\\n        "/usr/local/N2X/run.sh"' in install
assert 'ExecStart=/bin/sh /usr/local/N2X/run.sh server' in install
assert 'command_args="/usr/local/N2X/run.sh server"' in install
assert 'ExecStart=/bin/sh /usr/local/N2X/run.sh server' in (root / 'N2X.service').read_text()
PY
echo 'mptcp_runtime_test: OK'
