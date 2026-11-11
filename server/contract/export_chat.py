"""Run with uv run --directory server python contract/export_chat.py."""

import json
from pathlib import Path

from bb_auth_contract.chat import INTERNAL, LOCAL, Event, LocalEvent, VisibleMessage
from pydantic import TypeAdapter

root = Path(__file__).parent


schema = {
    "version": "chat-step3-r3",
    "operations": {
        name: {
            "method": "POST",
            "path": route,
            "status": status,
            "input": request.model_json_schema(),
            "output": response.model_json_schema(),
        }
        for name, (route, request, response, status) in LOCAL.items()
    },
    "internal_operations": {
        name: {
            "method": "POST",
            "path": route,
            "status": status,
            "input": request.model_json_schema(),
            "output": response.model_json_schema(),
        }
        for name, (route, request, response, status) in INTERNAL.items()
    },
    "errors": [401, 404, 409, 413, 415, 422, 502, 503, 504],
    "server_event": Event.model_json_schema(),
    "local_event": TypeAdapter(LocalEvent).json_schema(),
}
(root / "chat-local-schema.json").write_text(
    json.dumps(schema, ensure_ascii=False, indent=2) + "\n"
)
examples = {
    "send_message": {
        "target_account": "10000002",
        "operation_id": "example-send-1",
        "content": [
            {"type": "text", "text": "before"},
            {
                "type": "image",
                "source": {
                    "base64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC",
                    "mime_type": "image/png",
                    "filename": "example.png",
                },
            },
            {"type": "text", "text": "after"},
        ],
    },
    "send_attachment": {
        "target_account": "10000002",
        "operation_id": "example-file-1",
        "source": {
            "path": "/synthetic/docs/example.pdf",
            "mime_type": "application/pdf",
            "filename": "example.pdf",
        },
    },
    "list_users": {"limit": 50},
    "read_messages": {
        "account": "10000002",
        "consumer_session": "example-session",
        "after_position": 0,
    },
    "wait_messages": {
        "account": "10000002",
        "consumer_session": "example-session",
        "seen_position": 5,
        "timeout": 120,
    },
    "ack_messages": {
        "account": "10000002",
        "consumer_session": "example-session",
        "through_position": 5,
    },
    "start_download": {
        "operation_id": "example-download-1",
        "consumer_session": "example-session",
        "media_id": "example-media",
    },
    "get_download": {"consumer_session": "example-session", "task_id": "example-task"},
    "get_operation": {"operation_id": "example-send-1"},
}
internal_examples = {
    "confirm_presentation": {
        "consumer_session": "example-session",
        "attempt_id": "example-attempt",
        "request_digest": "a" * 64,
        "receipt_ids": ["example-receipt"],
    },
    "events_subscribe": {
        "consumer_session": "example-session",
        "peer_account": "10000002",
    },
    "events_read": {
        "consumer_session": "example-session",
        "after_cursor": 0,
        "limit": 50,
    },
    "events_wait": {
        "consumer_session": "example-session",
        "after_cursor": 2,
        "limit": 50,
        "timeout": 120,
    },
}
fixtures = {
    "version": "chat-step3-r3",
    "synthetic_only": True,
    "inputs": {
        name: LOCAL[name][1].model_validate(value).model_dump()
        for name, value in examples.items()
    },
    "internal_inputs": {
        name: INTERNAL[name][1].model_validate(value).model_dump()
        for name, value in internal_examples.items()
    },
    "visible_message": VisibleMessage.model_validate(
        {
            "message": {
                "id": "example-message",
                "position": 1,
                "sender_account": "10000002",
                "target_account": "10000001",
                "created_at": "2026-11-11T00:00:00Z",
                "kind": "body",
                "content": [{"type": "text", "text": "hello"}],
            },
            "presentation": {
                "receipt_id": "example-receipt",
                "content_digest": "client-owned-opaque-digest",
            },
            "blocks": [{"type": "text", "text": "hello"}],
        }
    ).model_dump(),
    "consumption_cases": [
        {"displayed": [1, 3], "consumed_through": 0, "ack": 3, "expected_status": 409},
        {
            "displayed": [1, 2, 3],
            "consumed_through": 0,
            "ack": 2,
            "expected_consumed": 2,
            "remaining": [3],
        },
        {"displayed": [], "consumed_through": 0, "ack": 1, "expected_status": 409},
        {"displayed": [1, 2], "consumed_through": 2, "ack": 2, "expected_consumed": 2},
    ],
    "presentation_cases": [
        "A/B read, only A fully projected -> confirm A only; ACK B ->409",
        "image admission failure -> no confirmation",
        "successful response persisted then confirmation receipt lost -> retry original attempt without model",
        "login account/session change -> reject old receipt",
    ],
    "confirmation_cases": [
        {
            "first": {
                "attempt_id": "a",
                "request_digest": "request-A",
                "receipt_ids": ["A"],
            },
            "retry": {
                "attempt_id": "a",
                "request_digest": "request-A",
                "receipt_ids": ["A"],
            },
            "expected_status": 200,
        },
        {
            "first": {
                "attempt_id": "a",
                "request_digest": "request-A",
                "receipt_ids": ["A"],
            },
            "retry": {
                "attempt_id": "a",
                "request_digest": "request-B",
                "receipt_ids": ["B"],
            },
            "expected_status": 409,
            "must_not_confirm": ["B"],
            "ack_through_B": 409,
        },
    ],
    "subscription_cases": [
        "consumer A drains server source cursor; consumer B subscribes -> its readable incoming backlog remains recoverable",
        "restart -> same per-account/consumer events and cursors; no consumption change",
        "events/wait accepts events/read limit and after_cursor with timeout",
    ],
    "operation_cases": [
        "lost receipt -> query result -> same message_id",
        "12 identical simultaneous submits -> one message/task",
        "changed target or payload ->409",
        "other account query ->404",
        "network timeout ->uncertain, never failed",
        "download pending -> no actual_path",
        "failed tool -> no consumption ACK",
    ],
}
(root / "chat-cases.json").write_text(
    json.dumps(fixtures, ensure_ascii=False, indent=2) + "\n"
)
