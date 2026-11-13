import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:net";
import { diagnostic, stoppedState } from "../../bundle/status.js";
test("real fetch distinguishes restricted port from refused TCP", async () => {
  const server = createServer();
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const port = server.address().port;
  await new Promise((r) => server.close(r));
  for (const [p, code] of [
    [1, "client_port_restricted"],
    [port, "client_connection_refused"],
  ]) {
    await assert.rejects(fetch("http://127.0.0.1:" + p), (e) => {
      assert.equal(diagnostic(e, "unknown"), code);
      assert.equal(stoppedState(code), "connection_unavailable");
      return true;
    });
  }
});
test("real restrictions remain distinct from unknown stopped failures", () => {
  for (const code of [
    "stale_identity",
    "stale_binding",
    "session_identity_mismatch",
    "recovery_session_required",
  ])
    assert.equal(stoppedState(diagnostic({ code }, "unknown")), "blocked");
  assert.equal(
    stoppedState(
      diagnostic(
        { code: "secret-credential", message: "private stack" },
        "binding_unavailable",
      ),
    ),
    "stopped",
  );
  assert.equal(
    diagnostic({ cause: { code: "ETIMEDOUT" } }, "unknown"),
    "client_connection_timeout",
  );
});
