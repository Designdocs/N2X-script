#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_path="${repo_dir}/config_gen.sh"

grep -Fq '"ReportMinTraffic": 0' "$config_path"

if grep -Eq '"(_comment|_[^"]+_comment)"' "$config_path"; then
    echo "inline config comments remain in config_gen.sh" >&2
    exit 1
fi

if grep -Fq '"MinReportTraffic"' "$config_path"; then
    echo "obsolete MinReportTraffic remains in config_gen.sh" >&2
    exit 1
fi

# The _help block lives in config_gen.sh; the callers only interpolate it.
grep -Fq 'config_help_block()' "$config_path"
grep -Fq 'CertMode 可填 none/file/http/dns/self' "$config_path"
grep -Fq 'handshake/connIdle/uplinkOnly/downlinkOnly 单位为秒；bufferSize 单位为 KB' "$config_path"
grep -Fq 'Level 可填 debug/info/warning/error/none' "$config_path"

# Both cores and every protocol they serve must be documented.
grep -Fq 'Type 可填 xray 或 sing' "$config_path"
grep -Fq 'xray 核心可填 shadowsocks/vless/vmess/trojan/anytls/artx' "$config_path"
for protocol in hysteria2 tuic shadowtls naive; do
    if ! grep -Fq "$protocol" "$config_path"; then
        echo "protocol ${protocol} is missing from the generated config hints" >&2
        exit 1
    fi
done
grep -Fq 'ShadowTLSOptions' "$config_path"
grep -Fq 'NaiveOptions' "$config_path"

for caller in initconfig.sh N2X.sh; do
    caller_path="${repo_dir}/${caller}"
    # The caller must interpolate the shared block, not inline its own.
    grep -Fq '$(config_help_block)' "$caller_path"
    grep -Fq '$(build_cores_config)' "$caller_path"
    if grep -Fq '"Cores.Type":' "$caller_path"; then
        echo "${caller} carries a duplicate _help block; it should call config_help_block" >&2
        exit 1
    fi
done

echo "generated config usage notes are aligned"
