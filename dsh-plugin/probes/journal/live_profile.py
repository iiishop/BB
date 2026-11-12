"""Real Profile chain. Proxy delays real responses, never substitutes their contents."""

import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx


def run(
    *,
    api,
    peer,
    root,
    private,
    launch,
    stop,
    record,
    dart_executable,
    packages,
    **unused,
):
    gate = {"path": None}
    reached, release = threading.Event(), threading.Event()
    trace = []

    class Proxy(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == "/probe/reached":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps({"reached": reached.is_set()}).encode())
                return
            self.forward()

        def do_POST(self):
            if self.path in ["/probe/arm", "/probe/release"]:
                payload = json.loads(
                    self.rfile.read(int(self.headers.get("Content-Length", "0")))
                    or b"{}"
                )
                if self.path.endswith("arm"):
                    gate["path"] = payload["path"]
                    reached.clear()
                    release.clear()
                else:
                    release.set()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")
                return
            self.forward()

        def do_PATCH(self):
            self.forward()

        def forward(self):
            content = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            headers = {
                k: v
                for k, v in self.headers.items()
                if k.lower() not in {"host", "connection", "content-length"}
            }
            response = httpx.request(
                self.command,
                api + self.path,
                content=content,
                headers=headers,
                trust_env=False,
                timeout=15,
            )
            trace.append(
                {
                    "method": self.command,
                    "path": self.path,
                    "status": response.status_code,
                }
            )
            if gate["path"] == self.path:
                gate["path"] = None
                reached.set()
                assert release.wait(8), "response barrier release deadline"
            self.send_response(response.status_code)
            for k, v in response.headers.items():
                if k.lower() not in {
                    "content-length",
                    "transfer-encoding",
                    "connection",
                    "content-encoding",
                }:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(response.content)))
            self.end_headers()
            self.wfile.write(response.content)

    proxy = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    thread = threading.Thread(target=proxy.serve_forever)
    thread.start()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    origin = f"http://127.0.0.1:{port}"
    proxy_origin = f"http://127.0.0.1:{proxy.server_port}"
    repo = Path(__file__).resolve().parents[3]
    dart = launch(
        [
            dart_executable,
            "--packages=" + packages,
            str(repo / "client/bin/bb_client_api.dart"),
            "--port",
            str(port),
            "--server-url",
            proxy_origin,
            "--session-file",
            str(private / "profile/session.json"),
        ],
        "profile-dart",
    )
    try:
        deadline = time.monotonic() + 15
        while True:
            assert dart.poll() is None
            try:
                httpx.get(origin, trust_env=False, timeout=0.2)
                break
            except httpx.TransportError:
                assert time.monotonic() < deadline
                time.sleep(0.05)
        config = private / "profile-config.json"
        config.write_text(
            json.dumps(
                {
                    "origin": origin,
                    "proxy": proxy_origin,
                    "peer": peer,
                    "state": str(private / "profile-binding.json"),
                }
            )
        )
        worker = launch(
            [
                "uv",
                "run",
                "--project",
                "dsh-plugin",
                "--locked",
                "python",
                str(Path(__file__).with_name("profile_mcp.py")),
                str(config),
            ],
            "profile-mcp",
            pipe=True,
        )
        stdout, stderr = worker.communicate(timeout=90)
        for line in stdout.splitlines():
            value = json.loads(line)
            record(value.pop("name"), **value)
        assert worker.returncode == 0, stderr[-3000:]
    finally:
        release.set()
        stop(dart)
        proxy.shutdown()
        proxy.server_close()
        thread.join(timeout=5)
        assert not thread.is_alive()
        (root / "profile-backend-trace.json").write_text(
            json.dumps(trace, indent=2) + "\n"
        )
