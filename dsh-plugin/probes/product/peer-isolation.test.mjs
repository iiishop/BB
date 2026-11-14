import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Bridge } from "../../bundle/bridge.js";
import { digest } from "../../bundle/store.js";

const account = "10000001",
  a = "10000002",
  b = "10000003";
function item(peer, position = 1) {
  return {
    message: {
      id: `${peer}-${position}`,
      position,
      sender_account: peer,
      target_account: account,
    },
    blocks: [],
    presentation: { receipt_id: `receipt-${peer}-${position}` },
  };
}
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "bb-peers-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const hooks = {},
    facts = [],
    delivered = [],
    calls = [],
    cursors = new Map();
  const agent = {
    session: {
      id: "session",
      header: { createdAt: 1 },
      snapshotEvents: () => facts,
    },
    status: "idle",
    inbox: { nextTurn: [], nextStep: [], remove() {} },
    runMaintenance: async (fn) => fn(),
    followup: (m) => {
      delivered.push(m);
      agent.inbox.nextTurn.push(m);
    },
  };
  const ctx = {
    sessions: { flush: async () => true },
    plugin: async (plugin) => {
      plugin.apply({
        on: (name, fn) => {
          hooks[name] = fn;
        },
      });
      return { dispose() {} };
    },
  };
  const client = {
    identity: { account, consumer_id: "owner", binding_revision: 1 },
    check: async () => {},
    call: async (path, args) => {
      calls.push({ path, args });
      if (path === "operations/get") throw { status: 503 };
      if (path === "chat/consumption")
        return { consumed_through: cursors.get(args.account) ?? 0 };
      if (path === "chat/read_messages") return { items: [item(args.account)] };
      if (path === "chat/ack_messages")
        cursors.set(args.account, args.through_position);
      return {};
    },
  };
  const bridge = await new Bridge(ctx, agent, client, root).mount();
  bridge.history.prepare = async () => ({ content: [] });
  const plan = async (peer = a, extra = {}) =>
    bridge.operations.put({
      key: digest(["operation", peer]),
      operation_id: `op-${peer}`,
      kind: "send",
      peer,
      state: "dispatching",
      session: "session",
      sessionCreatedAt: 1,
      ...extra,
    });
  return { bridge, plan, hooks, facts, delivered, calls, cursors, agent };
}

test("pending A does not suppress B; A cannot claim via passive or query", async (t) => {
  const f = await fixture(t);
  await f.plan();
  await f.bridge.poll(b);
  assert.equal(f.delivered.length, 1);
  await f.bridge.poll(b);
  assert.equal(
    f.delivered.length,
    1,
    "pending native delivery is not duplicated",
  );
  await f.bridge.poll(a);
  await f.bridge.claim(item(a));
  await f.bridge.claim(item(a), { callId: "query" });
  assert.equal(f.bridge.journal.list().filter((r) => r.peer === a).length, 0);
});

test("wait ownership is peer scoped and post-query uses the same claim guard", async (t) => {
  const f = await fixture(t);
  await f.plan();
  const exec = (peer, callId) => ({
    agent: f.agent,
    name: "mcp__bb__wait_messages",
    arguments: { account: peer, seen_position: 0 },
    callId,
  });
  await assert.rejects(
    f.hooks["tools/pre-execute"](exec(a, "a"), async () => {}),
  );
  await f.hooks["tools/pre-execute"](exec(b, "b"), async () => {});
  await f.bridge.poll(b);
  assert.equal(f.delivered.length, 0);
  const c = "10000004";
  await f.bridge.poll(c);
  assert.equal(f.delivered.length, 1);
  await f.hooks["tools/post-execute"](
    exec(b, "b"),
    { value: { structuredContent: { items: [item(b)] } } },
    async () => ({ kind: "accept" }),
  );
  assert.equal(f.bridge.waiters.size, 0);
  assert.equal(f.bridge.journal.list().find((r) => r.peer === b).callId, "b");
});

