"""Space HTTP and replay transport over the existing authentication/storage boundary."""

import asyncio
import hashlib
import sqlite3
from typing import Annotated

from bb_auth_contract import ErrorResponse
from bb_auth_contract import space as contract
from bb_auth_contract.media import MediaVariant
from fastapi import Depends, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import Response
from starlette.concurrency import run_in_threadpool

from . import space_media, space_queries, space_store
from .storage import connection, find_session
from .storage_errors import storage_failure


def authorize(db, identity):
    # Fence a logout between the dependency and actual transaction admission.
    if not db.execute("SELECT 1 FROM sessions WHERE token_hash=? AND account=?", (identity["digest"], identity["account"])).fetchone():
        space_queries.fail(401, "unauthenticated")


def execute(path, directory, identity, action, body, clock):
    mutation = isinstance(body, contract.Mutation)
    visiting = action == "get_post" and body.visit_id is not None
    upload = space_media.decode(body) if action == "add_image" else None
    with connection(path, write=mutation or visiting) as db:
        authorize(db, identity)
        if mutation:
            result = space_store.mutate(db, directory, identity["account"], action, body, space_store.now(clock), upload)
        else:
            if visiting:
                space_store.visit(db, identity["account"], body, space_store.now(clock))
            result = space_queries.read(db, identity["account"], action, body)
        # Validate before COMMIT so serialization faults cannot become phantom success.
        result = contract.RESPONSES[action].model_validate(result).model_dump()
    if action in ("delete_post", "delete_draft", "update_draft"):
        try:
            space_media.collect(path, directory)
        except (OSError, sqlite3.Error) as error:
            storage_failure(error)
    return result


def install(app, path, directory, current_session, clock):
    errors = {code: {"model": ErrorResponse} for code in (401, 403, 404, 409, 413, 415, 422, 503)}

    def no_query(request: Request):
        if request.query_params:
            space_queries.fail(422, "validation_error")

    def endpoint(action, model):
        def call(payload: model, identity=Depends(current_session)):
            return execute(path, directory, identity, action, payload, clock)
        call.__name__ = "space_" + action
        return call

    for action, model in contract.REQUESTS.items():
        app.add_api_route("/space/" + action, endpoint(action, model), methods=["POST"],
                          response_model=contract.RESPONSES[action], responses=errors,
                          dependencies=[Depends(no_query)], tags=["space"])

    @app.get("/space/images/{image_id}", responses=errors, tags=["space"])
    def image(image_id: contract.Id, request: Request,
              variant: Annotated[MediaVariant, Query()] = "original", identity=Depends(current_session)):
        if set(request.query_params) - {"variant"}:
            space_queries.fail(422, "validation_error")
        with connection(path) as db:
            authorize(db, identity)
            data, mime = space_media.read(db, directory, identity["account"], image_id, variant)
        return Response(data, media_type=mime, headers={"Cache-Control": "private, no-store", "Vary": "Authorization", "X-Content-Type-Options": "nosniff"})

    def events_for_token(token, after):
        user = find_session(path, token, clock())
        if user is None:
            return None
        with connection(path) as db:
            if not db.execute("SELECT 1 FROM sessions WHERE token_hash=?", (token,)).fetchone():
                return None
            return space_queries.event_page(db, user["account"], after, 100)

    @app.websocket("/space/events")
    async def events(socket: WebSocket):
        authorization = socket.headers.get("authorization", "")
        try:
            after = int(socket.query_params.get("after_event_id", "0"))
            if not 0 <= after <= 9007199254740991 or set(socket.query_params) - {"after_event_id"}:
                raise ValueError
        except ValueError:
            await socket.close(code=1008)
            return
        if not authorization.lower().startswith("bearer "):
            await socket.close(code=1008)
            return
        digest = hashlib.sha256(authorization[7:].encode()).hexdigest()
        initial = await run_in_threadpool(events_for_token, digest, after)
        if initial is None:
            await socket.close(code=1008)
            return
        await socket.accept()
        try:
            while True:
                page = await run_in_threadpool(events_for_token, digest, after)
                if page is None:
                    await socket.close(code=1008)
                    return
                for item in page["items"]:
                    await socket.send_json(item)
                after = page["next_event_id"]
                if not page["has_more"]:
                    try:
                        # Receive detects disconnects even when no events are pending.
                        message = await asyncio.wait_for(socket.receive(), timeout=0.5)
                        if message["type"] == "websocket.disconnect":
                            return
                    except TimeoutError:
                        pass
        except WebSocketDisconnect:
            pass
