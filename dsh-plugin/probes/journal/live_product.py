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
    import os

    if os.environ.get("BB_PRODUCT_CASES") == "online":
        from live_online import run as run_online

        return run_online(
            origin=origin,
            account=account,
            api=api,
            runtime=runtime,
            root=root,
            private=private,
            launch=launch,
            record=record,
            **unused,
        )

    if os.environ.get("BB_PRODUCT_CASES") == "profile":
        from live_profile import run as run_profile

        return run_profile(
            api=api,
            peer=peer,
            root=root,
            private=private,
            launch=launch,
            stop=stop,
            record=record,
            **unused,
        )

    if os.environ.get("BB_PRODUCT_CASES") == "gap":
        from live_gap import run as run_gap

        return run_gap(
            origin=origin,
            account=account,
            peer=peer,
            api=api,
            runtime=runtime,
            root=root,
            private=private,
            launch=launch,
            stop=stop,
            record=record,
            **unused,
        )
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
    cuts = [
        "claimed",
        "wait-claimed",
        "wait-confirmed",
        "pending",
        "dispatching",
        "provider-unknown",
        "turn-success",
        "confirmed",
        "acked",
        "operation-result",
        "download-result",
    ]
    if os.environ.get("BB_PRODUCT_CASES") == "installed":
        cuts = []
    if os.environ.get("BB_PRODUCT_CASES") == "cover":
        import secrets

        owner = secrets.token_urlsafe(32)
        auth = httpx.post(origin + "/v2/status", json={}, trust_env=False).json()[
            "auth"
        ]
        identity = httpx.post(
            origin + "/v2/consumers/create",
            json={"expected_auth": auth, "session_id": "nullable-cover"},
            headers={"X-BB-Consumer-Key": owner},
            trust_env=False,
        ).json()["identity"]
        body = {
            "expected_identity": identity,
            "target_account": peer,
            "operation_id": "nullable-cover",
            "source": {
                "base64": "c3ludGhldGlj",
                "mime_type": "text/plain",
                "filename": "probe.txt",
            },
        }
        missing = httpx.post(
            origin + "/v2/chat/send_attachment",
            json=body,
            headers={"X-BB-Consumer-Key": owner},
            trust_env=False,
        )
        explicit = httpx.post(
            origin + "/v2/chat/send_attachment",
            json={**body, "cover": None},
            headers={"X-BB-Consumer-Key": owner},
            trust_env=False,
        )
        assert missing.status_code == 200 and explicit.status_code == 200
        assert missing.json() == explicit.json(), "same operation must reconcile"
        record(
            "nullable-cover-wire",
            status="PASS",
            missing_cover=200,
            explicit_null=200,
            expected_missing_cover=200,
            same_operation_reconciled=True,
        )
        return
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
