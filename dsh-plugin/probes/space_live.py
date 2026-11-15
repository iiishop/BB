"""Real TCP server -> standalone Dart -> protected local contract integration.
All credentials are synthetic, temporary, and removed on exit.
"""

import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path

import httpx
from bb_auth_contract import space

REPO = Path(__file__).resolve().parents[2]


class Live:
    def __enter__(self):
        try:
            return self.start()
        except BaseException:
            self.__exit__()
            raise

    def start(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bb-space-")
        self.root = Path(self.temp.name)
        self.children = []
        self.safe_env = {k: os.environ[k] for k in ("PATH", "LANG") if k in os.environ}
        self.http = httpx.Client(trust_env=False, timeout=30)
        self.api = self.port()
        self.local = self.port()
        self.server_command = [
            "uv",
            "run",
            "--project",
            "server",
            "--locked",
            "python",
            "-m",
            "bb_server",
        ]
        self.server_env = dict(
            self.safe_env,
            BB_DATABASE_PATH=str(self.root / "db"),
            BB_AVATAR_DIRECTORY=str(self.root / "avatars"),
            BB_MEDIA_DIRECTORY=str(self.root / "media"),
            BB_HOST="127.0.0.1",
            BB_PORT=self.api.rsplit(":", 1)[1],
        )
        self.server = self.launch(self.server_command, self.api, self.server_env)
        self.dart_command = [
            "dart",
            "--packages=" + str(REPO / "client/.dart_tool/package_config.json"),
            str(REPO / "client/bin/bb_client_api.dart"),
            "--port",
            self.local.rsplit(":", 1)[1],
            "--server-url",
            self.api,
            "--session-file",
            str(self.root / "client/session.json"),
        ]
        self.dart = self.launch(self.dart_command, self.local)
        return self

    @staticmethod
    def port():
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            return "http://127.0.0.1:" + str(s.getsockname()[1])

    def launch(self, command, origin, env=None):
        log = open(self.root / f"child-{len(self.children)}.log", "w+")  # noqa: SIM115 - closed in __exit__ after child shutdown
        p = subprocess.Popen(
            command, cwd=REPO, env=env or self.safe_env, stdout=log, stderr=log
        )
        self.children.append((p, log))
        for _ in range(200):
            if p.poll() is not None:
                log.seek(0)
                raise AssertionError(log.read())
            try:
                self.http.get(origin + "/", timeout=0.2)
                return p
            except httpx.TransportError:
                time.sleep(0.05)
        raise AssertionError("readiness deadline")

    def stop(self, p):
        if p.poll() is not None:
            return
        daemon = json.loads(
            subprocess.check_output(
                [os.environ["MULTICA_CLI_PATH"], "daemon", "status", "--output", "json"]
            )
        )
        assert p.pid != daemon["pid"]
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=5)

    def __exit__(self, *args):
        for p, log in reversed(self.children):
            self.stop(p)
            log.close()
        self.http.close()
        self.temp.cleanup()

    def post(self, path, body, *, api=False, headers=None, status=200):
        r = self.http.post(
            (self.api if api else self.local) + path, json=body, headers=headers
        )
        assert r.status_code == status, (path, r.status_code, r.text[:500])
        return r.json()

    def register(self, name):
        return self.post(
            "/auth/register", {"username": name, "password": "Abc123"}, status=201
        )["account"]

    def login(self, account, owner="A" * 43, session="space-session"):
        self.post("/auth/login", {"account": account, "password": "Abc123"})
        auth = self.post("/v2/status", {})["auth"]
        headers = {"X-BB-Consumer-Key": owner}
        b = self.post(
            "/v2/consumers/create",
            {"expected_auth": auth, "session_id": session},
            headers=headers,
        )
        if not b["active"]:
            b = self.post(
                "/v2/consumers/bind",
                {
                    "expected_auth": auth,
                    "consumer_id": b["identity"]["consumer_id"],
                    "expected_binding_revision": b["identity"]["binding_revision"],
                    "session_id": session,
                },
                headers=headers,
            )
        self.identity = b["identity"]
        self.owner = owner
        return b

    def call(self, action, body=None, status=200, identity=None, owner=None):
        body = {"expected_identity": identity or self.identity, **(body or {})}
        space.LOCAL_REQUESTS[action].model_validate(body)
        result = self.post(
            "/v2/space/" + action,
            body,
            headers={"X-BB-Consumer-Key": owner or self.owner},
            status=status,
        )
        if status == 200:
            space.LOCAL_RESPONSES[action].model_validate(result)
            assert result["identity"] == body["expected_identity"]
            return result["result"]
        return result


