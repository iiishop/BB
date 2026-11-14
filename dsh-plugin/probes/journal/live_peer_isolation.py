"""DEA-470 real client/MCP/host regression; synthetic identities, no model secrets."""

import json
from pathlib import Path

import httpx


def run(
    *, origin, account, peer, api, runtime, root, private, launch, record, **unused
):
    response = httpx.post(
        api + "/auth/register",
        json={"username": "isolation-peer", "password": "Abc123"},
        trust_env=False,
    )
    assert response.status_code == 201
    peer_b = response.json()["account"]
    config = private / "peer-isolation.json"
    config.write_text(
        json.dumps(
            {
                "origin": origin,
                "api": api,
                "account": account,
                "peer": peer,
                "peerB": peer_b,
            }
        ),
        encoding="utf-8",
    )
    for phase in ["seed", "cold"]:
        child = launch(
            [
                "node",
                str(Path(__file__).parent.parent / "product/peer-isolation.mjs"),
                runtime,
                str(root),
                str(config),
                phase,
            ],
            "peer-isolation-" + phase,
            pipe=True,
        )
        stdout, stderr = child.communicate(timeout=50)
        assert child.returncode == 0, stderr[-3000:]
        result = json.loads(stdout)
        assert result["status"] == "PASS"
        record("peer-isolation-" + phase, **result)
