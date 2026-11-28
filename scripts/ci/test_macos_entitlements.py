import plistlib
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from verify_macos_entitlements import verify


class ReleaseEntitlementsTest(unittest.TestCase):
    def test_release_entitlements_allow_outgoing_connections_in_the_sandbox(self):
        project = Path(__file__).resolve().parents[2]
        verify(project / "client/macos/Runner/Release.entitlements")

    def test_rejects_a_signature_without_the_outgoing_entitlement(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "signed.plist"
            path.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
            with self.assertRaisesRegex(ValueError, r"com\.apple\.security\.network\.client"):
                verify(path)
