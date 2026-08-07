#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# config_gen.sh is the single generator; initconfig.sh and N2X.sh source it.
config_path="${repo_dir}/config_gen.sh"

grep -Fq '"CertDomain": "all.example.com"' "$config_path"
grep -Fq '"CertFile": "/etc/N2X/fullchain-{domain}.cer"' "$config_path"
grep -Fq '"KeyFile": "/etc/N2X/cert-{domain}.key"' "$config_path"

if grep -Fq '"CertFile": "/etc/N2X/fullchain.cer"' "$config_path"; then
    echo "legacy certificate path remains in config_gen.sh" >&2
    exit 1
fi
if grep -Fq '"KeyFile": "/etc/N2X/cert.key"' "$config_path"; then
    echo "legacy key path remains in config_gen.sh" >&2
    exit 1
fi

# The callers must not grow their own copy of the node block again.
for caller in initconfig.sh N2X.sh; do
    if grep -Fq '"CertFile": "/etc/N2X/fullchain-{domain}.cer"' "${repo_dir}/${caller}"; then
        echo "${caller} carries a duplicate node config block; it should call config_gen.sh" >&2
        exit 1
    fi
done

echo "certificate path defaults are aligned"
