"""Deterministic exports: uv run --project server --locked python server/contract/export_chat_v2.py."""

import copy
import json
from pathlib import Path

from bb_auth_contract import chat_v2 as v2
from pydantic import TypeAdapter

ROOT = Path(__file__).parent
AUTH = {"account": "10000001", "auth_generation": "generation-A-1"}
IDENTITY = {**AUTH, "consumer_id": "consumer-A", "binding_revision": 1}
RETIRED_ROUTES = [
    "/chat/list_users",
    "/chat/send_message",
    "/chat/send_attachment",
    "/chat/read_messages",
    "/chat/wait_messages",
    "/chat/ack_messages",
    "/chat/consumption",
    "/chat/confirm_presentation",
    "/operations/get",
    "/downloads/start",
    "/downloads/get",
    "/events/subscribe",
    "/events/read",
    "/events/wait",
    *["/profile/" + name for name in v2.profile.PROFILE_TOOLS],
]


def schema():
    components = {}

    def model(model):
        result = model.model_json_schema(ref_template="#/components/schemas/{model}")
        for name, value in result.pop("$defs", {}).items():
            assert name not in components or components[name] == value, name
            components[name] = value
        name = result["title"]
        # Pydantic generic titles contain brackets; use deterministic operation-specific roots.
        name = name.replace("[", "_").replace("]", "").replace(", ", "_")
        assert name not in components or components[name] == result, name
        components[name] = result
        return {"$ref": f"#/components/schemas/{name}"}

    error = model(v2.ErrorEnvelope)
    paths = {}
    for name, (path, request, response, status, owner) in v2.OPERATIONS.items():
        paths[path] = {
            "post": {
                "operationId": name,
                "security": [{"consumerOwner": []}] if owner else [],
                "requestBody": {
                    "required": True,
                    "content": {"application/json": {"schema": model(request)}},
                },
                "responses": {
                    str(status): {
                        "description": "Success",
                        "content": {"application/json": {"schema": model(response)}},
                    },
                    **{
                        str(code): {
                            "description": "See x-bb-errors; no input or capability echo",
                            "content": {"application/json": {"schema": error}},
                        }
                        for code in sorted({e[0] for e in v2.ERRORS.values()})
                    },
                },
            }
        }
    return {
        "openapi": "3.1.0",
        "info": {"title": "BB local client guarded chat", "version": v2.VERSION},
        "servers": [{"url": "http://127.0.0.1:9187"}],
        "paths": paths,
        "components": {
            "schemas": components,
            "securitySchemes": {
                "consumerOwner": {
                    "type": "apiKey",
                    "in": "header",
                    "name": v2.OWNER_HEADER,
                    "description": "32 random bytes, unpadded base64url, persisted before enrollment; local consumer capability, never a server credential.",
                    "x-value-schema": TypeAdapter(v2.OwnerKey).json_schema(),
                }
            },
        },
        "x-bb-errors": {
            name: {"status": code, "recovery": recovery}
            for name, (code, recovery) in v2.ERRORS.items()
        },
        "x-bb-contract": "docs/contracts/dea467-local-v2.md",
        "x-bb-local-business-policy": "Only protected /v2 business routes; no unguarded fallback or legacy alias migration.",
        "x-bb-auth-bootstrap": ["/auth/register", "/auth/login"],
        "x-bb-retired-local-routes": RETIRED_ROUTES,
    }


