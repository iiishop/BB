"""Real client/native context initialization; model double is explicit."""

import base64
import json
import struct
import zlib
from pathlib import Path

import httpx


def run(
    *, origin, account, peer, api, runtime, root, private, launch, record, **unused
):
    token = httpx.post(
        api + "/auth/login",
        json={"account": peer, "password": "Abc123"},
        trust_env=False,
    ).json()["token"]
    headers = {"Authorization": "Bearer " + token}

    def send(n, content):
        r = httpx.post(
            api + "/messages",
            headers=headers,
            json={
                "target_account": account,
                "client_nonce": "context-" + str(n),
                "content": content,
            },
            trust_env=False,
        )
        assert r.status_code == 200

    def png(rgb):
        def chunk(kind, data):
            return (
                struct.pack(">I", len(data))
                + kind
                + data
                + struct.pack(">I", zlib.crc32(kind + data))
            )

        return (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes([0, *rgb])))
            + chunk(b"IEND", b"")
        )

    media = []
    for rgb in [(255, 0, 0), (0, 0, 255)]:
        r = httpx.post(
            api + "/media",
            headers=headers,
            data={"target_account": account},
            files={"file": ("synthetic.png", png(rgb), "image/png")},
            trust_env=False,
        )
        assert r.status_code == 200
        media.append(r.json()["media_id"])
    send(1, [{"type": "text", "text": "synthetic context one"}])
    send(
        2,
        [
            {"type": "text", "text": "before-red"},
            {"type": "image", "media_id": media[0]},
            {"type": "text", "text": "between-colors"},
            {"type": "image", "media_id": media[1]},
        ],
    )
    send(3, [{"type": "text", "text": "synthetic context three"}])
    config = private / "context.json"
    config.write_text(
        json.dumps(
            {
                "origin": origin,
                "peer": peer,
                "images": [
                    base64.b64encode(png(rgb)).decode()
                    for rgb in [(255, 0, 0), (0, 0, 255)]
                ],
            }
        )
    )
    target = root / "native-context"
    target.mkdir()
    for phase, position in [
        ("seed", None),
        ("new", 4),
        ("resume", 5),
        ("rebuilt", 6),
        ("uncertain", 7),
        ("lost", None),
    ]:
        if position:
            send(
                position,
                [{"type": "text", "text": "synthetic increment " + str(position)}],
            )
        child = launch(
            [
                "node",
                str(Path(__file__).parent.parent / "product/context.mjs"),
                runtime,
                str(target),
                str(config),
                phase,
            ],
            "context-" + phase,
            pipe=True,
        )
        stdout, stderr = child.communicate(timeout=30)
        assert child.returncode == 0, stderr[-3000:]
        result = json.loads(stdout)
        record("context-" + phase, **result)
