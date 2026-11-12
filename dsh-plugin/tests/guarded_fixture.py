"""Transport double with explicit binding; never used as real client evidence."""

import json

import httpx

from bb_dsh_plugin.guarded import GuardedTransport

IDENTITY = {
    "account": "12345678",
    "auth_generation": "synthetic-generation",
    "consumer_id": "synthetic-consumer",
    "binding_revision": 1,
}
OWNER = "A" * 43


def guarded_client(base_url, *, transport):
    def handle(request):
        assert request.url.path.startswith("/v2/")
        assert request.headers["X-BB-Consumer-Key"] == OWNER
        assert json.loads(request.content)["expected_identity"] == IDENTITY
        response = transport.handle_request(request)
        if response.status_code in (200, 202):
            return httpx.Response(
                response.status_code,
                json={"identity": IDENTITY, "result": response.json()},
            )
        return response

    return GuardedTransport(
        base_url, OWNER, IDENTITY, transport=httpx.MockTransport(handle)
    )