def fixtures():
    old = json.loads((ROOT / "chat-cases.json").read_text())
    inputs = {}
    for name in v2.BUSINESS:
        value = copy.deepcopy(
            (
                old["inputs"]
                | old["internal_inputs"]
                | {
                    "view_avatar": {},
                    "update_avatar": {
                        "base64": old["inputs"]["send_message"]["content"][1]["source"][
                            "base64"
                        ]
                    },
                    "view_nickname": {},
                    "update_nickname": {"value": "Alice"},
                    "view_signature": {},
                    "update_signature": {"value": "synthetic signature"},
                    "get_consumption": {"account": "10000002"},
                    "list_conversations": {"after_account": "", "limit": 50},
                    "get_message": {"message_id": "m1"},
                    "get_context": {
                        "message_id": "m1",
                        "before_limit": 10,
                        "after_limit": 10,
                    },
                }
            )[name]
        )
        value.pop("consumer_session", None)
        value["expected_identity"] = IDENTITY
        inputs[name] = value
    inputs.update(
        {
            "negotiate": {"supported_versions": [2]},
            "status": {},
            "consumer_create": {"expected_auth": AUTH, "session_id": "session-one"},
            "consumer_get": {"expected_auth": AUTH, "consumer_id": "consumer-A"},
            "consumer_bind": {
                "expected_auth": AUTH,
                "consumer_id": "consumer-A",
                "expected_binding_revision": 1,
                "session_id": "session-two",
            },
        }
    )
    inputs["ack_messages"]["through_position"] = 1
    inputs["wait_messages"]["seen_position"] = 0
    inputs["events_wait"]["after_cursor"] = 0
    inputs["get_download"]["task_id"] = "task-one"
    binding = {
        "identity": IDENTITY,
        "session_id": "session-one",
        "active": True,
    }
    message = old["visible_message"]["message"]
    sent_message = {
        **message,
        "id": "sent-message",
        "sender_account": AUTH["account"],
        "target_account": "10000002",
        "content": [
            {"type": "text", "text": "before"},
            {"type": "image", "media_id": "uploaded-image"},
            {"type": "text", "text": "after"},
        ],
    }
    page = {"items": [old["visible_message"]], "next_position": 1, "has_more": False}
    download = {
        "task_id": "task-one",
        "operation_id": "example-download-1",
        "origin_identity": IDENTITY,
        "status": "pending",
        "planned_path": "/synthetic/pending-file",
        "actual_path": None,
        "error_code": None,
    }
    event = {
        "version": 2,
        "event_id": "event-one",
        "origin_identity": IDENTITY,
        "type": "message.available",
        "peer_account": "10000002",
        "position": 1,
    }
    event_page = {
        "items": [{"cursor": 1, "event": event}],
        "next_cursor": 1,
        "has_more": False,
    }
    context = {
        "peer_account": "10000002",
        "anchor_message_id": message["id"],
        "range": {
            "start_position": message["position"],
            "end_position": message["position"],
        },
        "before_has_more": False,
        "after_has_more": False,
        "missing_positions": [],
        "missing_truncated": False,
        "reply_relations": "unsupported",
    }
    for name in ["get_message", "get_context"]:
        inputs[name]["message_id"] = message["id"]
    results = {
        "view_avatar": {
            "account": AUTH["account"],
            "mime_type": "image/png",
            "data": inputs["update_avatar"]["base64"],
            "avatar_version": "synthetic-1",
        },
        "update_avatar": {
            "avatar_url": "/avatars/10000001.png",
            "avatar_version": "synthetic-1",
        },
        "view_nickname": {"account": AUTH["account"], "username": "Alice"},
        "update_nickname": {"account": AUTH["account"], "username": "Alice"},
        "view_signature": {"account": AUTH["account"], "signature": None},
        "update_signature": {
            "account": AUTH["account"],
            "signature": "synthetic signature",
        },
        "list_conversations": {
            "items": [
                {
                    "peer_account": "10000002",
                    "last_message": message,
                    "last_activity_at": message["created_at"],
                    "latest_position": message["position"],
                    "consumed_through": 0,
                    "unconsumed_positions": message["position"],
                }
            ],
            "next_cursor": None,
        },
        "get_message": {"item": old["visible_message"], "missing_media_ids": []},
        "get_context": {
            **context,
            "items": [old["visible_message"]],
            "missing_media_ids": [],
        },
        "list_users": {"items": [], "next_cursor": None},
        "send_message": sent_message,
        "send_attachment": {
            **sent_message,
            "id": "sent-attachment",
            "kind": "attachment",
            "content": None,
            "attachment": {
                "media_id": "media-one",
                "media_type": "document",
                "filename": "example.pdf",
                "mime_type": "application/pdf",
                "byte_size": 10,
            },
        },
        "read_messages": page,
        "wait_messages": {**page, "reason": "messages"},
        "ack_messages": {"consumed_through": 1},
        "confirm_presentation": {"confirmed_receipt_ids": ["example-receipt"]},
        "get_consumption": {"consumed_through": 1},
        "start_download": download,
        "get_download": download,
        "get_operation": {
            "operation_id": "example-send-1",
            "kind": "message",
            "status": "succeeded",
            "message": sent_message,
        },
        "events_subscribe": {"peer_account": "10000002"},
        "events_read": event_page,
        "events_wait": {**event_page, "reason": "events"},
    }
    outputs = {
        name: {"identity": IDENTITY, "result": value} for name, value in results.items()
    }
    outputs.update(
        {
            "negotiate": {
                "selected_version": 2,
                "contract": v2.VERSION,
                "owner_header": v2.OWNER_HEADER,
            },
            "status": {"protocol_version": 2, "auth": AUTH},
            "consumer_create": binding,
            "consumer_get": binding,
            "consumer_bind": {
                **binding,
                "identity": {**IDENTITY, "binding_revision": 2},
                "session_id": "session-two",
            },
        }
    )
    invalid = []
    for name in v2.BUSINESS:
        body = copy.deepcopy(inputs[name])
        body.pop("expected_identity")
        invalid.append(
            {"id": name + "-missing-identity", "operation": name, "input": body}
        )
    for field, value in [
        ("auth_generation", ""),
        ("consumer_id", ""),
        ("binding_revision", 0),
        ("binding_revision", True),
        ("binding_revision", "1"),
        ("account", "10000002x"),
    ]:
        body = copy.deepcopy(inputs["ack_messages"])
        body["expected_identity"][field] = value
        invalid.append(
            {
                "id": "identity-" + field + "-" + str(value),
                "operation": "ack_messages",
                "input": body,
            }
        )
    for extra in ["consumer_session", "token", "expected_account"]:
        body = copy.deepcopy(inputs["send_message"])
        body[extra] = "synthetic-rejected"
        invalid.append(
            {"id": "extra-" + extra, "operation": "send_message", "input": body}
        )
    invalid += [
        {
            "id": "history-exclusive-boundaries",
            "operation": "read_messages",
            "input": {
                **inputs["read_messages"],
                "after_position": 0,
                "before_position": 2,
            },
        },
        {
            "id": "context-budget",
            "operation": "get_context",
            "input": {**inputs["get_context"], "before_limit": 50},
        },
        {
            "id": "unsafe-message-id",
            "operation": "get_message",
            "input": {**inputs["get_message"], "message_id": "../other"},
        },
    ]
    return {
        "query_revision": "dea467-query-v1",
        "query_pagination": [
            {
                "request": {"limit": 2},
                "positions": [1, 2],
                "next_position": 2,
                "has_more": True,
            },
            {
                "request": {"after_position": 2, "limit": 2},
                "positions": [3, 4],
                "next_position": 4,
                "has_more": True,
            },
            {
                "request": {"before_position": 4, "limit": 2},
                "positions": [2, 3],
                "next_position": 2,
                "has_more": True,
            },
            {
                "request": {"before_position": 2, "limit": 2},
                "positions": [1],
                "next_position": 1,
                "has_more": False,
            },
            {
                "request": {"before_position": 1, "limit": 2},
                "positions": [],
                "next_position": 1,
                "has_more": False,
            },
            {
                "request": {"after_position": 6, "limit": 2},
                "positions": [],
                "next_position": 6,
                "has_more": False,
            },
        ],
        "version": v2.VERSION,
        "retired_local_routes": [
            {"path": path, "status": 404} for path in RETIRED_ROUTES
        ],
        "synthetic_only": True,
        "owner_header": {"name": v2.OWNER_HEADER, "value": "A" * 43},
        "inputs": {
            n: v2.OPERATIONS[n][1]
            .model_validate(v)
            .model_dump(exclude_unset=n == "update_avatar")
            for n, v in inputs.items()
        },
        "outputs": {
            n: v2.OPERATIONS[n][2].model_validate(v).model_dump()
            for n, v in outputs.items()
        },
        "invalid_inputs": invalid,
        "errors": {
            n: {
                "status": s,
                "body": {
                    "error": {
                        "code": n,
                        "message": "Synthetic contract error",
                        "fields": [],
                    }
                },
            }
            for n, (s, _) in v2.ERRORS.items()
        },
        "semantic_cases": [
            {
                "id": "consumer-isolation",
                "given": "A confirmed and ACKed 2; B has zero receipts",
                "operation": "ack_messages",
                "expect": {"status": 409, "code": "consumption_gap", "b_cursor": 0},
            },
            {
                "id": "aba-auth",
                "given": "A to B to A or same-account login; old identity",
                "operation": "send_message",
                "expect": {"status": 409, "code": "stale_identity", "new_sends": 0},
            },
            {
                "id": "competing-bind",
                "given": "two owner processes bind with revision 1",
                "operation": "consumer_bind",
                "expect": {"successes": 1, "conflicts": 1, "code": "stale_binding"},
            },
            {
                "id": "wrong-owner",
                "given": "known consumer ID with another owner capability",
                "operation": "consumer_get",
                "expect": {
                    "status": 409,
                    "code": "stale_binding",
                    "disclosed_bindings": 0,
                },
            },
            {
                "id": "receipt-loss-restart",
                "given": "successful send; local reply lost; client restarted; explicit rebind",
                "operation": "get_operation",
                "expect": {"status": 200, "same_operation_id": True, "new_sends": 0},
            },
            {
                "id": "no-legacy-receipt-inheritance",
                "given": "synthetic identity-less receipts exist; new consumer has no own confirmations",
                "operation": "ack_messages",
                "expect": {
                    "status": 409,
                    "code": "consumption_gap",
                    "inherited_cursor": False,
                },
            },
        ],
    }


def export():
    for name, value in [
        ("chat-v2-openapi.json", schema()),
        ("chat-v2-cases.json", fixtures()),
    ]:
        (ROOT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    export()