test("uncertain incoming A cannot block B, including recovery of reserved input", async (t) => {
  const f = await fixture(t);
  await f.bridge.claim(item(a));
  const row = f.bridge.journal.list()[0];
  await f.bridge.journal.put({ ...row, state: "uncertain" });
  await f.bridge.poll(b);
  assert.equal(f.delivered.length, 2);
  await f.bridge.claim(item(a, 2), { callId: "query" });
  assert.equal(f.bridge.journal.list().length, 2);
  await f.plan(b);
  f.agent.inbox.nextTurn = [];
  const before = f.delivered.length;
  await f.bridge.recover();
  assert.equal(
    f.delivered.length,
    before,
    "recovery cannot bypass peer uncertainty",
  );
});

test("unknown legacy scope permits input but withholds confirmation/ACK; terminal recovery releases it", async (t) => {
  const f = await fixture(t);
  await f.plan(undefined, { peer: undefined });
  await f.bridge.poll(b);
  assert.equal(f.delivered.length, 1);
  let row = f.bridge.journal.list()[0];
  row = await f.bridge.journal.put({
    ...row,
    state: "presented",
    turn: 1,
    requestDigest: "proof",
  });
  f.facts.push(
    { type: "user/message", data: { id: row.nativeId } },
    { type: "turn/end", data: { turn: 1, reason: { kind: "completed" } } },
  );
  await f.bridge.settle(row);
  assert.equal(
    f.calls.filter((c) => /confirm_presentation|ack_messages/.test(c.path))
      .length,
    0,
  );
  for (const p of f.bridge.operations.rows.values())
    await f.bridge.operations.put({ ...p, state: "failed_absent" });
  await f.bridge.settle(row);
  assert.equal(f.cursors.get(b), 1);
  assert.equal(f.bridge.journal.get(row.key).state, "completed");
});

test("unresolved operation blocks settlement of target and source peers only", async (t) => {
  const f = await fixture(t);
  await f.bridge.claim(item(a));
  await f.bridge.claim(item(b));
  await f.plan(a);
  for (let row of f.bridge.journal.list()) {
    row = await f.bridge.journal.put({
      ...row,
      state: "presented",
      turn: 1,
      requestDigest: "proof",
    });
    f.facts.push({ type: "user/message", data: { id: row.nativeId } });
  }
  f.facts.push({
    type: "turn/end",
    data: { turn: 1, reason: { kind: "completed" } },
  });
  for (const row of f.bridge.journal.list()) await f.bridge.settle(row);
  assert.equal(f.cursors.get(a), undefined);
  assert.equal(f.cursors.get(b), 1);
  await f.plan(a, { sourcePeers: [b] });
  assert.equal(f.bridge.operations.blocks(b), true);
});

test("recovery of an absent old-session operation does not demand that session", async (t) => {
  const f = await fixture(t);
  await f.plan(a, { session: "old-session" });
  const call = f.bridge.client.call;
  f.bridge.client.call = async (path, args) => {
    if (path === "operations/get") throw { status: 404, code: "not_found" };
    return call(path, args);
  };
  await f.bridge.recover();
  assert.equal(f.bridge.operations.status()[0].state, "failed_absent");
  await f.bridge.poll(a);
  assert.equal(f.delivered.length, 1);
});

test("wait/query arriving after a peer becomes uncertain cannot consume it", async (t) => {
  const f = await fixture(t);
  const exec = {
    agent: f.agent,
    name: "mcp__bb__wait_messages",
    callId: "waiting",
    arguments: { account: a, seen_position: 0 },
  };
  await f.hooks["tools/pre-execute"](exec, async () => {});
  await f.plan(a);
  await f.hooks["tools/post-execute"](
    exec,
    {
      value: { structuredContent: { items: [item(a)] } },
    },
    async () => ({ kind: "accept" }),
  );
  assert.equal(f.bridge.waiters.size, 0);
  assert.equal(f.bridge.journal.list().length, 0);
  f.facts.push({
    type: "assistant/message",
    data: {
      message: { content: [{ type: "tool-call", id: "query" }] },
    },
  });
  await f.hooks["tools/post-execute"](
    { ...exec, name: "mcp__bb__get_message", callId: "query" },
    {
      value: { structuredContent: { item: item(a) } },
    },
    async () => ({ kind: "accept" }),
  );
  assert.equal(f.bridge.journal.list().length, 0);
  assert.equal(
    f.calls.filter((c) => /confirm_presentation|ack_messages/.test(c.path))
      .length,
    0,
  );
});
