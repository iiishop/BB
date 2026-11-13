import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Operations } from "../../bundle/operations.js";
import { digest } from "../../bundle/store.js";

async function fixture(t, error, kind = "send") {
  const root = await mkdtemp(join(tmpdir(), "bb-operations-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const calls = [];
  const client = {
    identity: { account: "10000001", consumer_id: "owner", binding_revision: 1 },
    check: async () => {},
    call: async (path, args) => { calls.push({ path, args }); throw error; },
  };
  const operations = new Operations(client, root);
  await operations.open();
  const exec = {
    agent: { session: { id: "session", header: { createdAt: 1 }, snapshotEvents: () => [] } },
    callId: "call", name: "mcp__bb__send_message",
    arguments: { operation_id: "stable-id", target_account: "10000002", content: [] },
  };
  const row = await operations.prepare(exec);
  if (kind === "download") await operations.put({ ...row, kind, task_id: "task" });
  return { root, client, operations, row, exec, calls };
}

test("404 terminates a missing send durably without releasing its logical ID", async (t) => {
  const f = await fixture(t, { status: 404, code: "not_found" });
  await f.operations.reconcile();
  assert.equal(f.operations.status()[0].state, "failed_absent");
  assert.equal(f.operations.uncertain(), false);
  const reopened = new Operations(f.client, f.root);
  await reopened.open();
  assert.equal(reopened.status()[0].state, "failed_absent");
  await assert.rejects(reopened.prepare(f.exec), /do not redispatch/);
  await assert.rejects(reopened.prepare({ ...f.exec, callId: "new-call" }), /already planned/);
  await assert.rejects(reopened.prepare({ ...f.exec, arguments: { ...f.exec.arguments, content: ["changed"] } }), /plan changed/);
  assert.ok(f.calls.every(({ path, args }) => path === "operations/get" && args.operation_id === "stable-id"));
  assert.equal(reopened.rows.get(f.row.key).payloadDigest, digest([f.exec.name, f.exec.arguments]));
});

for (const [name, error] of [
  ["network", new TypeError("fetch failed")],
  ["timeout", new DOMException("deadline", "TimeoutError")],
  ["500", { status: 500 }], ["502", { status: 502 }], ["503", { status: 503 }], ["504", { status: 504 }],
]) test(`${name} remains uncertain and reconciliation continues`, async (t) => {
  const f = await fixture(t, error);
  await f.operations.reconcile();
  assert.equal(f.operations.status()[0].state, "uncertain");
  assert.equal(f.operations.uncertain(), true);
  const reopened = new Operations(f.client, f.root);
  await reopened.open();
  assert.equal(reopened.status()[0].state, "uncertain");
});

for (const error of [{ status: 401 }, { status: 409, code: "stale_binding" }, { status: 409, code: "stale_identity" }, { status: 422 }])
  test(`identity/schema failure ${error.status} ${error.code} still fences`, async (t) => {
    const f = await fixture(t, error);
    await assert.rejects(f.operations.reconcile(), (e) => e === error);
    assert.equal(f.operations.status()[0].state, "dispatching");
  });

test("download 404 is not evidence that a send is absent", async (t) => {
  const f = await fixture(t, { status: 404, code: "not_found" }, "download");
  await f.operations.reconcile();
  assert.equal(f.operations.status()[0].state, "uncertain");
});
