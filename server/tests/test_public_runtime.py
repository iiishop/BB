import json
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import pytest
from bb_auth_contract import ContractError
from bb_auth_contract.admin import (
    DraftSave,
    PlanCreate,
    PlanExecute,
    ProbeStart,
    TaskAuthorization,
)
from public_fixture import FakeCloud, FakePlatform, FakeVerifier

from bb_server.admin_storage import AdminStore
from bb_server.public_cloud import PublicFailure
from bb_server.public_runtime import PublicRuntime

TOKEN = "synthetic-management-token-never-persist"


@pytest.fixture
def runtime(tmp_path):
    path = tmp_path / "admin.db"
    AdminStore(path, lambda: 1000).migrate()
    cloud, adapter, verifier = (
        FakeCloud(),
        FakePlatform(tmp_path / "private"),
        FakeVerifier(),
    )
    value = PublicRuntime(
        path,
        business_port=8000,
        challenge_directory=tmp_path / "challenges",
        cloud_factory=lambda token: cloud,
        adapter=adapter,
        verifier=verifier,
        clock=lambda: 1000,
    )
    value.store.migrate()
    value.store.save(DraftSave(expected_version=0, domain="bb.example.com"))
    return value, cloud, adapter, verifier


def plan(runtime, action="create_and_connect"):
    task = runtime.admit(
        ProbeStart(expected_version=1, idempotency_key=uuid4(), management_token=TOKEN),
        "probe",
    )
    runtime.run_one(task.task_id)
    observed = runtime.store.get(task.task_id)
    assert observed.stage == "finished", observed
    return runtime.store.plan(
        PlanCreate(expected_version=1, probe_task_id=task.task_id, action=action),
        target=runtime.target,
    )


def execute(runtime, confirmed):
    return runtime.admit(
        PlanExecute(
            plan_id=confirmed.plan_id,
            digest=confirmed.digest,
            expected_version=1,
            idempotency_key=uuid4(),
            confirmed=True,
        ),
        "execute",
    )


def test_no_mutation_before_confirmation_and_success_separates_active(runtime):
    service, cloud, adapter, verifier = runtime
    confirmed = plan(service)
    assert cloud.calls == {"tunnel": 0, "ingress": 0, "dns": 0}
    assert adapter.calls == []
    assert service.store.config().active is None
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    result = service.store.get(task.task_id)
    assert result.classification == "passed", result
    assert result.stage == "finished"
    assert service.store.config().active.domain == "bb.example.com"
    assert cloud.calls == {"tunnel": 1, "ingress": 1, "dns": 1}
    assert adapter.calls == ["connect"]
    assert len(verifier.calls) == 1
    assert {x.kind for x in result.resources} == {"tunnel", "dns", "service"}
    # Credentials may exist only in the private runtime-secret file, never the DB/events.
    assert TOKEN.encode() not in service.store.path.read_bytes()
    assert all(TOKEN not in body for _, body in service.store.events(task.task_id, 0))
    assert all(
        cloud.tokens[cloud.items[0]["id"]].encode() not in p.read_bytes()
        for p in service.store.path.parent.glob("*.db*")
    )


