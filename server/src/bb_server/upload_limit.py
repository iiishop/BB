from bb_auth_contract import ContractError
from bb_auth_contract.profile import MAX_AVATAR_BYTES
from starlette.responses import JSONResponse


class UploadLimit:
    """Bound multipart bytes before Starlette can spool an unbounded request."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if (
            scope["type"] != "http"
            or scope["path"] != "/me/avatar"
            or scope["method"] != "POST"
        ):
            return await self.app(scope, receive, send)
        limit = MAX_AVATAR_BYTES + 64 * 1024  # bounded multipart overhead
        length = dict(scope.get("headers", [])).get(b"content-length")
        if length and length.isdigit() and int(length) > limit:
            error = ContractError(413, "payload_too_large", "头像请求体过大")
            return await JSONResponse(error.body, status_code=413)(scope, receive, send)
        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            body.extend(message.get("body", b""))
            if len(body) > limit:
                error = ContractError(413, "payload_too_large", "头像请求体过大")
                return await JSONResponse(error.body, status_code=413)(
                    scope, receive, send
                )
            if not message.get("more_body", False):
                break
        delivered = False

        async def limited_receive():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()

        await self.app(scope, limited_receive, send)
