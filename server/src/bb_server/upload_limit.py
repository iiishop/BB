from bb_auth_contract import ContractError
from bb_auth_contract.cover import MAX_COVER_BYTES, UPLOAD_PATH
from bb_auth_contract.profile import MAX_AVATAR_BYTES
from starlette.responses import JSONResponse


class UploadLimit:
    """Bound multipart bytes before Starlette can spool an unbounded request."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if (
            scope["type"] != "http"
            or (
                scope["path"] not in ("/me/avatar", "/media", UPLOAD_PATH)
                and not scope["path"].startswith("/space/")
            )
            or scope["method"] != "POST"
        ):
            return await self.app(scope, receive, send)
        limit = {
            "/me/avatar": MAX_AVATAR_BYTES,
            UPLOAD_PATH: MAX_COVER_BYTES,
            "/media": 32 * 1024 * 1024,
        }.get(scope["path"], 0) + 64 * 1024  # bounded multipart overhead
        if scope["path"].startswith("/space/"):
            limit = (
                48 * 1024 * 1024 if scope["path"] == "/space/add_image" else 1024 * 1024
            )
        length = dict(scope.get("headers", [])).get(b"content-length")
        if length and length.isdigit() and int(length) > limit:
            error = ContractError(413, "payload_too_large", "上传请求体过大")
            return await JSONResponse(error.body, status_code=413)(scope, receive, send)
        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            body.extend(message.get("body", b""))
            if len(body) > limit:
                error = ContractError(413, "payload_too_large", "上传请求体过大")
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
