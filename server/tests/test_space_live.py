"""Real bb-server TCP entry, persistent restart and protected media; no HTTP double."""
import os
import socket
import subprocess
import sys
import time
from contextlib import contextmanager

import httpx
from space_support import call, publish, register


@contextmanager
def server(tmp_path):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    environment = {**os.environ, "BB_DATABASE_PATH": str(tmp_path / "space.db"),
                   "BB_AVATAR_DIRECTORY": str(tmp_path / "avatars"),
                   "BB_MEDIA_DIRECTORY": str(tmp_path / "media"),
                   "BB_HOST": "127.0.0.1", "BB_PORT": str(port)}
    with (tmp_path / "server.log").open("ab") as log:
        process = subprocess.Popen([sys.executable, "-m", "bb_server"], env=environment, stdout=log, stderr=log)
        try:
            with httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=10) as api:
                deadline = time.monotonic() + 15
                while True:
                    assert process.poll() is None, "bb-server exited before readiness"
                    try:
                        if api.get("/auth/session").status_code == 401:
                            break
                    except httpx.ConnectError:
                        pass
                    assert time.monotonic() < deadline, "bb-server readiness timed out"
                    time.sleep(0.05)
                yield api
        finally:
            # Exact child handle, launched as python -m bb_server, never daemon name.
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def test_real_entry_publish_lost_response_restart_events_and_logout(tmp_path):
    with server(tmp_path) as api:
        a, b = register(api, "Alice"), register(api, "Bob")
        pid = publish(api, a, "real TCP fact")
        cid = call(api, b, "create_comment", post_id=pid, text="real reply", operation_id="logical_comment")["resource_id"]
        call(api, b, "get_post", post_id=pid, visit_id="active_visit")
        events = call(api, a, "read_events")
        assert any(e["type"] == "notification.changed" for e in events["items"])
    with server(tmp_path) as api:
        result = call(api, b, "get_operation", operation_id="logical_comment")
        assert result["resource_id"] == cid
        assert call(api, b, "create_comment", post_id=pid, text="real reply", operation_id="logical_comment") == result
        post = call(api, b, "get_post", post_id=pid, visit_id="active_visit")
        assert post["comment_count"] == post["view_count"] == 1
        assert call(api, a, "read_events") == events
        call(api, a, "delete_post", post_id=pid)
        call(api, b, "get_post", post_id=pid, status=404)
        notification = call(api, a, "list_notifications")["items"][0]
        assert notification["deleted"] and notification["snippet"] is None
        assert api.post("/auth/logout", headers=b[1]).status_code == 204
        call(api, b, "overview", status=401)
