"""Foreground stock DSH lifecycle against real standalone Dart and server."""

import argparse
import base64
import hashlib
import json
import os
import subprocess
from pathlib import Path

from space_live import REPO, Live

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--runtime", required=True, type=Path)
args = parser.parse_args()
runtime = args.runtime.resolve()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
files = [
    runtime / "package.json",
    *runtime.glob("node_modules/@deepseek-ai/dsh-*/lib/index.js"),
]


def hashes():
    return {
        str(p.relative_to(runtime)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in files
    }


before = hashes()
with Live() as live:
    account = live.register("NativeSpace")
    live.login(account)
    # Two valid synthetic PNG fixtures, no model credentials.
    import struct
    import zlib

    def png(rgb):
        def chunk(kind, data):
            return (
                struct.pack(">I", len(data))
                + kind
                + data
                + struct.pack(">I", zlib.crc32(kind + data))
            )

        return base64.b64encode(
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes([0, *rgb])))
            + chunk(b"IEND", b"")
        ).decode()

    config = live.root / "native-config.json"
    config.write_text(
        json.dumps(
            {
                "origin": live.local,
                "api": live.api,
                "account": account,
                "images": [png((255, 0, 0)), png((0, 0, 255))],
            }
        )
    )
    bundle = live.root / "bundle"
    subprocess.run(
        [
            "uv",
            "run",
            "--project",
            "dsh-plugin",
            "--locked",
            "python",
            "dsh-plugin/build_bundle.py",
            str(bundle),
        ],
        cwd=REPO,
        check=True,
    )
    native = live.root / "native"
    env = {k: os.environ[k] for k in ["PATH", "LANG"] if k in os.environ}
    env.update(DSH_HOME=str(native / "home"), DSH_TELEMETRY_DISABLED="1")
    command = [
        "node",
        str(REPO / "dsh-plugin/probes/product/space-installed.mjs"),
        str(runtime),
        str(native),
        str(bundle),
        str(config),
    ]
    # Explicit child ownership and PID check even on failure/timeout.
    with (output / "native.log").open("w") as log:
        proc = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=log)
        live.children.append((proc, log))
        try:
            code = proc.wait(timeout=180)
        except subprocess.TimeoutExpired:
            live.stop(proc)
            raise
    (output / "host-result.json").write_text(
        json.dumps(
            {
                "exit_code": code,
                "runtime_version": json.loads((runtime / "package.json").read_text())[
                    "version"
                ],
                "unchanged_dependencies": before == hashes(),
                "host_hashes": before,
            },
            indent=2,
        )
    )
    assert before == hashes()
    assert code == 0, (output / "native.log").read_text()[-6000:]
    (output / "space-installed.json").write_bytes(
        (native / "space-installed.json").read_bytes()
    )
print("stock DSH installed Space lifecycle PASS")