@pytest.mark.parametrize("cut", ["tunnel", "ingress", "dns", "service"])
def test_response_loss_restart_resupply_reconciles_without_duplicate_effects(
    runtime, cut
):
    service, cloud, adapter, verifier = runtime
    confirmed = plan(service)
    if cut == "service":
        adapter.lose = True
    else:
        cloud.lose = cut
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    before = service.store.get(task.task_id)
    assert before.stage in ("awaiting_authorization", "awaiting_local_admin")
    assert service.store.config().active is None
    # New executor object: no in-memory API token or plan held by the browser.
    restarted = PublicRuntime(
        service.store.path,
        business_port=8000,
        challenge_directory=service.verifier,
        cloud_factory=lambda token: cloud,
        adapter=adapter,
        verifier=verifier,
        clock=lambda: 1000,
    )
    restarted.store.migrate()
    restarted.run_one(task.task_id)
    assert restarted.store.current().task_id == task.task_id
    assert restarted.store.current().stage == "awaiting_authorization"
    resumed = restarted.authorize(
        task.task_id, TaskAuthorization(management_token=TOKEN)
    )
    assert resumed.task_id == task.task_id
    restarted.run_one(task.task_id)
    result = restarted.store.get(task.task_id)
    assert result.classification == "passed", result
    assert cloud.calls == {"tunnel": 1, "ingress": 1, "dns": 1}
    assert adapter.calls == ["connect"]
    assert len(cloud.items) == len(cloud.dns) == 1
    sequences = [seq for seq, _ in restarted.store.events(task.task_id, 0)]
    assert sequences == list(range(1, result.seq + 1))
    with pytest.raises(ContractError):
        restarted.authorize(task.task_id, TaskAuthorization(management_token=TOKEN))


def test_unknown_outcome_is_not_treated_as_missing_or_blindly_recreated(
    runtime, monkeypatch
):
    service, cloud, _, _ = runtime
    confirmed = plan(service)

    def lost_before_visible(*args):
        from bb_server.public_cloud import unknown

        raise unknown()

    monkeypatch.setattr(cloud, "create_tunnel", lost_before_visible)
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    service.authorize(task.task_id, TaskAuthorization(management_token=TOKEN))
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).issue_code == "tunnel_create_unknown"
    assert service.store.get(task.task_id).stage == "awaiting_authorization"
    assert service.store.config().active is None


def test_parallel_authorization_has_one_admitted_transition(runtime):
    service, cloud, _, _ = runtime
    task = service.admit(
        ProbeStart(expected_version=1, idempotency_key=uuid4()), "probe"
    )
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).stage == "awaiting_authorization"
    assert len(service.store.get(task.task_id).checks) == 6

    def submit(_):
        try:
            service.authorize(task.task_id, TaskAuthorization(management_token=TOKEN))
            return 202
        except ContractError as error:
            return error.status

    with ThreadPoolExecutor(max_workers=5) as pool:
        assert sorted(pool.map(submit, range(5))) == [202, 409, 409, 409, 409]
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).stage == "finished"
    assert cloud.calls == {"tunnel": 0, "ingress": 0, "dns": 0}


def test_missing_install_is_read_only_and_helper_wait_keeps_task(runtime):
    service, cloud, adapter, _ = runtime
    adapter.installed = False
    confirmed = plan(service, "install")
    assert adapter.calls == [] and not any(cloud.calls.values())
    adapter.denied = True
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).stage == "awaiting_local_admin"
    service.run_one(task.task_id)
    assert adapter.calls == ["install"]  # no repeated UAC/pkexec attempts
    adapter.installed = True  # simulate explicitly approved local helper completion
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).classification == "passed"
    assert service.store.config().active is None


def test_existing_dns_and_third_party_tunnel_are_never_overwritten(runtime):
    service, cloud, adapter, _ = runtime
    cloud.dns = [{"type": "A", "content": "93.184.216.34", "name": "bb.example.com"}]
    task = service.admit(
        ProbeStart(expected_version=1, idempotency_key=uuid4(), management_token=TOKEN),
        "probe",
    )
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).issue_code == "route_conflict"
    assert cloud.calls == {"tunnel": 0, "ingress": 0, "dns": 0}
    assert adapter.calls == []


def test_conflict_arriving_after_plan_stops_before_resource_creation(runtime):
    service, cloud, adapter, _ = runtime
    confirmed = plan(service)
    cloud.dns = [{"type": "AAAA", "content": "2606:4700:4700::1111"}]
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).issue_code == "route_conflict"
    assert not any(cloud.calls.values())
    assert adapter.calls == []