def run():
    with Live() as live:
        account = live.register("SpaceAgent")
        live.login(account)
        assert live.call("overview")["contract"] == space.VERSION
        draft = live.call(
            "create_draft", {"operation_id": "draft-one", "text": "draft"}
        )
        saved = live.call("get_draft", {"draft_id": draft["resource_id"]})
        assert saved["text"] == "draft"
        post = live.call(
            "publish_draft",
            {
                "operation_id": "pub-one",
                "draft_id": saved["draft_id"],
                "expected_version": 1,
            },
        )
        assert live.call("get_operation", {"operation_id": "pub-one"}) == post
        assert (
            live.call(
                "publish_draft",
                {
                    "operation_id": "pub-one",
                    "draft_id": saved["draft_id"],
                    "expected_version": 1,
                },
            )
            == post
        )
        assert len(live.call("list_posts")["items"]) == 1
        live.call(
            "get_operation", {"operation_id": "pub-one"}, owner="B" * 43, status=409
        )
        other = live.register("OtherSpace")
        original_identity = dict(live.identity)
        cursor = live.call("overview")["latest_event_id"]
        live.login(other, owner="B" * 43, session="space-other")
        live.call("get_draft", {"draft_id": saved["draft_id"]}, status=404)
        live.call("list_visitors", {"post_id": post["resource_id"]}, status=403)
        live.call("get_operation", {"operation_id": "pub-one"}, status=404)
        live.call(
            "delete_post",
            {"operation_id": "illegal-delete", "post_id": post["resource_id"]},
            status=403,
        )
        live.call("overview", identity=original_identity, owner="A" * 43, status=409)
        live.call(
            "get_post", {"post_id": post["resource_id"], "visit_id": "other-visit"}
        )
        live.call(
            "set_like",
            {
                "operation_id": "other-like",
                "post_id": post["resource_id"],
                "liked": True,
            },
        )
        comment = live.call(
            "create_comment",
            {
                "operation_id": "other-comment",
                "post_id": post["resource_id"],
                "text": "hello",
            },
        )
        live.call(
            "mark_read",
            {"operation_id": "other-read", "post_ids": [post["resource_id"]]},
        )
        assert live.call("overview")["unread_posts"] == 0
        live.login(account)
        assert (
            live.call("get_view_summary", {"post_id": post["resource_id"]})[
                "view_count"
            ]
            == 1
        )
        notices = live.call("list_notifications")["items"]
        assert len(notices) == 2
        live.call(
            "ack_notifications",
            {
                "operation_id": "ack",
                "items": [
                    {"notification_id": n["notification_id"], "version": n["version"]}
                    for n in notices
                ],
            },
        )
        assert live.call("overview")["unread_notifications"] == 0
        context = live.call(
            "get_comment_context", {"comment_id": comment["resource_id"]}
        )
        assert context["target"]["comment_id"] == comment["resource_id"]
        assert context["root"]["comment_id"] == comment["resource_id"]
        pending = live.call(
            "create_draft", {"operation_id": "pending-draft", "text": "survives"}
        )
        live.call(
            "update_draft",
            {
                "operation_id": "update",
                "draft_id": pending["resource_id"],
                "expected_version": 1,
                "text": "saved",
                "image_ids": [],
            },
        )
        live.call(
            "update_draft",
            {
                "operation_id": "conflict",
                "draft_id": pending["resource_id"],
                "expected_version": 1,
                "text": "lost",
                "image_ids": [],
            },
            status=409,
        )
        live.stop(live.dart)
        live.stop(live.server)
        live.server = live.launch(live.server_command, live.api, live.server_env)
        live.dart = live.launch(live.dart_command, live.local)
        live.call("overview", status=409)  # cold-start generation fences old binding
        live.login(account)
        assert (
            live.call("get_draft", {"draft_id": pending["resource_id"]})["text"]
            == "saved"
        )
        assert live.call("get_operation", {"operation_id": "pub-one"}) == post
        events = live.call("read_events", {"after_event_id": cursor, "limit": 100})
        assert events["items"] and events["next_event_id"] > cursor
        assert (
            live.call("read_events", {"after_event_id": cursor, "limit": 100}) == events
        )
        live.call(
            "delete_post", {"operation_id": "delete", "post_id": post["resource_id"]}
        )
        live.call("get_post", {"post_id": post["resource_id"]}, status=404)
        live.call("list_comments", {"post_id": post["resource_id"]}, status=404)
        notifications = live.call("list_notifications")["items"]
        assert all(n["snippet"] is None and n["deleted"] for n in notifications)
        replay = live.call("read_events", {"after_event_id": events["next_event_id"]})
        assert any(e["type"] == "post.deleted" for e in replay["items"])
        assert live.call("get_operation", {"operation_id": "pub-one"}) == post
        # Same-account second consumer cannot query the first consumer's receipt.
        live.login(account, owner="C" * 43, session="second-consumer")
        live.call("get_operation", {"operation_id": "pub-one"}, status=404)
        live.call(
            "publish_draft",
            {
                "operation_id": "pub-one",
                "draft_id": saved["draft_id"],
                "expected_version": 1,
            },
            status=409,
        )
        token = json.loads((live.root / "client/session.json").read_text())["token"]
        revoked = live.http.post(
            live.api + "/auth/logout", headers={"Authorization": "Bearer " + token}
        )
        assert revoked.status_code in (200, 204)
        live.call("create_draft", {"operation_id": "revoked", "text": "no"}, status=401)
        assert live.post("/v2/status", {})["auth"] is None
        print(
            json.dumps(
                {
                    "gate": "standalone-dart-tcp-schema-operation",
                    "passed": True,
                    "restart_rebind": True,
                    "http_replay": True,
                    "delete_invalidation": True,
                    "account_consumer_isolation": True,
                    "explicit_notification_ack": True,
                }
            )
        )


if __name__ == "__main__":
    run()
