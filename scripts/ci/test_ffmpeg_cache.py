"""Cache integrity is anchored in the Actions key, not the mutable manifest."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


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
