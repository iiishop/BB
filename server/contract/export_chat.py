"""Run with uv run --directory server python contract/export_chat.py."""

import json
from pathlib import Path

from bb_auth_contract.chat import LOCAL, Event, LocalEvent
from pydantic import TypeAdapter

root = Path(__file__).parent


schema = {
    "version": "chat-step3-r2",
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
fixtures = {
    "version": "chat-step3-r2",
    "synthetic_only": True,
    "inputs": {
        name: LOCAL[name][1].model_validate(value).model_dump()
        for name, value in examples.items()
    },
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
