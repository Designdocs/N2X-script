#!/usr/bin/env bash
# render_config.sh runs as N2X.service's ExecStartPre and pipes config.json
# through envsubst, which only ever substitutes $VAR patterns -- it has no
# opinion on whether the input is valid JSON. A syntax error in config.json
# used to surface only from deep inside N2X's own Go log, with no line
# number, because read_config_value's python step hits the same parse error
# and silently swallows it (by design, so it can fall back to .env). This
# test guards the up-front diagnostic that surfaces the same error, with a
# line/column, before that happens -- and that it does not change behavior
# for a config that actually is valid.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
cd "$work_dir"

cat > config_valid.json <<'JSON'
{
    "Log": {"Level": "error", "Output": ""},
    "Cores": [{"Type": "sing"}],
    "Nodes": [{
        "Core": "sing",
        "ApiHost": "${N2X_API_HOST}",
        "ApiKey": "k",
        "NodeID": 1,
        "NodeType": "hysteria"
    }]
}
JSON

# Missing comma between "EnableTFO": true and "CertConfig" -- the same class
# of error reported against a live deployment: valid-looking JSON to the eye,
# but Go's json.Unmarshal rejects it with no position information at all.
cat > config_broken.json <<'JSON'
{
    "Log": {"Level": "error", "Output": ""},
    "Cores": [{"Type": "sing"}],
    "Nodes": [{
        "Core": "sing",
        "ApiHost": "x",
        "ApiKey": "k",
        "NodeID": 1,
        "NodeType": "hysteria",
        "EnableTFO": true
        "CertConfig": {"CertMode": "none"}
    }]
}
JSON

run_render() {
    local config="$1" out="$2" err="$3"
    CONFIG_PATH="./$config" ENV_PATH=./missing.env OUTPUT_PATH="./$out" \
        bash "${repo_dir}/render_config.sh" 2>"$err"
}

# A valid config must render silently -- no spurious diagnostic noise.
run_render config_valid.json out_valid.json stderr_valid.log
if [[ -s stderr_valid.log ]]; then
    echo "FAIL: valid config produced unexpected stderr output:" >&2
    cat stderr_valid.log >&2
    exit 1
fi
if [[ ! -s out_valid.json ]]; then
    echo "FAIL: valid config did not produce a rendered output file" >&2
    exit 1
fi

# A broken config must get one clear diagnostic line naming the file and a
# position, and render_config.sh must still exit 0 and still write an output
# file -- N2X's own loader is the thing that actually refuses to start on
# broken config; this script only adds a diagnostic ahead of that, it does
# not change the pass-through behavior.
run_render config_broken.json out_broken.json stderr_broken.log
if ! grep -q "config_broken.json is not valid JSON" stderr_broken.log; then
    echo "FAIL: broken config did not produce the expected diagnostic:" >&2
    cat stderr_broken.log >&2
    exit 1
fi
if ! grep -qE 'line [0-9]+ column [0-9]+' stderr_broken.log; then
    echo "FAIL: diagnostic did not include a line/column position:" >&2
    cat stderr_broken.log >&2
    exit 1
fi
if [[ ! -s out_broken.json ]]; then
    echo "FAIL: adding the diagnostic must not stop render_config.sh from writing its output (N2X's own error is still the one that blocks startup)" >&2
    exit 1
fi

echo "render_config.sh surfaces invalid JSON with a position and stays a no-op otherwise"
