#!/usr/bin/env python3
"""Run the real upgrade migration against disposable main configurations."""
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


def xray(value):
    return {"Type": "xray", "ConnectionConfig": {"connIdle": value, "bufferSize": 64}}


class ConnIdleMigrationTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.path = self.root / "config.json"
        self.env = dict(os.environ, N2X_CONFIG_DIR=str(self.root))

    def shell(self, script, *args, success=True):
        result = subprocess.run(
            ["/bin/bash", "-c", script, "migration-test", str(REPO), *map(str, args)],
            env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def migrate(self, *args, success=True):
        return self.shell('source "$1/config_gen.sh"; shift; migrate_xray_conn_idle "$@"',
                          *args, success=success)

    def backups(self, path=None):
        path = path or self.path
        return list(path.parent.glob(path.name + ".bak.conn-idle.*"))

    def write(self, data):
        self.path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")

    def assert_untouched(self, raw, before):
        self.assertEqual(self.path.read_bytes(), raw)
        after = self.path.stat()
        self.assertEqual((after.st_ino, after.st_mtime_ns), (before.st_ino, before.st_mtime_ns))
        self.assertEqual(self.backups(), [])

    def test_mixed_cores_custom_fields_credentials_backup_metadata_and_idempotence(self):
        data = {"Memory": {"SoftLimitPercent": 70, "RestartPercent": 90},
                "Cores": [xray(v) for v in (30, 600, 300, 1800, 0, 6000)] + [
                    {"Type": "sing", "ConnectionConfig": {"connIdle": 30}},
                    {"Type": "custom", "ConnectionConfig": {"connIdle": 600}},
                    {"Type": "xray"}],
                "Nodes": [{"NodeID": 9007199254740993, "ApiKey": '密\\"码${TOKEN}',
                           "ConnectionConfig": {"connIdle": 30}}],
                "_help": {"connIdle": 600}}
        self.write(data)
        self.path.chmod(0o640)
        raw, before = self.path.read_bytes(), self.path.stat()
        result = self.migrate()
        expected = copy.deepcopy(data)
        for index in (0, 1):
            expected["Cores"][index]["ConnectionConfig"]["connIdle"] = 300
        self.assertEqual(json.loads(self.path.read_bytes()), expected)
        self.assertIn("2 个 Xray connIdle", result.stdout)
        self.assertNotIn(data["Nodes"][0]["ApiKey"], result.stdout + result.stderr)
        backup, = self.backups()
        self.assertEqual(backup.read_bytes(), raw)
        for path in (self.path, backup):
            after = path.stat()
            self.assertEqual(stat.S_IMODE(after.st_mode), 0o640)
            self.assertEqual((after.st_uid, after.st_gid), (before.st_uid, before.st_gid))
        raw, before = self.path.read_bytes(), self.path.stat()
        self.migrate()
        self.assertEqual(self.path.read_bytes(), raw)
        self.assertEqual(self.path.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.backups(), [backup])

    def test_jsonc_format_comments_escapes_urls_and_trailing_commas_preserved(self):
        raw = (b'{\r\n// "connIdle": 600; do not edit this comment\r\n'
               b'"Cores": [ {"Type": "xray", "ConnectionConfig": {\r\n'
               b'"connIdle" /* idle */ : 30, "bufferSize": 64, /* }, */ }, },\r\n'
               b'{"Type":"xray","ConnectionConfig":{"co\\u006enIdle":600,},}, ],\r\n'
               b'"Nodes": [{"ApiHost":"https://example.invalid/a//b",'
               b'"ApiKey":"escaped \\\"connIdle\\\": 600,} /* not a comment */",},],\r\n}\r\n')
        self.path.write_bytes(raw)
        self.migrate()
        expected = raw.replace(b'/* idle */ : 30', b'/* idle */ : 300').replace(
            b'"co\\u006enIdle":600', b'"co\\u006enIdle":300')
        self.assertEqual(self.path.read_bytes(), expected)
        self.assertEqual(self.backups()[0].read_bytes(), raw)

    def test_case_insensitive_field_names(self):
        self.path.write_text('{"cores":[{"type":"xray","connectionconfig":{"ConnIdle":600}}]}')
        self.migrate()
        self.assertEqual(json.loads(self.path.read_bytes())["cores"][0]["connectionconfig"]["ConnIdle"], 300)

    def test_custom_missing_null_noninteger_and_sing_values_are_noops(self):
        for data in ({}, {"Cores": []}, {"Cores": [
                xray(v) for v in (300, 0, 60, 1800, 6000, "30", "600", True, None, 30.0, 600.0)
        ] + [{"Type": "xray"}, {"Type": "xray", "ConnectionConfig": {}},
             {"Type": "xray", "ConnectionConfig": None},
             {"Type": "sing", "ConnectionConfig": {"connIdle": 600}}]}):
            with self.subTest(data=data):
                self.write(data)
                raw, before = self.path.read_bytes(), self.path.stat()
                self.migrate()
                self.assert_untouched(raw, before)

    def test_invalid_json_and_shapes_never_partially_migrate(self):
        for raw in ('not JSON', '{"Cores":', '[]', '{"Cores":{}}', '{"Cores":[null]}',
                    '{"Cores":[{"Type":"xray","ConnectionConfig":30}]}',
                    '{"Cores":[{"Type":"xray","ConnectionConfig":{"connIdle":30}}],"bad":NaN}',
                    '{"Cores":[{"Type":"xray","ConnectionConfig":{"connIdle":30}}]} /* unclosed'):
            with self.subTest(raw=raw):
                self.path.write_text(raw)
                before = self.path.stat()
                result = self.migrate(success=False)
                self.assertIn("迁移失败", result.stderr)
                self.assert_untouched(raw.encode(), before)

    def test_duplicate_and_ambiguous_keys_are_rejected_without_edits(self):
        for raw in (
            '{"Cores":[],"Cores":[]}',
            '{"Cores":[],"cores":[]}',
            '{"Cores":[{"Type":"xray","type":"xray"}]}',
            '{"Cores":[{"Type":"xray","ConnectionConfig":{},"connectionconfig":{}}]}',
            '{"Cores":[{"Type":"xray","ConnectionConfig":{"connIdle":30,"connIdle":600}}]}',
            '{"Cores":[{"Type":"xray","ConnectionConfig":{"connIdle":30,"ConnIdle":600}}]}',
        ):
            with self.subTest(raw=raw):
                self.path.write_text(raw)
                before = self.path.stat()
                self.migrate(success=False)
                self.assert_untouched(raw.encode(), before)

    def test_missing_config_is_noop(self):
        self.migrate()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_explicit_path_and_symlink_preserve_link_and_target_backup(self):
        self.write({"Cores": [xray(30)]})
        original = self.path.read_bytes()
        target = self.root / "custom" / "main.json"
        target.parent.mkdir()
        target.write_text('{"Cores":[{"Type":"xray","ConnectionConfig":{"connIdle":600}}]}')
        raw = target.read_bytes()
        link = self.root / "main-link.json"
        link.symlink_to(target)
        self.migrate(link)
        self.assertTrue(link.is_symlink())
        self.assertEqual(json.loads(target.read_bytes())["Cores"][0]["ConnectionConfig"]["connIdle"], 300)
        self.assertEqual(self.backups(target)[0].read_bytes(), raw)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(self.backups(), [])

    def python_wrapper(self, patch):
        wrapper = self.root / "bin" / "python3"
        wrapper.parent.mkdir()
        wrapper.write_text("#!" + sys.executable + '\nimport os, sys, tempfile\n'
                           'source = sys.stdin.read()\nsys.argv = sys.argv[1:]\n' + patch +
                           '\nexec(compile(source, "<migration>", "exec"))\n')
        wrapper.chmod(0o700)
        self.env["PATH"] = str(wrapper.parent) + os.pathsep + self.env["PATH"]

    def test_atomic_replace_failure_keeps_original_and_valid_backup(self):
        self.write({"Cores": [xray(30)]})
        raw, before = self.path.read_bytes(), self.path.stat()
        self.python_wrapper('def fail(*args):\n    raise OSError("simulated replace failure")\nos.replace = fail\n')
        self.migrate(success=False)
        self.assertEqual(self.path.read_bytes(), raw)
        self.assertEqual(self.path.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.backups()[0].read_bytes(), raw)
        self.assertEqual(list(self.root.glob("*.tmp.conn-idle.*")), [])

    def test_backup_failure_does_not_change_original_or_leave_partial_backup(self):
        self.write({"Cores": [xray(600)]})
        raw, before = self.path.read_bytes(), self.path.stat()
        self.python_wrapper('def fail(*args):\n    raise OSError("simulated backup failure")\nos.fchmod = fail\n')
        self.migrate(success=False)
        self.assert_untouched(raw, before)
        self.assertEqual(list(self.root.glob("*.tmp.conn-idle.*")), [])

    def test_concurrent_edit_is_not_overwritten(self):
        self.write({"Cores": [xray(30)]})
        raw = self.path.read_bytes()
        self.python_wrapper('''
original_mkstemp = tempfile.mkstemp
def edit_during_write(*args, **kwargs):
    result = original_mkstemp(*args, **kwargs)
    if '.tmp.conn-idle.' in kwargs.get('prefix', ''):
        with open(sys.argv[1], 'wb') as handle:
            handle.write(b'{"Cores":[],"concurrent":"keep"}')
    return result
tempfile.mkstemp = edit_during_write
''')
        result = self.migrate(success=False)
        self.assertIn("迁移期间被修改", result.stderr)
        self.assertEqual(self.path.read_bytes(), b'{"Cores":[],"concurrent":"keep"}')
        self.assertEqual(self.backups()[0].read_bytes(), raw)
        self.assertEqual(list(self.root.glob("*.tmp.conn-idle.*")), [])

    def test_missing_python_preserves_config_and_reports_failure(self):
        self.write({"Cores": [xray(30)]})
        raw, before = self.path.read_bytes(), self.path.stat()
        self.env["PATH"] = str(self.root / "no-python")
        result = self.migrate(success=False)
        self.assertIn("需要 python3", result.stderr)
        self.assert_untouched(raw, before)

    def test_source_and_script_only_upgrade_do_not_migrate_main_config(self):
        self.write({"Cores": [xray(30)]})
        raw, before = self.path.read_bytes(), self.path.stat()
        self.shell('source "$1/config_gen.sh"')
        self.assert_untouched(raw, before)
        text = (REPO / "N2X.sh").read_text()
        body = text.split("update_shell() {\n", 1)[1].split("\n}\n", 1)[0]
        body = body.replace("/usr/local/N2X", str(self.root / "installed"))
        body = body.replace("/usr/bin/N2X", str(self.root / "manager"))
        (self.root / "installed").mkdir()
        prelude = 'red= green= yellow= plain=\ndownload_managed_shell_file() { cp "$1" "$2"; }\n'
        body = body.replace("https://raw.githubusercontent.com/Designdocs/N2X-script/main", str(REPO))
        self.shell(prelude + "\nupdate_shell() {\n" + body + "\n}\nupdate_shell\n")
        self.assert_untouched(raw, before)

    def test_installer_runs_migration_after_stop_and_before_both_start_paths(self):
        text = (REPO / "install.sh").read_text()
        body = text.split("install_N2X() {", 1)[1]
        call = body.index("\n    run_xray_conn_idle_migration\n")
        for stop in ("service N2X stop", "systemctl stop N2X"):
            self.assertLess(body.index(stop), call)
        self.assertLess(body.index("if ! install_xray_side_files; then"), call)
        for start in ("service N2X start", "systemctl start N2X"):
            self.assertLess(call, body.index(start))
        wrapper = text.split("run_xray_conn_idle_migration() {\n", 1)[1].split("\n}\n", 1)[0]
        self.write({"Cores": [xray(600)]})
        result = self.shell('source "$1/config_gen.sh"\nlog_warn() { printf "%s\\n" "$*"; }\n' + wrapper)
        self.assertIn("调整为 300 秒", result.stdout)
        self.assertEqual(json.loads(self.path.read_bytes())["Cores"][0]["ConnectionConfig"]["connIdle"], 300)
        self.path.write_text('{invalid')
        result = self.shell('source "$1/config_gen.sh"\nlog_warn() { printf "%s\\n" "$*"; }\n' + wrapper)
        self.assertIn("自动迁移未完成", result.stdout)
        self.assertEqual(self.path.read_text(), '{invalid')


if __name__ == "__main__":
    unittest.main(verbosity=2)
