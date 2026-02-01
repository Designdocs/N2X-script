#!/bin/sh
# Generate /run/N2X/config.json with fallback when .env is missing or invalid.
# Priority: explicit values inside config.json (non-template) > /etc/N2X/.env > empty.

set -e

CONFIG_PATH="${CONFIG_PATH:-/etc/N2X/config.json}"
ENV_PATH="${ENV_PATH:-/etc/N2X/.env}"
OUTPUT_PATH="${OUTPUT_PATH:-/run/N2X/config.json}"

# shellcheck disable=SC3043
tmpdir="$(dirname "$OUTPUT_PATH")"
mkdir -p "$tmpdir"

# Load env file if present (may set baseline defaults)
if [ -f "$ENV_PATH" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_PATH" || true
  set +a
fi

read_config_value() {
  # $1: logical key (ApiHost|ApiKey|CertDomain|CertProvider|CertEmail|CF_API_KEY|CLOUDFLARE_EMAIL)
  python3 - "$CONFIG_PATH" "$1" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(0)

def pick(obj, chain):
    for k in chain:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(k)
    return obj

chains = {
    "ApiHost": ("Nodes", 0, "ApiHost"),
    "ApiKey": ("Nodes", 0, "ApiKey"),
    "CertDomain": ("Nodes", 0, "CertConfig", "CertDomain"),
    "CertProvider": ("Nodes", 0, "CertConfig", "Provider"),
    "CertEmail": ("Nodes", 0, "CertConfig", "Email"),
    "CF_API_KEY": ("Nodes", 0, "CertConfig", "DNSEnv", "CF_API_KEY"),
    "CLOUDFLARE_EMAIL": ("Nodes", 0, "CertConfig", "DNSEnv", "CLOUDFLARE_EMAIL"),
}

chain = chains.get(key)
if not chain:
    sys.exit(0)

value = pick(data, chain)
if isinstance(value, str) and "$" not in value and value.strip():
    print(value.strip())
PY
}

set_env_if_config_prefers() {
  var="$1"; key="$2"
  cfg_val="$(read_config_value "$key")"
  if [ -n "$cfg_val" ]; then
    export "$var"="$cfg_val"
    return
  fi
  current="$(eval "echo \${$var}")"
  if [ -z "$current" ]; then
    export "$var"=""
  fi
}

set_env_if_config_prefers "N2X_API_HOST" "ApiHost"
set_env_if_config_prefers "N2X_API_KEY" "ApiKey"
set_env_if_config_prefers "N2X_CERT_DOMAIN" "CertDomain"
set_env_if_config_prefers "N2X_CERT_PROVIDER" "CertProvider"
set_env_if_config_prefers "N2X_CERT_EMAIL" "CertEmail"
set_env_if_config_prefers "CF_API_KEY" "CF_API_KEY"
set_env_if_config_prefers "CLOUDFLARE_EMAIL" "CLOUDFLARE_EMAIL"

# Render final config; envsubst will leave placeholders empty if still unset.
envsubst '$N2X_API_HOST $N2X_API_KEY $N2X_CERT_DOMAIN $N2X_CERT_PROVIDER $N2X_CERT_EMAIL $CF_API_KEY $CLOUDFLARE_EMAIL' <"$CONFIG_PATH" >"$OUTPUT_PATH"

chmod 600 "$OUTPUT_PATH" 2>/dev/null || true
