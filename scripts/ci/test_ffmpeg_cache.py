"""Cache integrity is anchored in the Actions key, not the mutable manifest."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import os
from unittest import mock

from test_package_windows import make_bundle


class CacheTests(unittest.TestCase):
    def helper(self):
        self.assertIsNotNone(importlib.util.find_spec('ffmpeg_cache'))
        import ffmpeg_cache
        return ffmpeg_cache

    def test_tree_digest_detects_exe_and_manifest_rewrite(self):
        cache = self.helper()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'ffmpeg.exe').write_bytes(b'MZoriginal')
            (root / 'BUILD-MANIFEST.txt').write_text('sha=original')
            original = cache.tree_digest(root)
            (root / 'ffmpeg.exe').write_bytes(b'MZtampered')
            (root / 'BUILD-MANIFEST.txt').write_text('sha=tampered')
            with self.assertRaisesRegex(RuntimeError, 'cache content digest'):
                cache.verify_tree(root, original)

    def test_hit_entrypoint_validates_before_packaging_and_preserves_provenance(self):
        cache = self.helper()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle = make_bundle(root / 'bundle', ffmpeg_payload=b'MZ' + b'X' * (11 * 1024 * 1024))
            dest = bundle / 'ffmpeg'
            script = root / cache.INPUTS[2]
            script.parent.mkdir(parents=True)
            script.write_bytes((dest / 'BUILD-FFMPEG.sh').read_bytes())
            manifest = (dest / 'BUILD-MANIFEST.txt').read_bytes()
            output = root / 'output'
            env = {'CACHE_HIT': 'true', 'CACHE_PREFIX': 'exact-',
                   'CACHE_KEY': 'exact-' + cache.tree_digest(dest),
                   'GITHUB_SHA': 'a' * 40, 'GITHUB_OUTPUT': str(output)}
            with mock.patch.object(cache, 'DEST', dest), mock.patch.object(cache, 'ROOT', root), \
                    mock.patch.dict(os.environ, env), \
                    mock.patch.object(cache, 'toolchain_digest', side_effect=AssertionError('hit must not install/recheck build tools')):
                cache.verify()
                self.assertIn('sha=' + cache.sha256_file(dest / 'ffmpeg.exe'), output.read_text())
                self.assertEqual((dest / 'BUILD-MANIFEST.txt').read_bytes(), manifest)
                old_hash = cache.sha256_file(dest / 'ffmpeg.exe')
                (dest / 'ffmpeg.exe').write_bytes(b'MZ' + b'Y' * (11 * 1024 * 1024))
                (dest / 'BUILD-MANIFEST.txt').write_bytes(manifest.replace(old_hash.encode(), cache.sha256_file(dest / 'ffmpeg.exe').encode()))
                with self.assertRaisesRegex(RuntimeError, 'cache content digest'):
                    cache.verify()

    def test_exact_input_and_ref_only(self):
        cache = self.helper()
        entries = [
            {'key': 'input-old-' + 'a'*64, 'ref': 'refs/heads/test'},
            {'key': 'input-new-' + 'b'*64, 'ref': 'refs/heads/main'},
            {'key': 'input-new-' + 'c'*64, 'ref': 'refs/heads/test'},
            {'key': 'input-new-invalid', 'ref': 'refs/heads/test'},
        ]
        self.assertEqual(cache.select_key(entries, 'input-new-', 'refs/heads/test'),
                         'input-new-' + 'c'*64)
        self.assertIsNone(cache.select_key(entries, 'different-', 'refs/heads/test'))

    def test_tree_digest_binds_names_and_license_bytes(self):
        cache = self.helper()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            p = root / 'LICENSE'
            p.write_bytes(b'license')
            original = cache.tree_digest(root)
            p.rename(root / 'OTHER')
            self.assertNotEqual(cache.tree_digest(root), original)


if __name__ == '__main__':
    unittest.main()
