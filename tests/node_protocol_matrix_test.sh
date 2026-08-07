#!/usr/bin/env bash
# Drives config_gen.sh for every protocol in the menu and checks that what it
# emits is valid JSON carrying the right NodeType, Core and CertMode. The
# grep-based tests only prove the strings exist somewhere in the file; this one
# proves the wizard actually produces a usable node.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# check_ipv6_support shells out to `ip`, which is absent on macOS and in
# minimal containers. Stub it so the matrix runs anywhere.
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
cat >"${stub_dir}/ip" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "${stub_dir}/ip"
PATH="${stub_dir}:${PATH}"

# shellcheck source=../config_gen.sh
source "${repo_dir}/config_gen.sh"

red="" green="" yellow="" plain=""
api_host_val='${N2X_API_HOST}'
api_key_val='${N2X_API_KEY}'
custom_dns_enabled=false

# choice | expected NodeType | expected Core | expected CertMode | wizard input
#
# The wizard input is the dialogue after the node id, one answer per ';'.
# Protocols that force TLS skip the "是否进行TLS配置" question and go straight
# to the cert-mode menu (1 = http); vless asks about reality first; shadowtls
# needs no certificate and asks for its handshake target instead.
matrix=(
    "1|shadowsocks|xray|http|1;y;1"
    "2|vless|xray|none|2;n;n"
    "3|vmess|xray|http|3;y;1"
    "4|trojan|xray|http|4;y;1"
    "5|anytls|xray|http|5;1"
    "6|artx|xray|http|6;1"
    "7|anytls|sing|http|7;1"
    "8|hysteria|sing|http|8;1"
    "9|tuic|sing|http|9;1"
    "10|shadowtls|sing|none|10;"
    "11|naive|sing|http|11;1"
)

# Feeds a ';'-separated dialogue to add_node_config.
#
# `read` returns non-zero at EOF, which under `set -e` would abort the run, so
# the call is unguarded here; correctness is asserted on the emitted JSON
# instead, which catches a prompt that consumed the wrong answer.
run_wizard() {
    local node_id="$1" dialogue="$2" input
    input=$(printf '%s\n' "$node_id"; printf '%s\n' "$dialogue" | tr ';' '\n')
    set +e
    add_node_config >/dev/null 2>&1 <<<"$input"
    set -e
}

