"""Dependency integrity: pinned archive, pinned tree, pinned build script."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import os
from unittest import mock

from test_package_windows import make_bundle


class DependencyTests(unittest.TestCase):
    def helper(self):
        self.assertIsNotNone(importlib.util.find_spec('ffmpeg_cache'))
        import ffmpeg_cache
        return ffmpeg_cache

    def bundle_with_dependency(self, root, script_bytes=None):
        bundle = make_bundle(root / 'bundle',
                             ffmpeg_payload=b'MZ' + b'X' * (11 * 1024 * 1024))
        dest = bundle / 'ffmpeg'
        script = root / self.cache.BUILD_SCRIPT
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_bytes(
            script_bytes if script_bytes is not None
            else (dest / 'BUILD-FFMPEG.sh').read_bytes())
        return dest

    def test_tree_digest_detects_exe_and_manifest_rewrite(self):
        self.cache = self.helper()
        cache = self.cache
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'ffmpeg.exe').write_bytes(b'MZoriginal')
            (root / 'BUILD-MANIFEST.txt').write_text('sha=original')
            original = cache.tree_digest(root)
            (root / 'ffmpeg.exe').write_bytes(b'MZtampered')
            (root / 'BUILD-MANIFEST.txt').write_text('sha=tampered')
            with self.assertRaisesRegex(RuntimeError, 'cache content digest'):
                cache.verify_tree(root, original)

    def test_prebuilt_asset_validates_and_preserves_provenance(self):
        self.cache = self.helper()
        cache = self.cache
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dest = self.bundle_with_dependency(root)
            manifest = (dest / 'BUILD-MANIFEST.txt').read_bytes()
            out = root / 'output'
            env = {'FFMPEG_SOURCE': 'asset', 'GITHUB_SHA': 'a' * 40,
                   'GITHUB_OUTPUT': str(out)}
            with mock.patch.object(cache, 'DEST', dest), \
                    mock.patch.object(cache, 'ROOT', root), \
                    mock.patch.object(cache, 'FFMPEG_DEPS_TREE_DIGEST',
                                      cache.tree_digest(dest)), \
                    mock.patch.dict(os.environ, env):
                cache.verify()
                self.assertIn('sha=' + cache.sha256_file(dest / 'ffmpeg.exe'),
                              out.read_text())
                self.assertEqual((dest / 'BUILD-MANIFEST.txt').read_bytes(), manifest)
                # A self-consistent rewrite of exe + manifest still moves the tree.
                old = cache.sha256_file(dest / 'ffmpeg.exe')
                (dest / 'ffmpeg.exe').write_bytes(b'MZ' + b'Y' * (11 * 1024 * 1024))
                (dest / 'BUILD-MANIFEST.txt').write_bytes(
                    manifest.replace(old.encode(),
                                     cache.sha256_file(dest / 'ffmpeg.exe').encode()))
                with self.assertRaisesRegex(RuntimeError, 'prebuilt dependency tree digest'):
                    cache.verify()

    def test_prebuilt_asset_is_refused_when_build_script_drifted(self):
        self.cache = self.helper()
        cache = self.cache
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dest = self.bundle_with_dependency(
                root, script_bytes=b'# the repository build script moved on\n')
            env = {'FFMPEG_SOURCE': 'asset', 'GITHUB_SHA': 'a' * 40,
                   'GITHUB_OUTPUT': str(root / 'output')}
            with mock.patch.object(cache, 'DEST', dest), \
                    mock.patch.object(cache, 'ROOT', root), \
                    mock.patch.object(cache, 'FFMPEG_DEPS_TREE_DIGEST',
                                      cache.tree_digest(dest)), \
                    mock.patch.dict(os.environ, env):
                with self.assertRaisesRegex(RuntimeError, 'build script differs'):
                    cache.verify()

    def test_fetch_rejects_archive_with_wrong_digest(self):
        self.cache = self.helper()
        cache = self.cache
        payload = b'not the pinned bytes'

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = {'GITHUB_OUTPUT': str(root / 'output')}
            with mock.patch.object(cache, 'ROOT', root), \
                    mock.patch.object(cache, 'DEST', root / 'client/windows/ffmpeg'), \
                    mock.patch('urllib.request.urlopen', return_value=Response()), \
                    mock.patch.dict(os.environ, env):
                with self.assertRaisesRegex(RuntimeError, 'archive sha256 mismatch'):
                    cache.fetch()

    def test_tree_digest_binds_names_and_license_bytes(self):
        self.cache = self.helper()
        cache = self.cache
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            p = root / 'LICENSE'
            p.write_bytes(b'license')
            original = cache.tree_digest(root)
            p.rename(root / 'OTHER')
            self.assertNotEqual(cache.tree_digest(root), original)


if __name__ == '__main__':
    unittest.main()
