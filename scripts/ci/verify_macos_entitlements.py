"""Validate the outgoing-only macOS release sandbox (source or signed plist)."""
import plistlib
import sys


def verify(path):
    with open(path, "rb") as file:
        entitlements = plistlib.load(file)
    for key in ("com.apple.security.app-sandbox", "com.apple.security.network.client"):
        if entitlements.get(key) is not True:
            raise ValueError(f"{key} must be the Boolean true")
    for key in ("com.apple.security.network.server", "com.apple.security.cs.allow-jit"):
        if key in entitlements:
            raise ValueError(f"{key} must be absent from the release signature")


if __name__ == "__main__":
    verify(sys.argv[1])
