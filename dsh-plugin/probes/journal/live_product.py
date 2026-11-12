"""Product A/B/C crashes: stock native DSH, actual Dart/FastAPI, fixed model double."""

import json
import select
import signal
from pathlib import Path

import httpx


def run(
    *,
    origin,
    account,
    peer,
    api,
    runtime,
    root,
    private,
    launch,
    stop,
    record,
    **unused,
):
    token = httpx.post(
        api + "/auth/login",
        json={"account": peer, "password": "Abc123"},
        trust_env=False,
    ).json()["token"]
    response = httpx.post(
        api + "/messages",
        headers={"Authorization": "Bearer " + token},
        json={
            "target_account": account,
            "client_nonce": "product-recovery-inbound",
            "content": [{"type": "text", "text": "synthetic product recovery input"}],
        },
        trust_env=False,
    )
    assert response.status_code == 200
    config = private / "product.json"
    import base64
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

    config.write_text(
        json.dumps(
            {
                "origin": origin,
                "peer": peer,
                "images": [png((255, 0, 0)), png((0, 0, 255))],
            }
        )
    )
    here = Path(__file__).parent
    failures = []
    import os

    cuts = [
        "claimed",
        "wait-claimed",
        "pending",
        "dispatching",
        "provider-unknown",
        "turn-success",
        "confirmed",
        "acked",
        "operation-result",
    ]
    if os.environ.get("BB_PRODUCT_CASES") == "installed":
        cuts = []
    for cut in cuts:
        case_root = root / cut
        case_root.mkdir()
        command = [
            "node",
            str(Path(__file__).parent.parent / "product/recovery.mjs"),
            runtime,
            str(case_root),
            str(config),
            cut,
        ]
        child = launch([*command, "crash"], cut + "-crash", pipe=True)
        try:
            assert select.select([child.stdout], [], [], 25)[0], "barrier timeout"
            line = child.stdout.readline()
            if not line:
                raise AssertionError(child.stderr.read()[-2500:])
            assert json.loads(line)["checkpoint"] == cut
            stop(child, crash=True)
            assert child.returncode == -signal.SIGKILL
            recovery = launch([*command, "recover"], cut + "-recover", pipe=True)
            stdout, stderr = recovery.communicate(timeout=25)
            assert recovery.returncode == 0, stderr[-2500:]
            result = json.loads(stdout)
            record("product-" + cut, **result)
        except Exception as error:  # noqa: BLE001 - aggregate independent gates
            failures.append(cut)
            record("product-" + cut, status="FAIL", detail=str(error))
        finally:
            stop(child)
    bundle = root / "bundle"
    import subprocess

    subprocess.run(
        ["python3", str(here.parent.parent / "build_bundle.py"), str(bundle)],
        check=True,
        capture_output=True,
    )
    install_root = root / "installed"
    install_root.mkdir()
    child = launch(
        [
            "node",
            str(here.parent / "product/installed.mjs"),
            runtime,
            str(install_root),
            str(bundle),
            str(config),
        ],
        "installed",
        env=dict(__import__("os").environ, DSH_HOME=str(install_root / "home")),
        pipe=True,
    )
    stdout, stderr = child.communicate(timeout=90)
    if child.returncode:
        record("installed-product", status="FAIL", detail=stderr[-3000:])
        failures.append("installed")
    else:
        record("installed-product", status="PASS", **json.loads(stdout))
    assert not failures, failures