failures=0
for row in "${matrix[@]}"; do
    IFS='|' read -r choice want_type want_core want_cert wizard_input <<<"$row"

    nodes_config=()
    core_xray=false
    core_sing=false

    run_wizard 4242 "$wizard_input"

    if (( ${#nodes_config[@]} == 0 )); then
        echo "FAIL choice ${choice} (${want_type}): the wizard produced no node" >&2
        failures=$((failures + 1))
        continue
    fi

    # add_node_config emits a trailing comma so nodes concatenate; strip it.
    node_json="${nodes_config[0]%,}"

    # Regression check for a bug json.load cannot see: command substitution
    # strips trailing newlines, so two heredoc blocks concatenated directly
    # against literal text can glue onto one line (e.g. "EnableTFO": true,
    # "CertConfig": {) while staying perfectly valid, whitespace-insensitive
    # JSON. Check the raw layout instead: CertConfig must start its own line.
    if ! printf '%s\n' "$node_json" | grep -qE '^ {12}"CertConfig": \{$'; then
        echo "FAIL choice ${choice}: \"CertConfig\" is not on its own line (a heredoc/command-substitution newline got eaten)" >&2
        printf '%s\n' "$node_json" >&2
        failures=$((failures + 1))
    fi

    if ! result=$(printf '%s' "$node_json" | python3 -c '
import json, sys
n = json.load(sys.stdin)
print(n["NodeType"], n["Core"], n["CertConfig"]["CertMode"], n["NodeID"])
' 2>&1); then
        echo "FAIL choice ${choice} (${want_type}): invalid JSON" >&2
        echo "$result" >&2
        printf '%s\n' "$node_json" >&2
        failures=$((failures + 1))
        continue
    fi

    read -r got_type got_core got_cert got_id <<<"$result"

    if [[ "$got_type" != "$want_type" || "$got_core" != "$want_core" || "$got_cert" != "$want_cert" || "$got_id" != "4242" ]]; then
        echo "FAIL choice ${choice}: got ${got_type}/${got_core}/${got_cert}/id=${got_id}, want ${want_type}/${want_core}/${want_cert}/id=4242" >&2
        failures=$((failures + 1))
        continue
    fi

    # The core flags drive which Cores entries get written.
    if [[ "$want_core" == "sing" && "$core_sing" != true ]]; then
        echo "FAIL choice ${choice}: sing protocol did not set core_sing" >&2
        failures=$((failures + 1))
    fi
    if [[ "$want_core" == "xray" && "$core_xray" != true ]]; then
        echo "FAIL choice ${choice}: xray protocol did not set core_xray" >&2
        failures=$((failures + 1))
    fi

    # Protocol-specific option blocks must be present, and must not leak into
    # protocols that do not understand them.
    case "$want_type" in
        shadowtls )
            printf '%s' "$node_json" | python3 -c '
import json, sys
n = json.load(sys.stdin)
assert "ShadowTLSOptions" in n, "shadowtls node is missing ShadowTLSOptions"
' || { echo "FAIL choice ${choice}: missing ShadowTLSOptions" >&2; failures=$((failures + 1)); }
            ;;
        naive )
            printf '%s' "$node_json" | python3 -c '
import json, sys
n = json.load(sys.stdin)
assert "NaiveOptions" in n, "naive node is missing NaiveOptions"
' || { echo "FAIL choice ${choice}: missing NaiveOptions" >&2; failures=$((failures + 1)); }
            ;;
        * )
            printf '%s' "$node_json" | python3 -c '
import json, sys
n = json.load(sys.stdin)
for key in ("ShadowTLSOptions", "NaiveOptions"):
    assert key not in n, key + " leaked into an unrelated protocol"
' || { echo "FAIL choice ${choice}: protocol option leaked" >&2; failures=$((failures + 1)); }
            ;;
    esac

    # xray-only and sing-only knobs must not cross over.
    printf '%s' "$node_json" | python3 -c "
import json, sys
n = json.load(sys.stdin)
core = '${want_core}'
if core == 'sing':
    for key in ('EnableDNS', 'DNSType', 'EnableProxyProtocol', 'EnableUot'):
        assert key not in n, key + ' is an xray-only option but appeared on a sing node'
    assert n['EnableSniff'] is True
else:
    assert 'EnableSniff' not in n, 'EnableSniff is a sing-only option but appeared on an xray node'
    assert 'DNSType' in n
" || { echo "FAIL choice ${choice}: core option crossover" >&2; failures=$((failures + 1)); }
done

# Cores array: each combination must be valid JSON with exactly the right cores.
check_cores() {
    local xray="$1" sing="$2" want="$3"
    core_xray="$xray"
    core_sing="$sing"
    local got
    got=$(build_cores_config | python3 -c '
import json, sys
print(",".join(c["Type"] for c in json.load(sys.stdin)))
') || { echo "FAIL cores(xray=$xray sing=$sing): invalid JSON" >&2; failures=$((failures + 1)); return; }
    if [[ "$got" != "$want" ]]; then
        echo "FAIL cores(xray=$xray sing=$sing): got '${got}', want '${want}'" >&2
        failures=$((failures + 1))
    fi
}
check_cores true false "xray"
check_cores false true "sing"
check_cores true true "xray,sing"

# The full document, _help block included, must parse.
core_xray=true
core_sing=true
nodes_config=()
run_wizard 4242 "8;1"
run_wizard 4243 "10;"
nodes_str="${nodes_config[*]}"
full_config=$(cat <<EOF
{
    "Log": {
        "Level": "error",
        "Output": ""
    },
    "Cores": $(build_cores_config),
    "Nodes": [${nodes_str%,}],
    "_help": {
$(config_help_block)
    }
}
EOF
)
if ! printf '%s' "$full_config" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert [c["Type"] for c in d["Cores"]] == ["xray", "sing"], d["Cores"]
assert [n["NodeType"] for n in d["Nodes"]] == ["hysteria", "shadowtls"], d["Nodes"]
assert d["_help"]["Nodes.NodeType"]
' 2>&1; then
    echo "FAIL: assembled config.json is not valid" >&2
    printf '%s\n' "$full_config" >&2
    failures=$((failures + 1))
fi

if (( failures > 0 )); then
    echo "${failures} protocol matrix check(s) failed" >&2
    exit 1
fi

echo "node protocol matrix is aligned (11 protocols, 2 cores)"
