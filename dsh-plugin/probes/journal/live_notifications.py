"""DEA-474 actual wait A/B and process crash boundaries; no model credentials."""
import json
import select
import signal
from pathlib import Path


def run(*, origin, account, peer, switched, api, runtime, root, private, launch, stop, restart, record, **unused):
    config = private / "notifications.json"
    config.write_text(json.dumps({"origin": origin, "api": api, "account": account, "peer": peer, "other": switched}))
    from bb_auth_contract import chat_v2 as v2
    def validate_wire(case):
        count = 0
        models = {path: (request, response) for path, request, response, _, _ in v2.BUSINESS.values()}
        for line in (case / "wire.jsonl").read_text().splitlines():
            value = json.loads(line)
            request, response = models[value["path"]]
            request.model_validate(value["body"])
            response.model_validate(value["reply"])
            count += 1
        return count

    script = Path(__file__).parent.parent / "product/notifications.mjs"
    cuts = ["wait", "scope", "admission", "notification-prepared", "notification-dispatching", "notification-enqueued", "notification-visible", "notification-pending", "notification-committed"]
    # Separate consumer and peer per crash, so assertions don't inherit earlier unread.
    import httpx
    for cut in cuts:
        case = root / cut
        case.mkdir()
        if cut != "wait":
            fresh = httpx.post(api + "/auth/register", json={"username": cut, "password": "Abc123"}, trust_env=False)
            assert fresh.status_code == 201
            config.write_text(json.dumps({"origin": origin, "api": api, "account": account, "peer": fresh.json()["account"], "other": switched}))
        command = ["node", str(script), runtime, str(case), str(config), cut]
        crash_case = cut.startswith("notification-")
        if crash_case:
            child = launch([*command, "crash"], cut + "-crash", pipe=True)
            try:
                assert select.select([child.stdout], [], [], 25)[0], "barrier deadline"
                line = child.stdout.readline()
                assert line, child.stderr.read()[-3000:]
                assert json.loads(line)["checkpoint"] == cut
                stop(child, crash=True)
                assert child.returncode == -signal.SIGKILL
            finally:
                stop(child)
        child = launch([*command, "recover" if crash_case else "run"], cut, pipe=True)
        stdout, stderr = child.communicate(timeout=45)
        assert child.returncode == 0, stderr[-4000:]
        record("notifications-" + cut, wire_contract_checks=validate_wire(case), **json.loads(stdout))

    case = root / "offline"
    case.mkdir()
    fresh = httpx.post(api + "/auth/register", json={"username": "offline-peer", "password": "Abc123"}, trust_env=False).json()["account"]
    config.write_text(json.dumps({"origin": origin, "api": api, "account": account, "peer": fresh, "other": switched}))
    command = ["node", str(script), runtime, str(case), str(config), "offline"]
    child = launch([*command, "seed"], "offline-seed", pipe=True)
    stdout, stderr = child.communicate(timeout=30)
    assert child.returncode == 0, stderr[-3000:]
    record("notifications-offline-seed", **json.loads(stdout))
    token = httpx.post(api + "/auth/login", json={"account": fresh, "password": "Abc123"}, trust_env=False).json()["token"]
    for n in range(3):
        reply = httpx.post(api + "/messages", json={"target_account": account, "client_nonce": f"offline-{n}", "content": [{"type": "text", "text": f"offline-{n}"}]}, headers={"Authorization": "Bearer " + token}, trust_env=False)
        assert reply.status_code == 200
    restart(crash=True)
    assert httpx.post(origin + "/auth/login", json={"account": account, "password": "Abc123"}, trust_env=False).status_code == 200
    child = launch([*command, "recover"], "offline-recover", pipe=True)
    stdout, stderr = child.communicate(timeout=30)
    assert child.returncode == 0, stderr[-3000:]
    record("notifications-offline-recover", wire_contract_checks=validate_wire(case), **json.loads(stdout))
