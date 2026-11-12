"""Local client is a labeled transport double. This does NOT validate Flutter/Dart."""

import json
from pathlib import Path

import httpx
import pytest
from bb_auth_contract import ContractError
from bb_auth_contract import chat_v2 as v2
from guarded_fixture import IDENTITY, guarded_client

from bb_dsh_plugin.guarded import INTERNAL, TOOL_MODELS
from bb_dsh_plugin.guarded import invoke_guarded as invoke


def test_all_inputs_share_machine_contract():
    source = Path(__file__).parents[2] / "server/contract/chat-v2-cases.json"
    for name, payload in json.loads(source.read_text())["inputs"].items():
        assert v2.OPERATIONS[name][1].model_validate(payload)


@pytest.mark.asyncio
async def test_wait_120_seconds_not_cut_to_ten_and_no_auto_ack():
    seen = []

    def handler(request):
        seen.append(request)
        assert request.url.path == "/v2/chat/wait_messages"
        assert request.extensions["timeout"]["read"] >= 125
        return httpx.Response(
            200,
            json={
                "items": [],
                "next_position": 0,
                "has_more": False,
                "reason": "timeout",
            },
        )

    client = guarded_client(
        "http://127.0.0.1:8123", transport=httpx.MockTransport(handler)
    )
    result = await invoke(
        client,
        "wait_messages",
        {
            "account": "10000002",
            "seen_position": 0,
            "timeout": 120,
        },
    )
    assert not result.isError
    assert len(seen) == 1


@pytest.mark.asyncio
async def test_real_image_blocks_order_and_no_remote_fetch():
    png = json.loads(
        (Path(__file__).parents[2] / "server/contract/chat-cases.json").read_text()
    )["inputs"]["send_message"]["content"][1]["source"]["base64"]
    message = {
        "id": "m",
        "position": 1,
        "sender_account": "10000002",
        "target_account": "10000001",
        "created_at": "2026-11-11T00:00:00Z",
        "kind": "body",
        "content": [
            {"type": "text", "text": "a"},
            {"type": "image", "media_id": "image"},
            {"type": "text", "text": "b"},
        ],
    }
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(
            200,
            json={
                "items": [
                    {
                        "message": message,
                        "blocks": [
                            {"type": "text", "text": "a"},
                            {"type": "image", "data": png, "mime_type": "image/png"},
                            {"type": "text", "text": "b"},
                        ],
                    }
                ],
                "next_position": 1,
                "has_more": False,
            },
        )

    result = await invoke(
        guarded_client("http://127.0.0.1", transport=httpx.MockTransport(handler)),
        "read_messages",
        {"account": "10000002"},
    )
    assert not result.isError
    assert [block.type for block in result.content] == ["text", "text", "image", "text"]
    assert result.content[2].data == png
    assert len(calls) == 1


@pytest.mark.asyncio
async def test_download_acceptance_query_failure_and_timeout():
    seen = []

    def handler(request):
        seen.append(request.url.path)
        if request.url.path == "/v2/downloads/start":
            return httpx.Response(
                202,
                json={
                    "task_id": "task",
                    "operation_id": "download-1",
                    "origin_identity": IDENTITY,
                    "status": "pending",
                    "planned_path": "/synthetic/documents/example.pdf",
                },
            )
        return httpx.Response(
            200,
            json={
                "operation_id": "download-1",
                "kind": "download",
                "status": "pending",
                "task_id": "task",
            },
        )

    client = guarded_client("http://127.0.0.1", transport=httpx.MockTransport(handler))
    accepted = await invoke(
        client,
        "start_download",
        {"operation_id": "download-1", "media_id": "media"},
    )
    assert accepted.structuredContent["actual_path"] is None
    query = await invoke(client, "get_operation", {"operation_id": "download-1"})
    assert query.structuredContent["task_id"] == "task"
    assert seen == ["/v2/downloads/start", "/v2/operations/get"]

    def timeout(request):
        raise httpx.ReadTimeout("synthetic")

    uncertain = await invoke(
        guarded_client("http://127.0.0.1", transport=httpx.MockTransport(timeout)),
        "send_message",
        {
            "target_account": "10000002",
            "operation_id": "send-1",
            "content": [{"type": "text", "text": "hi"}],
        },
    )
    assert uncertain.isError and uncertain.structuredContent["status"] == 504
    assert "failed" not in uncertain.structuredContent


async def test_ack_gap_is_internal_and_does_not_retry():
    calls = []

    def handler(request):
        calls.append(request.url.path)
        return httpx.Response(
            409,
            json={"error": {"code": "consumption_gap", "message": "gap", "fields": []}},
        )

    client = guarded_client("http://127.0.0.1", transport=httpx.MockTransport(handler))
    with pytest.raises(ContractError) as failure:
        await client.call(
            "ack_messages", {"account": "10000002", "through_position": 3}
        )
    assert (
        failure.value.status == 409
        and failure.value.body["error"]["code"] == "consumption_gap"
    )
    assert calls == ["/v2/chat/ack_messages"]
    assert "ack_messages" not in TOOL_MODELS


@pytest.mark.asyncio
async def test_r3_presentation_metadata_tracks_full_ordered_content():
    fixture = json.loads(
        (Path(__file__).parents[2] / "server/contract/chat-cases.json").read_text()
    )
    png = fixture["inputs"]["send_message"]["content"][1]["source"]["base64"]
    message = {
        "id": "m",
        "position": 1,
        "sender_account": "10000002",
        "target_account": "10000001",
        "created_at": "2026-11-11T00:00:00Z",
        "kind": "body",
        "content": [
            {"type": "text", "text": "a"},
            {"type": "image", "media_id": "image"},
            {"type": "text", "text": "b"},
        ],
    }
    proof = {"receipt_id": "receipt-A", "content_digest": "opaque-client-digest"}

    def handler(request):
        return httpx.Response(
            200,
            json={
                "items": [
                    {
                        "message": message,
                        "presentation": proof,
                        "blocks": [
                            {"type": "text", "text": "a"},
                            {"type": "image", "data": png, "mime_type": "image/png"},
                            {"type": "text", "text": "b"},
                        ],
                    }
                ],
                "next_position": 1,
                "has_more": False,
            },
        )

    result = await invoke(
        guarded_client("http://127.0.0.1", transport=httpx.MockTransport(handler)),
        "read_messages",
        {"account": "10000002"},
    )
    assert not result.isError
    assert [b.type for b in result.content] == ["text", "text", "image", "text"]
    item = result.structuredContent["items"][0]
    assert item["presentation"] == proof
    assert item["message"]["sender_account"] == "10000002"
    assert item["message"]["target_account"] == "10000001"
    assert "bb_presentations" not in result.structuredContent


def test_internal_machine_contract_is_not_model_tool_inventory():
    assert INTERNAL.isdisjoint(TOOL_MODELS)
    assert INTERNAL <= v2.BUSINESS.keys()
