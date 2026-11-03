#!/usr/bin/env bash
# 使用临时配置验证整段删除、精确匹配、无改动分支和服务重启接线。
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_dir" "$BASH" <<'PY'
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
bash = sys.argv[2]
manager = (repo / 'N2X.sh').read_text()
wrapper = re.search(r'^delete_node_config\(\) \{\n.*?^\}\n', manager, re.M | re.S).group(0)
assert '23.${plain} 删除节点' in manager
assert '23) delete_node_config ;;' in manager
assert '24) exit ;;' in manager and '[0-24]' in manager
assert '"delnode"|"delete_node") delete_node_config 0 ;;' in manager
assert 'N2X delnode' in manager

original = {
    'Log': {'Level': 'warn', 'Output': '/var/log/custom.log'},
    'Cores': [{'Type': 'xray', 'ConnectionConfig': {'bufferSize': 999}},
              {'Type': 'sing', 'NTP': {'Enable': True}}],
    'Nodes': [
        {'Core': 'xray', 'NodeID': 219, 'NodeType': 'anytls',
         'ApiHost': '${N2X_API_HOST}', 'ApiKey': 'secret-never-display',
         'WebSocket': {'Enabled': True, 'URL': 'wss://example.com/219'},
         'CertConfig': {'CertDomain': '219.example.com', 'DNSEnv': {'TOKEN': 'secret'}}},
        {'Core': 'sing', 'NodeID': 365, 'NodeType': 'tuic',
         'Nested': {'NodeID': 219, 'List': [219, {'NodeID': 219}]}},
        {'Core': 'xray', 'NodeID': 2190, 'NodeType': 'vless', 'Timeout': 219},
        {'Core': 'sing', 'NodeID': 21, 'NodeType': 'hysteria2'},
    ],
    '_help': {'说明': '保留我', 'NodeID': 219},
}

