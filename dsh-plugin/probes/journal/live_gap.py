"""R3: real HTTP/MCP queries, stock native turns, disk journal and process restart."""

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
    restart,
    record,
    **unused,
):
    token = httpx.post(
        api + "/auth/login",
        json={"account": peer, "password": "Abc123"},
        trust_env=False,
    ).json()["token"]
    # Each query has its own peer/stream so both begin at cursor zero.
    failures = []
    for query in ["get_message", "get_context"]:
        if query == "get_context":
            registered = httpx.post(
                api + "/auth/register",
                json={"username": "gap-context-peer", "password": "Abc123"},
                trust_env=False,
            )
            assert registered.status_code == 201, registered.status_code
            peer = registered.json()["account"]
            token = httpx.post(
                api + "/auth/login",
                json={"account": peer, "password": "Abc123"},
                trust_env=False,
            ).json()["token"]
        for n in range(1, 4):
            response = httpx.post(
                api + "/messages",
                headers={"Authorization": "Bearer " + token},
                json={
                    "target_account": account,
                    "client_nonce": f"r3-{query}-{n}",
                    "content": [{"type": "text", "text": f"synthetic gap {n}"}],
                },
                trust_env=False,
            )
            assert response.status_code == 200, response.status_code
        config = private / f"gap-{query}.json"
        config.write_text(
            json.dumps(
                {
                    "origin": origin,
                    "peer": peer,
                    "query": query,
                    "message_id": response.json()["id"],
                }
            )
        )
        target = root / query
        target.mkdir()
        command = [
            "node",
            str(Path(__file__).parent.parent / "product/gap.mjs"),
            runtime,
            str(target),
            str(config),
        ]
        child = launch([*command, "seed"], query + "-seed", pipe=True)
        try:
            assert select.select([child.stdout], [], [], 40)[0], "seed deadline"
            line = child.stdout.readline()
            assert line, child.stderr.read()[-3000:]
            result = json.loads(line)
            assert result["checkpoint"] == "gap-durable"
            record(query + "-seed", **result)
            stop(child, crash=True)
            assert child.returncode == -signal.SIGKILL
            restart(crash=True)
            for phase in ["recover", "replay"]:
                worker = launch([*command, phase], query + "-" + phase, pipe=True)
                stdout, stderr = worker.communicate(timeout=40)
                result = json.loads(stdout) if stdout else {"status": "FAIL"}
                record(query + "-" + phase, **result)
                assert worker.returncode == 0, stderr[-3000:]
        except Exception as error:  # noqa: BLE001 - report both independent queries
            record(query + "-gate", status="FAIL", detail=str(error))
            failures.append(query)
        finally:
            stop(child)
    assert not failures, failures
