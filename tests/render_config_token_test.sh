#!/usr/bin/env bash
# Exercise the service's real renderer with scoped tokens and legacy configs.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v envsubst >/dev/null || { echo "envsubst is required" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/config.json" <<'JSON'
{
  "Nodes": [{
    "CertConfig": {
      "Provider": "cloudflare",
      "Email": "ops@example.com",
      "DNSEnv": {"CF_DNS_API_TOKEN": "${CF_DNS_API_TOKEN}"}
    }
  }]
}
JSON
cat > "$work_dir/token.env" <<'ENV'
export CF_DNS_API_TOKEN='scoped-token-from-file'
ENV

run_render() {
    env -i PATH="$PATH" CONFIG_PATH="$work_dir/config.json" \
        ENV_PATH="$work_dir/$1" OUTPUT_PATH="$work_dir/rendered.json" \
        CF_DNS_API_TOKEN=process-token sh "$repo_dir/render_config.sh"
}

assert_token() {
    python3 - "$work_dir/rendered.json" "$1" <<'PY'
import json, stat, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
for node in data["Nodes"]:
    cert = node["CertConfig"]
    assert cert["DNSEnv"] == {"CF_DNS_API_TOKEN": sys.argv[2]}, "wrong token rendered"
    assert cert["Email"] == "ops@example.com", "ACME email changed"
assert stat.S_IMODE(path.stat().st_mode) == 0o600, "rendered config must be private"
PY
}

# .env must be loaded even though envsubst accepts only an explicit allowlist.
run_render token.env
assert_token scoped-token-from-file

# A process variable remains usable without an env file.
run_render missing.env
assert_token process-token

# Literal config values take precedence over .env for subsequent placeholders.
# This exercises reading through Nodes[0], including its array index.
python3 - "$work_dir/config.json" <<'PY'
import copy, json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["Nodes"].append(copy.deepcopy(data["Nodes"][0]))
data["Nodes"][0]["CertConfig"]["DNSEnv"]["CF_DNS_API_TOKEN"] = "config-token"
path.write_text(json.dumps(data))
PY
run_render token.env
assert_token config-token

# Existing Global API Key deployments must still render during migration.
cat > "$work_dir/config.json" <<'JSON'
{"Nodes":[{"CertConfig":{"DNSEnv":{
  "CF_API_KEY":"${CF_API_KEY}","CLOUDFLARE_EMAIL":"${CLOUDFLARE_EMAIL}"
}}}]}
JSON
cat > "$work_dir/legacy.env" <<'ENV'
CF_API_KEY=legacy-test-key
CLOUDFLARE_EMAIL=legacy@example.com
ENV
run_render legacy.env
python3 - "$work_dir/rendered.json" <<'PY'
import json, sys
env = json.load(open(sys.argv[1]))["Nodes"][0]["CertConfig"]["DNSEnv"]
assert env == {"CF_API_KEY": "legacy-test-key", "CLOUDFLARE_EMAIL": "legacy@example.com"}
PY

cat > "$work_dir/config.json" <<'JSON'
{"Nodes":[{"DDNSConfig":{"Enabled":true,"Provider":"alidns","DNSEnv":{
  "ALICLOUD_ACCESS_KEY":"${ALICLOUD_ACCESS_KEY}",
  "ALICLOUD_SECRET_KEY":"${ALICLOUD_SECRET_KEY}",
  "ALICLOUD_SECURITY_TOKEN":"${ALICLOUD_SECURITY_TOKEN}"
}}}]}
JSON
cat > "$work_dir/alidns.env" <<'ENV'
ALICLOUD_ACCESS_KEY=ram-test-key
ALICLOUD_SECRET_KEY='ram-test-secret'
ALICLOUD_SECURITY_TOKEN=temporary-test-token
ENV
run_render alidns.env
python3 - "$work_dir/rendered.json" <<'PY'
import json, sys
env = json.load(open(sys.argv[1]))["Nodes"][0]["DDNSConfig"]["DNSEnv"]
assert env == {"ALICLOUD_ACCESS_KEY": "ram-test-key", "ALICLOUD_SECRET_KEY": "ram-test-secret", "ALICLOUD_SECURITY_TOKEN": "temporary-test-token"}
PY

echo "Cloudflare/Alibaba DNS credentials, precedence and legacy compatibility passed"
