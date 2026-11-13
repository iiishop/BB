"""Independent DEA-469 regressions: malformed successful external write replies."""

import pytest
import test_public_runtime as cases
from test_public_runtime import execute, plan

from bb_server.public_cloud import Cloudflare

runtime = cases.runtime


def malformed_create(cloud, monkeypatch, result):
    original = cloud.create_tunnel

    def transport(method, path, payload):
        assert method == "POST"
        original(cloud.account_id, payload["name"], payload["tunnel_secret"])
        return {"success": True, "result": result}

    adapter = Cloudflare("synthetic-only", transport=transport)
    monkeypatch.setattr(cloud, "create_tunnel", adapter.create_tunnel)


@pytest.mark.parametrize("result", [{}, {"id": "invalid-uuid"}])
def test_malformed_success_keeps_original_task_for_reconciliation(
    runtime, monkeypatch, result
):
    service, cloud, _, _ = runtime
    confirmed = plan(service)
    malformed_create(cloud, monkeypatch, result)
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    assert cloud.calls["tunnel"] == 1
    assert len(cloud.items) == 1
    assert service.store.config().active is None
    assert service.store.get(task.task_id).stage == "awaiting_authorization"


def test_malformed_success_does_not_allow_fresh_plan_to_duplicate_tunnel(
    runtime, monkeypatch
):
    service, cloud, _, _ = runtime
    confirmed = plan(service)
    malformed_create(cloud, monkeypatch, {})
    task = execute(service, confirmed)
    service.run_one(task.task_id)
    if service.store.get(task.task_id).stage == "finished":
        # The exposed UI permits another probe/plan after this terminal failure.
        retry = execute(service, plan(service))
        service.run_one(retry.task_id)
    assert cloud.calls["tunnel"] == 1, "unknown create was retried under a new task"
    assert len(cloud.items) == 1
