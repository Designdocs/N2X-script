#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for generator in config_gen.sh initconfig.sh N2X.sh; do
    config_path="${repo_dir}/${generator}"

    for hint in _api_comment _traffic_comment _dns_comment _network_comment _paths_comment _provider_comment; do
        grep -Fq "\"${hint}\"" "$config_path"
    done

    grep -Fq 'NodeType 可填 shadowsocks/vless/vmess/trojan/anytls/artx' "$config_path"
    grep -Fq 'CertMode 可填 none/file/http/dns/self' "$config_path"
    grep -Fq '"ReportMinTraffic": 0' "$config_path"

    if grep -Fq '"MinReportTraffic"' "$config_path"; then
        echo "obsolete MinReportTraffic remains in ${generator}" >&2
        exit 1
    fi
done

for generator in initconfig.sh N2X.sh; do
    config_path="${repo_dir}/${generator}"
    grep -Fq '所有以 _comment 结尾或名为 _comment 的字段仅用于说明' "$config_path"
    grep -Fq 'handshake/connIdle/uplinkOnly/downlinkOnly 单位为秒；bufferSize 单位为 KB' "$config_path"
    grep -Fq 'Level 可填 debug/info/warning/error/none' "$config_path"
done

echo "generated config hints are aligned"
