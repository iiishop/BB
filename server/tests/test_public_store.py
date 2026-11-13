from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import pytest
from bb_auth_contract import ContractError
from bb_auth_contract.admin import DraftSave, PlanCreate, PlanExecute

from bb_server.admin_storage import AdminStore
from bb_server.public_store import PublicStore
from bb_server.storage import connection


@pytest.fixture
def store(tmp_path):
    path = tmp_path / "admin.db"
    AdminStore(path, lambda: 1000).migrate()
    value = PublicStore(path, lambda: 1000)
    value.migrate()
    value.save(DraftSave(domain="bb.example.com", expected_version=0))
    return value


def probe(store):
    value = store.admit(kind="probe", version=1, key=uuid4())
    store.publish(
        value.task_id,
        stage="finished",
        classification="passed",
        allowed_actions=["create_and_connect"],
    )
    return value


def execution(store):
    value = probe(store)
    plan = store.plan(
        PlanCreate(
            expected_version=1, probe_task_id=value.task_id, action="create_and_connect"
        ),
        target="http://127.0.0.1:8000",
    )
    request = PlanExecute(
        plan_id=plan.plan_id,
        expected_version=1,
        digest=plan.digest,
        idempotency_key=uuid4(),
        confirmed=True,
    )
    return plan, request


def test_atomic_admission_deduplicates_reconnect_and_parallel_clicks(store):
    _, body = execution(store)
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(
            pool.map(
                lambda _: store.admit(
                    kind="execute", version=1, key=uuid4(), plan=body
                ),
                range(6),
            )
        )
    assert len({x.task_id for x in results}) == 1
    task_id = results[0].task_id
    assert store.current().task_id == task_id
    assert len(store.events(task_id, 0)) == 1
    with pytest.raises(ContractError) as error:
        store.save(DraftSave(domain="changed.example.com", expected_version=1))
    assert error.value.status == 409
    restarted = PublicStore(store.path, store.clock)
    restarted.migrate()
    assert (
        restarted.admit(
            kind="execute", version=1, key=body.idempotency_key, plan=body
        ).task_id
        == task_id
    )


def test_draft_invalidates_plan_and_read_only_probe(store):
    _, body = execution(store)
    pending = store.admit(kind="probe", version=1, key=uuid4())
    store.save(DraftSave(domain="next.example.com", expected_version=1))
    assert store.get(pending.task_id).issue_code == "draft_superseded"
    with pytest.raises(ContractError):
        store.admit(kind="execute", version=1, key=body.idempotency_key, plan=body)
    assert store.config().active is None
    assert store.pending() == []


def test_key_conflict_and_invalid_confirmation_have_no_task(store):
    key = uuid4()
    task = store.admit(kind="probe", version=1, key=key)
    with pytest.raises(ContractError) as error:
        store.admit(kind="probe", version=2, key=key)
    assert error.value.body["error"]["code"] == "idempotency_conflict"
    assert store.current().task_id == task.task_id


def test_expired_plan_and_tampered_digest_rejected(store):
    _, body = execution(store)
    changed = body.model_copy(update={"digest": "0" * 64})
    with pytest.raises(ContractError):
        store.admit(kind="execute", version=1, key=uuid4(), plan=changed)
    store.clock = lambda: 1600
    with pytest.raises(ContractError) as error:
        store.admit(kind="execute", version=1, key=uuid4(), plan=body)
    assert error.value.body["error"]["code"] == "plan_expired"
    assert store.pending() == []


def test_authorization_is_single_transition_and_no_secret_storage(store):
    _, body = execution(store)
    task = store.admit(kind="execute", version=1, key=body.idempotency_key, plan=body)
    store.publish(
        task.task_id,
        stage="awaiting_authorization",
        classification="unknown",
        allowed_actions=["authorize"],
    )

    def authorize(_):
        try:
            return store.authorize(task.task_id).seq
        except ContractError as error:
            return error.status

    with ThreadPoolExecutor(max_workers=4) as pool:
        assert sorted(pool.map(authorize, range(4))) == [3, 409, 409, 409]
    assert [seq for seq, _ in store.events(task.task_id, 0)] == [1, 2, 3]
    assert [seq for seq, _ in store.events(task.task_id, 2)] == [3]
    with pytest.raises(ContractError):
        store.events(task.task_id, 4)


def test_intent_persists_response_loss_and_terminal_state_never_reopens(store):
    _, body = execution(store)
    task = store.admit(kind="execute", version=1, key=body.idempotency_key, plan=body)
    assert (
        store.effect(task.task_id, "tunnel", {"name": "owned"})["state"] == "prepared"
    )
    store.mark_effect(task.task_id, "tunnel", "sent")
    restarted = PublicStore(store.path, store.clock)
    assert (
        restarted.effect(task.task_id, "tunnel", {"name": "owned"})["state"] == "sent"
    )
    with pytest.raises(ContractError):
        restarted.effect(task.task_id, "tunnel", {"name": "other"})
    store.mark_effect(task.task_id, "tunnel", "done", {"id": "resource"})
    store.activate(task.task_id, "resource")
    assert store.config().active.domain == "bb.example.com"
    terminal = store.get(task.task_id)
    assert store.publish(task.task_id, stage="running") == terminal
    assert (
        store.admit(kind="execute", version=1, key=body.idempotency_key, plan=body)
        == terminal
    )


def test_snapshot_and_event_rollback_together(store):
    task = store.admit(kind="probe", version=1, key=uuid4())
    with connection(store.path, write=True) as db:
        db.execute(
            "CREATE TRIGGER fail_event BEFORE INSERT ON public_events BEGIN SELECT RAISE(ABORT, 'synthetic'); END"
        )
    import sqlite3

    with pytest.raises(sqlite3.IntegrityError):
        store.publish(task.task_id, stage="detecting")
    assert store.get(task.task_id).seq == 1
    assert len(store.events(task.task_id, 0)) == 1


@pytest.mark.parametrize("step", ["tunnel", "ingress", "dns", "package", "service"])
def test_all_terminal_writers_preserve_sent_effect_and_single_target(store, step):
    _, body = execution(store)
    task = store.admit(kind="execute", version=1, key=body.idempotency_key, plan=body)
    store.effect(task.task_id, step, {"name": "owned"})
    store.mark_effect(task.task_id, step, "sent")
    with pytest.raises(ContractError) as error:
        store.activate(task.task_id, "resource")
    assert error.value.body["error"]["code"] == "effect_unresolved"
    assert store.config().active is None
    assert store.get(task.task_id).seq == task.seq
    for classification in ("failed", "passed"):
        result = store.publish(
            task.task_id, stage="finished", classification=classification
        )
        expected = (
            "awaiting_local_admin"
            if step in ("package", "service")
            else "awaiting_authorization"
        )
        assert result.stage == expected
        assert result.classification == "unknown"
        assert store.pending() == [str(task.task_id)]
        with pytest.raises(ContractError) as error:
            store.admit(kind="probe", version=1, key=uuid4())
        assert error.value.body["error"]["code"] == "task_busy"
        assert store.effect(task.task_id, step, {"name": "owned"})["state"] == "sent"
    # Only reconciled evidence permits terminal state and a fresh task.
    store.mark_effect(task.task_id, step, "done", {"id": "resource"})
    store.publish(task.task_id, stage="finished", classification="failed")
    assert store.pending() == []
    assert store.admit(kind="probe", version=1, key=uuid4()).task_id != task.task_id
