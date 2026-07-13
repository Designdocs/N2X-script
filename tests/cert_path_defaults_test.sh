#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for config_generator in config_gen.sh initconfig.sh N2X.sh; do
    config_path="${repo_dir}/${config_generator}"
    grep -Fq '"CertDomain": "all.example.com"' "$config_path"
    grep -Fq '"CertFile": "/etc/N2X/fullchain-{domain}.cer"' "$config_path"
    grep -Fq '"KeyFile": "/etc/N2X/cert-{domain}.key"' "$config_path"

    if grep -Fq '"CertFile": "/etc/N2X/fullchain.cer"' "$config_path"; then
        echo "legacy certificate path remains in ${config_generator}" >&2
        exit 1
    fi
    if grep -Fq '"KeyFile": "/etc/N2X/cert.key"' "$config_path"; then
        echo "legacy key path remains in ${config_generator}" >&2
        exit 1
    fi
done

echo "certificate path defaults are aligned"
