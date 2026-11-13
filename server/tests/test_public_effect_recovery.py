"""Malformed replies exercise real parsing and persistence, not only error doubles."""

from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import pytest
import test_public_runtime as cases
from bb_auth_contract import ContractError
from bb_auth_contract.admin import DraftSave, ProbeStart, TaskAuthorization
from test_public_runtime import TOKEN, execute, plan

from bb_server.public_cloud import Cloudflare, PublicFailure
from bb_server.public_runtime import PublicRuntime

runtime = cases.runtime


def restart(service, cloud, adapter, verifier):
    value = PublicRuntime(
        service.store.path,
        business_port=8000,
        challenge_directory=service.store.path.parent / "challenges",
        cloud_factory=lambda token: cloud,
        adapter=adapter,
        verifier=verifier,
        clock=lambda: 1000,
    )
    value.store.migrate()
    return value


@pytest.mark.parametrize("step", ["tunnel", "ingress", "dns"])
@pytest.mark.parametrize(
    "bad", [{}, {"id": "invalid"}, None, [], "secret-invalid-response"]
)
def test_malformed_write_reply_cold_restart_reconciles_same_task(
    runtime, monkeypatch, step, bad
):
    service, cloud, adapter, verifier = runtime
    confirmed = plan(service)
    name = {"tunnel": "create_tunnel", "ingress": "configure", "dns": "create_record"}[
        step
    ]
    original = getattr(cloud, name)

    def transport(method, path, payload):
        if step == "tunnel":
            assert method == "POST" and path.endswith("/cfd_tunnel")
            original(cloud.account_id, payload["name"], payload["tunnel_secret"])
        elif step == "dns":
            assert method == "POST" and path.endswith("/dns_records")
            original(
                cloud.zone_id, payload["name"], cloud.items[0]["id"], payload["comment"]
            )
        else:
            assert method == "PUT" and path.endswith("/configurations")
            original(
                cloud.account_id, cloud.items[0]["id"], "bb.example.com", service.target
            )
            # PUT has no resource id to consume: malformed ENVELOPE is uncertain.
            return bad
        return {"success": True, "result": bad}

    parser = Cloudflare("synthetic", transport)
    monkeypatch.setattr(cloud, name, getattr(parser, name))
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    snapshot = service.store.get(task.task_id)
    assert snapshot.stage == "awaiting_authorization"
    assert snapshot.classification == "unknown"
    assert "secret-invalid-response" not in snapshot.model_dump_json()
    assert service.credentials == {}
    assert service.store.config().active is None
    # Retry/double-click of the exact confirmed plan remains the original task.
    with ThreadPoolExecutor(max_workers=4) as pool:
        repeats = list(
            pool.map(lambda _: execute(service, confirmed).task_id, range(4))
        )
    assert set(repeats) == {task.task_id}
    with pytest.raises(ContractError) as error:
        service.admit(ProbeStart(expected_version=1, idempotency_key=uuid4()), "probe")
    assert error.value.status == 409
    with pytest.raises(ContractError):
        service.store.save(DraftSave(expected_version=1, domain="other.example.com"))
    # Recreating the executor drops all memory. Actual resource reads, not the
    # still-broken mutation parser, must recover each sent intent without a POST.
    recovered = restart(service, cloud, adapter, verifier)
    recovered.run_one(task.task_id)
    assert recovered.store.current().task_id == task.task_id
    recovered.authorize(task.task_id, TaskAuthorization(management_token=TOKEN))
    recovered.run_one(task.task_id)
    result = recovered.store.get(task.task_id)
    assert result.classification == "passed"
    assert recovered.store.config().active.domain == "bb.example.com"
    assert cloud.calls == {"tunnel": 1, "ingress": 1, "dns": 1}
    assert len(cloud.items) == len(cloud.dns) == 1
    assert adapter.calls == ["connect"]
    assert [seq for seq, _ in recovered.store.events(task.task_id, 0)] == list(
        range(1, result.seq + 1)
    )
    assert restart(service, cloud, adapter, verifier).store.get(task.task_id) == result


@pytest.mark.parametrize("step", ["package", "service"])
@pytest.mark.parametrize("error", [TypeError, RuntimeError])
def test_unexpected_local_reply_keeps_ownership_until_readback(
    runtime, monkeypatch, step, error
):
    service, cloud, adapter, verifier = runtime
    if step == "package":
        adapter.installed = False
    confirmed = plan(service, "install" if step == "package" else "create_and_connect")
    original = adapter.apply

    def apply(*args):
        original(*args)
        raise error("PRIVATE_RUNTIME_TOKEN")

    monkeypatch.setattr(adapter, "apply", apply)
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    result = service.store.get(task.task_id)
    assert result.stage == "awaiting_local_admin"
    assert result.classification == "unknown"
    assert "PRIVATE_RUNTIME_TOKEN" not in result.model_dump_json()
    recovered = restart(service, cloud, adapter, verifier)
    recovered.run_one(task.task_id)
    if step == "service":
        recovered.authorize(task.task_id, TaskAuthorization(management_token=TOKEN))
        recovered.run_one(task.task_id)
    assert recovered.store.get(task.task_id).classification == "passed"
    assert adapter.calls == ["install" if step == "package" else "connect"]


@pytest.mark.parametrize(
    "error", [KeyError, ValueError, TypeError, AttributeError, IndexError, RuntimeError]
)
def test_unexpected_cloud_error_after_send_cannot_release_target(
    runtime, monkeypatch, error
):
    service, cloud, _, _ = runtime
    confirmed = plan(service)
    original = cloud.create_tunnel

    def create(*args):
        original(*args)
        raise error("PRIVATE_TOKEN")

    monkeypatch.setattr(cloud, "create_tunnel", create)
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).stage == "awaiting_authorization"
    assert service.credentials == {}
    # Even a later explicit conflict cannot finalize the unresolved sent write.
    monkeypatch.setattr(
        cloud,
        "inspect",
        lambda _: (_ for _ in ()).throw(PublicFailure("conflict", "conflict")),
    )
    service.authorize(task.task_id, TaskAuthorization(management_token=TOKEN))
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).stage == "awaiting_authorization"
    assert service.store.get(task.task_id).issue_code == "effect_result_unknown"
    assert cloud.calls["tunnel"] == len(cloud.items) == 1


def test_sent_tunnel_unreadable_on_reconciliation_remains_owned(runtime, monkeypatch):
    service, cloud, adapter, verifier = runtime
    cloud.lose = "tunnel"
    task = execute(service, plan(service))
    service.run_one(task.task_id)
    recovered = restart(service, cloud, adapter, verifier)
    original = cloud.tunnels
    parser = Cloudflare(
        "synthetic", lambda *args: {"success": True, "result": [{"name": "no id"}]}
    )
    monkeypatch.setattr(cloud, "tunnels", parser.tunnels)
    recovered.authorize(task.task_id, TaskAuthorization(management_token=TOKEN))
    recovered.run_one(task.task_id)
    assert recovered.store.get(task.task_id).stage == "awaiting_authorization"
    monkeypatch.setattr(cloud, "tunnels", original)
    recovered.authorize(task.task_id, TaskAuthorization(management_token=TOKEN))
    recovered.run_one(task.task_id)
    assert recovered.store.get(task.task_id).classification == "passed"
    assert cloud.calls == {"tunnel": 1, "ingress": 1, "dns": 1}
