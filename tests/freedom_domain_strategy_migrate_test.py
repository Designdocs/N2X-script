#!/usr/bin/env python3
"""Exercise the actual shell entry point against disposable user configurations."""
import copy
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.path = self.root / "custom_outbound.json"
        self.env = dict(os.environ, N2X_CONFIG_DIR=str(self.root))

    def run_migration(self, *paths, success=True):
        result = subprocess.run(
            ["bash", "-c", 'source "$1/config_gen.sh"; shift; migrate_freedom_domain_strategy "$@"',
             "migration-test", str(REPO), *map(str, paths)],
            env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def write(self, payload):
        self.path.write_text(json.dumps(payload, indent=2) + "\n")

    def backups(self):
        return list(self.root.glob("custom_outbound.json.bak.freedom-domain-strategy.*"))

    def test_preserves_custom_fields_order_credentials_metadata_and_idempotence(self):
        payload = [
            {"tag": "custom-direct", "protocol": "freedom", "sendThrough": "192.0.2.1",
             "settings": {"domainStrategy": "ForceIPv6", "redirect": ":443", "fragment": {"length": "10-20"}},
             "streamSettings": {"security": "tls", "tlsSettings": {"serverName": "example.invalid"},
                                "sockopt": {"mark": 42, "dialerProxy": "upstream"}}},
            {"tag": "proxy", "protocol": "socks", "settings": {
                "domainStrategy": "leave-this-custom-field", "servers": [{"users": [{"user": "u", "pass": "密\\\"码"}]}]}},
            {"tag": "v4", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4v6"}},
            {"tag": "block", "protocol": "blackhole"},
        ]
        self.write(payload)
        self.path.chmod(0o640)
        raw, before = self.path.read_bytes(), self.path.stat()
        self.run_migration()
        expected = copy.deepcopy(payload)
        for index in (0, 2):
            old = expected[index]["settings"].pop("domainStrategy")
            expected[index].setdefault("streamSettings", {}).setdefault("sockopt", {})["domainStrategy"] = old
        self.assertEqual(json.loads(self.path.read_bytes()), expected)
        backup, = self.backups()
        self.assertEqual(backup.read_bytes(), raw)
        for file in (self.path, backup):
            after = file.stat()
            self.assertEqual(stat.S_IMODE(after.st_mode), 0o640)
            self.assertEqual((after.st_uid, after.st_gid), (before.st_uid, before.st_gid))
        raw, before = self.path.read_bytes(), self.path.stat()
        self.run_migration()
        self.assertEqual(self.path.read_bytes(), raw)
        self.assertEqual(self.path.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(len(self.backups()), 1)

    def test_asis_target_precedence_and_equal_existing_strategy(self):
        payload = [
            {"protocol": "freedom", "settings": {"domainStrategy": "AsIs", "custom": 1},
             "streamSettings": {"sockopt": {"domainStrategy": "UseIPv6", "mark": 5}}},
            {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"},
             "targetStrategy": "ForceIPv6", "streamSettings": {"sockopt": {"domainStrategy": "UseIP"}}},
            {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv6"},
             "streamSettings": {"sockopt": {"domainStrategy": "useipv6", "mark": 6}}},
        ]
        self.write(payload)
        self.run_migration()
        expected = copy.deepcopy(payload)
        for outbound in expected:
            del outbound["settings"]["domainStrategy"]
        self.assertEqual(json.loads(self.path.read_bytes()), expected)

    def test_conflicts_invalid_json_duplicates_and_bad_types_are_not_changed(self):
        cases = [
            '[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv6"}},'
            '{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4"},'
            '"streamSettings":{"sockopt":{"domainStrategy":"UseIPv6"}}}]',
            '[{"protocol":"freedom","settings":{"domainStrategy":"bogus"}}]',
            '[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4"},"streamSettings":[]}]',
            '[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4"},"streamSettings":{"sockopt":1}}]',
            '[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4","domainStrategy":"UseIPv6"}}]',
            '{"not": "an outbound array"}', '["bad outbound"]', '{invalid',
        ]
        for raw in cases:
            with self.subTest(raw=raw):
                self.path.write_text(raw)
                before = self.path.stat().st_mtime_ns
                self.run_migration(success=False)
                self.assertEqual(self.path.read_text(), raw)
                self.assertEqual(self.path.stat().st_mtime_ns, before)
                self.assertEqual(self.backups(), [])

    def test_custom_path_discovery_and_symlinks(self):
        target = self.root / "custom.json"
        target.write_text('[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv6"}}]')
        other = self.root / "another-custom.json"
        other.write_text('[{"protocol":"freedom","settings":{"domainStrategy":"ForceIPv4"}}]')
        self.path.symlink_to(target)
        main = self.root / "config.json"
        main.write_text(json.dumps({"Cores": [
            {"Type": "xray", "OutboundConfigPath": str(other)},
            {"Type": "xray", "OutboundConfigPath": str(self.path)},
            {"Type": "sing", "OutboundConfigPath": "/ignored"},
        ], "Nodes": [{"custom": "保留"}]}))
        raw = main.read_bytes()
        self.run_migration()
        self.assertTrue(self.path.is_symlink())
        self.assertEqual(main.read_bytes(), raw)
        self.assertEqual(json.loads(target.read_bytes())[0]["streamSettings"]["sockopt"]["domainStrategy"], "UseIPv6")
        self.assertEqual(len(list(self.root.glob("custom.json.bak.*"))), 1)
        self.assertEqual(json.loads(other.read_bytes())[0]["streamSettings"]["sockopt"]["domainStrategy"], "ForceIPv4")
        self.assertEqual(len(list(self.root.glob("another-custom.json.bak.*"))), 1)

    def test_missing_current_files_and_explicit_path(self):
        self.run_migration()
        self.assertEqual(list(self.root.iterdir()), [])
        self.write([{"protocol": "freedom", "settings": {}, "custom": 2}])
        raw, before = self.path.read_bytes(), self.path.stat().st_mtime_ns
        self.run_migration()
        self.assertEqual(self.path.read_bytes(), raw)
        self.assertEqual(self.path.stat().st_mtime_ns, before)
        target = self.root / "other.json"
        target.write_text('[{"protocol":"freedom","settings":{"domainStrategy":"UseIP"}}]')
        (self.root / "config.json").write_text("// unsupported comments")
        self.run_migration(target)
        self.assertNotIn("domainStrategy", json.loads(target.read_bytes())[0]["settings"])
        self.assertEqual(self.path.read_bytes(), raw)

    def test_new_update_shell_runs_migration(self):
        self.check_update_shell(legacy=False)

    def test_released_update_shell_bootstraps_migration(self):
        self.check_update_shell(legacy=True)

    def check_update_shell(self, legacy):
        self.write([{"protocol": "freedom", "settings": {"domainStrategy": "UseIPv6"}}])
        text = (REPO / "N2X.sh").read_text()
        body = text.split("update_shell() {\n", 1)[1].split("\n}\n", 1)[0]
        if legacy:
            # This three-line addition is absent from the released updater.
            start = body.index("        if declare -F migrate_freedom_domain_strategy")
            end = body.index("        fi\n", start) + len("        fi\n")
            body = body[:start] + body[end:]
        body = body.replace("/usr/local/N2X", str(self.root / "installed"))
        body = body.replace("/usr/bin/N2X", str(self.root / "manager"))
        (self.root / "installed").mkdir()
        prelude = '''
red= green= yellow= plain=
download_managed_shell_file() { cp "$TEST_REPO/${1##*/}" "$2"; }
'''
        result = subprocess.run(["bash", "-c", prelude + "\nupdate_shell() {\n" + body + "\n}\nupdate_shell\n"],
                                env=dict(self.env, TEST_REPO=str(REPO)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("domainStrategy", json.loads(self.path.read_bytes())[0]["settings"])
        self.assertEqual(len(self.backups()), 1)

    def test_ordinary_source_does_not_migrate(self):
        self.write([{"protocol": "freedom", "settings": {"domainStrategy": "UseIP"}}])
        raw = self.path.read_bytes()
        subprocess.run(["bash", "-c", 'source "$1/config_gen.sh"', "source-test", str(REPO)],
                       env=self.env, check=True, capture_output=True)
        self.assertEqual(self.path.read_bytes(), raw)
        self.assertEqual(self.backups(), [])

    def test_atomic_replace_failure_keeps_original_and_valid_backup(self):
        self.write([{"protocol": "freedom", "settings": {"domainStrategy": "UseIP"}}])
        raw, before = self.path.read_bytes(), self.path.stat().st_mtime_ns
        wrapper = self.root / "bin" / "python3"
        wrapper.parent.mkdir()
        wrapper.write_text("#!" + sys.executable + '''
import os, sys
source = sys.stdin.read()
sys.argv = sys.argv[1:]
def fail_replace(*args):
    raise OSError("simulated atomic replace failure")
os.replace = fail_replace
exec(compile(source, "<migration>", "exec"))
''')
        wrapper.chmod(0o700)
        self.env["PATH"] = str(wrapper.parent) + os.pathsep + self.env["PATH"]
        self.run_migration(success=False)
        self.assertEqual(self.path.read_bytes(), raw)
        self.assertEqual(self.path.stat().st_mtime_ns, before)
        backup, = self.backups()
        self.assertEqual(backup.read_bytes(), raw)
        self.assertEqual(list(self.root.glob("*.tmp.freedom-domain-strategy.*")), [])

    def test_installer_migrates_before_starting_new_core(self):
        text = (REPO / "install.sh").read_text()
        body = text.split("install_N2X() {", 1)[1]
        call = body.index("\n    run_freedom_domain_strategy_migration\n")
        self.assertLess(body.index("if ! install_xray_side_files; then"), call)
        self.assertLess(call, body.index("service N2X start"))
        self.assertLess(call, body.index("systemctl start N2X"))
        wrapper = text.split("run_freedom_domain_strategy_migration() {\n", 1)[1].split("\n}\n", 1)[0]
        self.write([{"protocol": "freedom", "settings": {"domainStrategy": "UseIP"}}])
        script = 'source "$1/config_gen.sh"\nlog_warn() { printf "%s\\n" "$*"; }\n' + wrapper
        result = subprocess.run(["bash", "-c", script, "installer-test", str(REPO)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("domainStrategy", json.loads(self.path.read_bytes())[0]["settings"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