with tempfile.TemporaryDirectory(prefix='n2x-delete-test-') as root:
    root = Path(root)
    counter = [0]

    def run_case(data, entry='delete_node_configs', dialogue='219\n', setup='', success=False):
        counter[0] += 1
        work = root / str(counter[0])
        work.mkdir()
        config = work / 'config.json'
        if isinstance(data, dict) or isinstance(data, list):
            raw = json.dumps(data, ensure_ascii=False, indent=2)
        else:
            raw = data
        if raw is not None:
            config.write_text(raw)
            config.chmod(0o640)
        backup = work / 'config.json.bak'
        backup.write_text('previous backup')
        untouched = {name: b'keep unchanged\n' for name in
                     ('.env', 'dns.json', 'route.json', 'custom_outbound.json', 'cert.pem')}
        for name, content in untouched.items():
            (work / name).write_bytes(content)
        inode = config.stat().st_ino if config.exists() else None
        command = '''source "$1"
red='' green='' yellow='' plain=''
restart() { printf 'restart %s\\n' "$*" >> "$N2X_CONFIG_DIR/actions"; }
before_show_menu() { printf 'menu\\n' >> "$N2X_CONFIG_DIR/actions"; }
'''
        command += wrapper + '\n' + setup + '\n' + entry
        result = subprocess.run(
            [bash, '-c', command, 'delete-test', str(repo / 'config_append.sh')],
            input=dialogue, capture_output=True, encoding='utf-8', timeout=10,
            env=dict(os.environ, N2X_CONFIG_DIR=str(work)),
        )
        assert (result.returncode == 0) == success, (entry, dialogue, result)
        assert 'secret-never-display' not in result.stdout, result.stdout
        for name, content in untouched.items():
            assert (work / name).read_bytes() == content, name
        if success:
            assert backup.read_text() == raw, 'backup must preserve the original bytes'
            assert config.stat().st_ino == inode, 'keep the watched inode'
            assert config.stat().st_mode & 0o777 == 0o640, 'keep config permissions'
            assert backup.stat().st_mode & 0o777 == 0o600, 'protect backup credentials'
        else:
            assert (config.read_text() if config.exists() else None) == raw, result
            assert backup.read_text() == 'previous backup', 'no-op must not replace backup'
        actions = (work / 'actions').read_text() if (work / 'actions').exists() else ''
        return config, result.stdout, actions

    # 目标完整对象被删除；相似 ID、嵌套 NodeID 和其余所有字段保持原值。
    config, out, actions = run_case(original, success=True)
    expected = copy.deepcopy(original)
    del expected['Nodes'][0]
    assert json.loads(config.read_text()) == expected
    assert 'anytls=219, tuic=365, vless=2190, hysteria2=21' in out
    assert '共 1 段' in out and not actions

    # 相同 ID 的不同协议/核心都按 ID 删除，数值字符串也兼容。
    duplicates = copy.deepcopy(original)
    duplicates['Nodes'].extend([
        {'NodeID': 219, 'NodeType': 'tuic', 'Core': 'sing'},
        {'NodeID': '219', 'NodeType': 'trojan', 'Core': 'xray'},
    ])
    config, out, _ = run_case(duplicates, dialogue='00219\n', success=True)
    assert json.loads(config.read_text()) == expected
    assert '共 3 段' in out

    # 删除首项、中间项、尾项和最后一个节点，均得到合法数组。
    for index in (1, 2, 3):
        data = copy.deepcopy(original)
        target = data['Nodes'].pop(index)['NodeID']
        config, _, _ = run_case(original, dialogue=str(target) + '\n', success=True)
        assert json.loads(config.read_text()) == data
    single = copy.deepcopy(original)
    single['Nodes'] = single['Nodes'][:1]
    config, _, _ = run_case(single, success=True)
    single['Nodes'] = []
    assert json.loads(config.read_text()) == single

    # 不存在、空输入、EOF、非法输入、无节点、缺失/损坏配置都不写配置或备份。
    for dialogue in ('999\n', '\n', '', 'anytls=219\n', '219 365\n', '-219\n', '219.0\n', '219;exit\n'):
        run_case(original, dialogue=dialogue)
    for data in ({'Nodes': []}, {}, {'Nodes': {}}, {'Nodes': [None]}, [], '{broken json', None):
        run_case(data)
    run_case(original, setup='n2x_python_bin() { return 1; }')
    run_case(original, setup='cp() { return 1; }')

    # 注释、尾逗号、字符串里的 URL/括号均使用共用 JSON5 解析器处理。
    commented = '''{
      // 这份原文必须保存在备份里
      "Nodes": [
        {"NodeID": 219, "NodeType": "anytls", "Nested": {"enabled": true,},},
        {"NodeID": 365, "NodeType": "tuic", "URL": "https://example.com/a//b/*c*/",},
      ],
      "Cores": [{"Type": "sing",}],
    }'''
    config, out, _ = run_case(commented, success=True)
    assert json.loads(config.read_text()) == {
        'Nodes': [{'NodeID': 365, 'NodeType': 'tuic', 'URL': 'https://example.com/a//b/*c*/'}],
        'Cores': [{'Type': 'sing'}],
    }
    assert '标准 JSON' in out

    # 只在真正保存成功时重启一次；CLI 不回菜单，菜单模式则返回菜单。
    _, _, actions = run_case(original, entry='delete_node_config 0', success=True)
    assert actions == 'restart 0\n', actions
    _, _, actions = run_case(original, entry='delete_node_config', success=True)
    assert actions == 'restart 0\nmenu\n', actions
    _, _, actions = run_case(original, entry='delete_node_config 0', dialogue='999\n')
    assert not actions
    _, _, actions = run_case(original, entry='delete_node_config', dialogue='\n')
    assert actions == 'menu\n', actions
    run_case(original, entry='delete_node_config 0', setup='unset -f delete_node_configs')

print('Node deletion: exact IDs, full objects, backups, no-op paths and manager flow passed')
PY