def test_failed_instance_check_never_marks_active_and_keeps_partial_resources(runtime):
    service, cloud, _, verifier = runtime
    task = execute(service, plan(service))
    verifier.fail = True
    service.run_one(task.task_id)
    result = service.store.get(task.task_id)
    assert (
        result.classification == "failed"
        and result.issue_code == "instance_verification_failed"
    )
    assert {x.kind for x in result.resources} == {"tunnel", "dns", "service"}
    assert service.store.config().active is None
    assert len(cloud.items) == len(cloud.dns) == 1


def test_reuse_verified_token_mode_without_cert_file_or_service_reinstall(runtime):
    service, cloud, adapter, verifier = runtime
    first = execute(service, plan(service))
    service.run_one(first.task_id)
    confirmed = plan(service, "verify")
    second = execute(service, confirmed)
    service.run_one(second.task_id)
    assert service.store.get(second.task_id).classification == "passed"
    assert cloud.calls == {"tunnel": 1, "ingress": 1, "dns": 1}
    assert adapter.calls == ["connect"]
    assert len(verifier.calls) == 3


def test_local_mode_recognized_without_claiming_runtime_unavailable(runtime):
    service, cloud, _, _ = runtime
    first = execute(service, plan(service))
    service.run_one(first.task_id)
    cloud.items[0]["remote_config"] = False
    probe = service.admit(
        ProbeStart(expected_version=1, idempotency_key=uuid4(), management_token=TOKEN),
        "probe",
    )
    service.run_one(probe.task_id)
    assert service.store.get(probe.task_id).issue_code == "local_managed_tunnel"
    assert cloud.calls == {"tunnel": 1, "ingress": 1, "dns": 1}


def test_process_lock_prevents_second_executor(runtime):
    service, cloud, adapter, verifier = runtime
    other = PublicRuntime(
        service.store.path,
        business_port=8000,
        challenge_directory=service.verifier,
        cloud_factory=lambda token: cloud,
        adapter=adapter,
        verifier=verifier,
    )
    service.start()
    try:
        with pytest.raises(RuntimeError, match="executor"):
            other.start()
    finally:
        service.close()


def test_task_effects_contain_only_safe_fields(runtime):
    service, _, _, _ = runtime
    task = execute(service, plan(service))
    service.run_one(task.task_id)
    data = json.dumps(service.store.context(task.task_id))
    assert TOKEN not in data and "management_token" not in data


def test_authorization_failure_is_unknown_not_missing(runtime):
    service, cloud, _, _ = runtime

    def denied(domain):
        raise PublicFailure(
            "cloud_authorization_required", "Synthetic denied", waiting="authorization"
        )

    cloud.inspect = denied
    task = service.admit(
        ProbeStart(expected_version=1, idempotency_key=uuid4(), management_token=TOKEN),
        "probe",
    )
    service.run_one(task.task_id)
    snapshot = service.store.get(task.task_id)
    assert snapshot.classification == "unknown"
    assert snapshot.allowed_actions == ["authorize"]


def test_changed_local_prerequisite_stops_confirmed_execution_before_cloud_write(
    runtime,
):
    service, cloud, adapter, _ = runtime
    confirmed = plan(service)
    adapter.installed = False
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).issue_code == "plan_prerequisites_changed"
    assert cloud.calls == {"tunnel": 0, "ingress": 0, "dns": 0}
    assert adapter.calls == []


def test_changed_business_target_rejects_resupply_for_original_plan(runtime):
    service, cloud, adapter, _ = runtime
    task = execute(service, plan(service))
    service.credentials.clear()
    service.run_one(task.task_id)
    assert service.store.get(task.task_id).stage == "awaiting_authorization"
    service.target = "http://127.0.0.1:8001"
    with pytest.raises(ContractError) as error:
        service.authorize(task.task_id, TaskAuthorization(management_token=TOKEN))
    assert error.value.status == 409
    assert cloud.calls == {"tunnel": 0, "ingress": 0, "dns": 0}
    assert adapter.calls == []
