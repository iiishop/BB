"""Local client is a labeled transport double. This does NOT validate Flutter/Dart."""

import json
from pathlib import Path

import httpx
import pytest
from bb_auth_contract.chat import LOCAL

from bb_dsh_plugin.plugin import LocalClient, invoke


@pytest.mark.asyncio
async def test_all_inputs_share_machine_contract():
    source = Path(__file__).parents[2] / "server/contract/chat-cases.json"
    for name, payload in json.loads(source.read_text())["inputs"].items():
        assert LOCAL[name][1].model_validate(payload)


@pytest.mark.asyncio
async def test_wait_120_seconds_not_cut_to_ten_and_no_auto_ack():
    seen = []

    def handler(request):
        seen.append(request)
        assert request.url.path == "/chat/wait_messages"
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

    client = LocalClient(
        "http://127.0.0.1:8123", transport=httpx.MockTransport(handler)
    )
    result = await invoke(
        client,
        "wait_messages",
        {
            "account": "10000002",
            "consumer_session": "session",
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
        LocalClient("http://127.0.0.1", transport=httpx.MockTransport(handler)),
        "read_messages",
        {"account": "10000002", "consumer_session": "session"},
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
        if request.url.path == "/downloads/start":
            return httpx.Response(
                202,
                json={
                    "task_id": "task",
                    "operation_id": "download-1",
                    "consumer_session": "s",
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

    client = LocalClient("http://127.0.0.1", transport=httpx.MockTransport(handler))
    accepted = await invoke(
        client,
        "start_download",
        {"operation_id": "download-1", "consumer_session": "s", "media_id": "media"},
    )
    assert accepted.structuredContent["actual_path"] is None
    query = await invoke(client, "get_operation", {"operation_id": "download-1"})
    assert query.structuredContent["task_id"] == "task"
    assert seen == ["/downloads/start", "/operations/get"]

    def timeout(request):
        raise httpx.ReadTimeout("synthetic")

    uncertain = await invoke(
        LocalClient("http://127.0.0.1", transport=httpx.MockTransport(timeout)),
        "send_message",
        {
            "target_account": "10000002",
            "operation_id": "send-1",
            "content": [{"type": "text", "text": "hi"}],
        },
    )
    assert uncertain.isError and uncertain.structuredContent["status"] == 504
    assert "failed" not in uncertain.structuredContent


@pytest.mark.asyncio
async def test_explicit_ack_gap_contract_double():
    # Test double implements the CLIENT's required ledger; plugin never invents display evidence.
    fixtures = json.loads(
        (Path(__file__).parents[2] / "server/contract/chat-cases.json").read_text()
    )
    for case in fixtures["consumption_cases"]:
        calls = []

        def handler(request, calls=calls, case=case):
            calls.append(request.url.path)
            payload = json.loads(request.content)
            assert payload["consumer_session"] == "consumer-A"
            ack = payload["through_position"]
            missing = set(range(case["consumed_through"] + 1, ack + 1)) - set(
                case["displayed"]
            )
            if missing:
                return httpx.Response(
                    409,
                    json={
                        "error": {
                            "code": "consumption_gap",
                            "message": "Unpresented positions",
                            "fields": [],
                        }
                    },
                )
            return httpx.Response(
                200, json={"consumed_through": max(case["consumed_through"], ack)}
            )

        result = await invoke(
            LocalClient("http://127.0.0.1", transport=httpx.MockTransport(handler)),
            "ack_messages",
            {
                "account": "10000002",
                "consumer_session": "consumer-A",
                "through_position": case["ack"],
            },
        )
        assert result.isError == ("expected_status" in case)
        if not result.isError:
            assert (
                result.structuredContent["consumed_through"]
                == case["expected_consumed"]
            )
        assert calls == ["/chat/ack_messages"]


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
        LocalClient("http://127.0.0.1", transport=httpx.MockTransport(handler)),
        "read_messages",
        {"account": "10000002", "consumer_session": "s"},
    )
    assert not result.isError
    assert [b.type for b in result.content] == [
        "text",
        "text",
        "text",
        "image",
        "text",
        "text",
    ]
    assert result.content[0].text.startswith("BB_PRESENTATION_START:")
    assert result.content[-1].text == 'BB_PRESENTATION_END:"receipt-A"'
    metadata = result.structuredContent["bb_presentations"][0]
    assert (
        metadata["receipt_id"] == proof["receipt_id"]
        and metadata["content_digest"] == proof["content_digest"]
    )
    assert metadata["consumer_session"] == "s" and metadata["image_count"] == 1
    assert (
        metadata["sender_account"] == "10000002"
        and metadata["target_account"] == "10000001"
    )


def test_r3_internal_machine_contract_is_not_model_tool_inventory():
    from bb_auth_contract.chat import INTERNAL, VisibleMessage
    from pydantic import ValidationError

    schema = json.loads(
        (
            Path(__file__).parents[2] / "server/contract/chat-local-schema.json"
        ).read_text()
    )
    assert schema["version"] == "chat-step3-r3"
    assert len(LOCAL) == 9
    assert set(INTERNAL).isdisjoint(LOCAL)
    assert set(schema["internal_operations"]) == set(INTERNAL)
    for name, (_, request, response, _) in INTERNAL.items():
        assert (
            schema["internal_operations"][name]["input"] == request.model_json_schema()
        )
        assert (
            schema["internal_operations"][name]["output"]
            == response.model_json_schema()
        )
    with pytest.raises(ValidationError):
        INTERNAL["events_wait"][1].model_validate(
            {"consumer_session": "s", "after_cursor": -1, "timeout": 10}
        )
    assert "presentation" not in VisibleMessage.model_json_schema()["required"]
