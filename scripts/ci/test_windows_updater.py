"""Native updater transactions on isolated fixtures; existing Windows package job.

Linux explicitly skips these tests. BB_UPDATER_PACKAGE_DIR points at the actual packaged ZIP;
tests extract its helper; the fixture EXE only substitutes the GUI/first-frame acknowledgement.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


@unittest.skipUnless(os.name == "nt", "NOT RUN: requires native Windows")
class WindowsUpdaterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix="bb-updater-native-")
        cls.base = Path(cls.workspace.name)
        archives = list(Path(os.environ["BB_UPDATER_PACKAGE_DIR"]).glob("*.zip"))
        if len(archives) != 1:
            raise AssertionError("expected exactly one packaged ZIP")
        cls.package_archive = archives[0]
        cls.helper = cls.base / "bb_updater.exe"
        with zipfile.ZipFile(archives[0]) as archive:
            data = archive.read("bb_updater.exe")
            inventory = archive.read("bb-payload.sha256").decode("utf-8")
            expected = hashlib.sha256(data).hexdigest() + "  bb_updater.exe"
            if expected not in inventory.splitlines():
                raise AssertionError("packaged helper does not match payload manifest")
            cls.helper.write_bytes(data)
        source = cls.base / "Fixture.cs"
        source.write_text('''using System; using System.Threading;
class Fixture { static void Main(string[] args) {
  foreach (var arg in args) if (arg.StartsWith("--bb-update-ready=")) {
    using (var e = EventWaitHandle.OpenExisting(arg.Substring(18))) e.Set();
  }
} }''', encoding="utf-8")
        cls.app = cls.base / "fixture.exe"
        compiler = Path(os.environ["SystemRoot"]) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
        subprocess.run([str(compiler), "/nologo", f"/out:{cls.app}", str(source)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="case-", dir=self.base)
        self.addCleanup(self.temp.cleanup)
        self.basecase = Path(self.temp.name)
        self.old = self.basecase / "BB 中文 空格"
        self.new = self.basecase / "new payload"
        self.make_payload(self.old, "old")
        self.make_payload(self.new, "new")
        (self.old / "用户文件.txt").write_text("user data", encoding="utf-8")
        self.archive = self.basecase / "package.zip"
        self.zip_new()
        self.transaction = self.basecase / ("." + self.old.name + ".bb-update")

    def make_payload(self, path, version):
        path.mkdir()
        shutil.copy2(self.app, path / "bb_client.exe")
        shutil.copy2(self.helper, path / "bb_updater.exe")
        for name in ["flutter_windows.dll", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin", "ffmpeg/ffmpeg.exe", "ffmpeg/FFMPEG-LICENSE.txt", "ffmpeg/FFMPEG-NOTICE.txt", "bb-build.json"]:
            target = path / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(version, encoding="utf-8")
        self.inventory(path)

    def inventory(self, path):
        files = sorted(p for p in path.rglob("*") if p.is_file() and p.name != "bb-payload.sha256")
        (path / "bb-payload.sha256").write_text("".join(
            f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(path).as_posix()}\n" for p in files), encoding="utf-8")

    def zip_new(self, extra=None):
        with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as z:
            for p in self.new.rglob("*"):
                if p.is_file():
                    z.write(p, p.relative_to(self.new).as_posix())
            if extra:
                z.writestr(extra, "malicious")

    def run_update(self, fault=None, crash=None, digest=None):
        parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(100)"])
        try:
            env = dict(os.environ)
            env["BB_SESSION_FILE"] = str(self.basecase / "isolated-data/session.json")
            env["PATH"] = str(Path(os.environ["SystemRoot"]) / "System32")
            env.pop("BB_UPDATE_FAULT", None)
            env.pop("BB_UPDATE_CRASH", None)
            if fault:
                env["BB_UPDATE_FAULT"] = fault
            if crash:
                env["BB_UPDATE_CRASH"] = crash
            updater = subprocess.Popen([str(self.helper), "--apply", str(self.old), str(self.archive),
                digest or hashlib.sha256(self.archive.read_bytes()).hexdigest(), str(parent.pid)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            try:
                # A background reader is unnecessary: the updater preflight is
                # bounded by the test runner's subprocess timeout watchdog below.
                import threading
                watchdog = threading.Timer(45, updater.kill)
                watchdog.start()
                line = updater.stdout.readline().decode("utf-8-sig").strip()
                if line == "READY":
                    parent.terminate()
                    parent.wait(timeout=10)
                out, err = updater.communicate(timeout=45)
                return updater.returncode, line + out.decode("utf-8-sig"), err.decode("utf-8-sig")
            finally:
                watchdog.cancel()
                if updater.poll() is None:
                    updater.kill()
                    updater.wait(timeout=10)
        finally:
            if parent.poll() is None:
                parent.terminate()
            parent.wait(timeout=10)

    def assert_old(self):
        self.assertEqual((self.old / "bb-build.json").read_text(), "old")
        self.assertEqual((self.old / "用户文件.txt").read_text(encoding="utf-8"), "user data")

    def test_packaged_flutter_first_frame_commits_real_payload(self):
        # This case runs the actual ZIP's Flutter EXE/DLL/data/FFmpeg payload;
        # the other cases use a fast GUI fixture to isolate transaction faults.
        shutil.rmtree(self.old)
        shutil.rmtree(self.new)
        with zipfile.ZipFile(self.package_archive) as archive:
            archive.extractall(self.old)
            archive.extractall(self.new)
        (self.old / "用户文件.txt").write_text("user data", encoding="utf-8")
        self.zip_new()
        try:
            result = self.run_update()
            self.assertEqual(result[0], 0, result)
            self.assertEqual((self.transaction / "state").read_text(), "committed")
            self.assertEqual((self.old / "用户文件.txt").read_text(encoding="utf-8"), "user data")
        finally:
            pid_file = self.transaction / "launched.pid"
            if pid_file.exists():
                app_pid = int(pid_file.read_text())
                # Only terminate our recorded child, after checking its full
                # executable path belongs to this isolated fixture directory.
                subprocess.run(["powershell.exe", "-NoProfile", "-Command",
                    "$p = Get-Process -Id " + str(app_pid) + " -ErrorAction SilentlyContinue; "
                    "if ($p -and $p.Path -eq $env:BB_FIXTURE_EXE) { $p | Stop-Process -Force; $p.WaitForExit() }"],
                    env={**os.environ, "BB_FIXTURE_EXE": str(self.old / "bb_client.exe")}, check=True, timeout=20)

    def test_success_keeps_backup_and_unknown_user_files(self):
        result = self.run_update()
        self.assertEqual(result[0], 0, result)
        self.assertEqual((self.old / "bb-build.json").read_text(), "new")
        self.assertEqual((self.old / "用户文件.txt").read_text(encoding="utf-8"), "user data")
        self.assertEqual((self.transaction / "old/bb-build.json").read_text(), "old")
        self.assertEqual((self.transaction / "state").read_text(), "committed")

    def test_failure_boundaries_restore_complete_old_install(self):
        for point in ["before-move", "after-old-move", "after-new-move"]:
            with self.subTest(point=point):
                result = self.run_update(fault=point)
                self.assertEqual(result[0], 1, result)
                self.assert_old()

    def test_crash_then_cold_recovery(self):
        result = self.run_update(crash="after-old-move")
        self.assertEqual(result[0], 91, result)
        self.assertFalse(self.old.exists())
        recovery = subprocess.run([str(self.transaction / "Recover BB.exe")], capture_output=True, timeout=45)
        self.assertEqual(recovery.returncode, 0, recovery.stderr)
        self.assert_old()
        result = self.run_update()
        self.assertEqual(result[0], 0, result)

    def test_hash_mismatch_leaves_old_untouched(self):
        result = self.run_update(digest="0" * 64)
        self.assertEqual(result[0], 1, result)
        self.assertNotIn("READY", result[1])
        self.assert_old()

    def test_traversal_ads_reserved_names_and_case_duplicates(self):
        for name in ["../escaped.txt", "C:/escape.txt", "data/a:stream", "NUL.txt", "BB_CLIENT.EXE"]:
            with self.subTest(name=name):
                self.zip_new(name)
                result = self.run_update()
                self.assertEqual(result[0], 1, result)
                self.assertNotIn("READY", result[1])
                self.assert_old()
                self.assertFalse((self.basecase / "escaped.txt").exists())

    def test_collision_with_unknown_user_file_refuses_replacement(self):
        (self.new / "用户文件.txt").write_text("must not overwrite", encoding="utf-8")
        self.inventory(self.new)
        self.zip_new()
        result = self.run_update()
        self.assertEqual(result[0], 1, result)
        self.assert_old()

    def test_locked_payload_refuses_before_parent_exit(self):
        import ctypes
        from ctypes import wintypes
        create = ctypes.windll.kernel32.CreateFileW
        create.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                           wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        create.restype = wintypes.HANDLE
        close = ctypes.windll.kernel32.CloseHandle
        close.argtypes = [wintypes.HANDLE]
        handle = create(str(self.old / "bb_client.exe"), 0x80000000, 0, None, 3, 0, None)
        self.assertNotEqual(handle, wintypes.HANDLE(-1).value)
        try:
            result = self.run_update()
            self.assertEqual(result[0], 1, result)
            self.assertNotIn("READY", result[1])
            self.assert_old()
        finally:
            close(handle)

    def test_symlink_zip_is_rejected(self):
        with zipfile.ZipFile(self.archive, "a") as z:
            entry = zipfile.ZipInfo("escape-link")
            entry.create_system = 3
            entry.external_attr = 0o120777 << 16
            z.writestr(entry, "../outside")
        result = self.run_update()
        self.assertEqual(result[0], 1, result)
        self.assertNotIn("READY", result[1])
        self.assert_old()


if __name__ == "__main__":
    unittest.main(verbosity=2)
