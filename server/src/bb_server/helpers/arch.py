"""Install as /usr/local/libexec/bb-public-helper (root:root 0755).

Standalone stdlib helper: fixed operations, JSON stdin, no user paths/commands.
Only invoke after the local OS authorizes elevation; never run BB itself as root.
"""

import base64
import fcntl
import hashlib
import json
import os
import platform
import subprocess
import sys
from pathlib import Path
from uuid import UUID

ROOT = Path("/var/lib/bb-public")
UNITS = Path("/etc/systemd/system")


def request(value):
    if not isinstance(value, dict):
        raise TypeError()
    if set(value) - {"action", "task_id", "instance_id", "token"}:
        raise ValueError()
    if value.get("action") not in ("install", "connect"):
        raise ValueError()
    for name in ("task_id", "instance_id"):
        if (
            not isinstance(value.get(name), str)
            or str(UUID(value[name])) != value[name]
        ):
            raise ValueError()
    if value["action"] == "connect":
        token = value.get("token", "")
        if not isinstance(token, str) or not 1 <= len(token) <= 4096:
            raise ValueError()
        decoded = json.loads(
            base64.b64decode(token + "=" * (-len(token) % 4), validate=True)
        )
        UUID(decoded["t"])
        if len(base64.b64decode(decoded["s"], validate=True)) < 32:
            raise ValueError()
    elif "token" in value:
        raise ValueError()
    return value


def private_directory(path):
    if path.is_symlink():
        raise ValueError()
    path.mkdir(mode=0o700, exist_ok=True)
    stat = path.stat()
    if stat.st_uid != 0 or stat.st_mode & 0o077:
        raise ValueError()


def write_once(path, data, mode=0o600):
    try:
        descriptor = os.open(
            path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode
        )
    except FileExistsError:
        if (
            path.is_symlink()
            or path.stat().st_uid != 0
            or path.stat().st_mode & 0o777 != mode
            or path.read_bytes() != data
        ):
            raise ValueError()
        return
    with os.fdopen(descriptor, "wb") as file:
        os.fchmod(file.fileno(), mode)
        file.write(data)
        file.flush()
        os.fsync(file.fileno())


def run(args):
    completed = subprocess.run(
        args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=180,
        check=False,
        env={"PATH": "/usr/bin:/bin", "LANG": "C"},
    )
    if completed.returncode:
        raise RuntimeError()


def unit(instance):
    return (
        "[Unit]\nDescription=BB owned cloudflared tunnel\nAfter=network-online.target\nWants=network-online.target\n"
        "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\nProtectSystem=strict\nProtectHome=yes\nPrivateTmp=yes\n"
        f"LoadCredential=token:{ROOT}/{instance}/token\n"
        "ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token-file ${CREDENTIALS_DIRECTORY}/token\n"
        "Restart=on-failure\n[Install]\nWantedBy=multi-user.target\n"
    ).encode()


def apply(value):
    value = request(value)
    if (
        os.geteuid() != 0
        or platform.machine() not in ("x86_64", "AMD64")
        or "ID=arch" not in Path("/etc/os-release").read_text().splitlines()
    ):
        raise ValueError()
    os.umask(0o077)
    private_directory(ROOT)
    lock = os.open(ROOT / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, "a+b") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if value["action"] == "install":
            # Never update package lists or upgrade/reinstall an existing binary.
            if not Path("/usr/bin/cloudflared").exists():
                run(
                    [
                        "/usr/bin/pacman",
                        "-S",
                        "--needed",
                        "--noconfirm",
                        "extra/cloudflared",
                    ]
                )
            run(["/usr/bin/cloudflared", "--version"])
            return
        instance = value["instance_id"]
        name = f"bb-cloudflared-{instance}.service"
        directory = ROOT / instance
        private_directory(directory)
        expected = unit(instance)
        unit_path = UNITS / name
        # Existing service must match BOTH immutable owner receipt and exact unit/token.
        marker = directory / "owner.json"
        ownership = json.dumps(
            {
                "instance_id": instance,
                "unit_sha256": hashlib.sha256(expected).hexdigest(),
            },
            sort_keys=True,
        ).encode()
        if unit_path.exists() and (
            not marker.exists()
            or marker.is_symlink()
            or marker.read_bytes() != ownership
        ):
            raise ValueError()
        write_once(marker, ownership)
        write_once(directory / "token", value["token"].encode())
        write_once(unit_path, expected, 0o644)
        run(["/usr/bin/systemctl", "daemon-reload"])
        run(["/usr/bin/systemctl", "enable", "--now", name])
        run(["/usr/bin/systemctl", "is-active", "--quiet", name])


def main():
    try:
        data = sys.stdin.buffer.read(8193)
        if len(data) > 8192:
            raise ValueError()
        apply(json.loads(data))
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        RuntimeError,
        subprocess.SubprocessError,
    ):
        # No exception string, raw subprocess output, token or request echo.
        print('{"ok":false,"code":"local_operation_failed"}')
        return 1
    print('{"ok":true}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
