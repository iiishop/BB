"""F2 online retry: real Dart/FastAPI, stock host; one explicit injected failure."""

import json
from pathlib import Path

import httpx


def run(*, origin, account, api, runtime, root, private, launch, record, **unused):
    for cut in ["context", "prepared", "pending"]:
        peer = httpx.post(
            api + "/auth/register",
            json={"username": "online-" + cut, "password": "Abc123"},
            trust_env=False,
        ).json()["account"]
        token = httpx.post(
            api + "/auth/login",
            json={"account": peer, "password": "Abc123"},
            trust_env=False,
        ).json()["token"]
        for n in [1, 2]:
            response = httpx.post(
                api + "/messages",
                headers={"Authorization": "Bearer " + token},
                json={
                    "target_account": account,
                    "client_nonce": f"online-{cut}-{n}",
                    "content": [{"type": "text", "text": f"online input {n}"}],
                },
                trust_env=False,
            )
            assert response.status_code == 200
        config = private / f"online-{cut}.json"
        config.write_text(json.dumps({"origin": origin, "peer": peer, "cut": cut}))
        worker = launch(
            [
                "node",
                str(Path(__file__).parent.parent / "product/online.mjs"),
                runtime,
                str(root / cut),
                str(config),
            ],
            "online-" + cut,
            pipe=True,
        )
        stdout, stderr = worker.communicate(timeout=45)
        result = json.loads(stdout) if stdout else {"status": "FAIL"}
        record("online-" + cut, **result)
        assert worker.returncode == 0, stderr[-3000:]
