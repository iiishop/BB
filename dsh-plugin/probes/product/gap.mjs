// Real MCP/HTTP and persisted native turns; only the model is deterministic.
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { boot } from "../journal/host.mjs";
import { Client } from "../../bundle/client.js";
import { Bridge } from "../../bundle/bridge.js";
const [pkg, root, configPath, phase] = process.argv.slice(2);
const config = JSON.parse(await readFile(configPath));
const client = new Client(config.origin, resolve(root, "state"));
let modelCalls = 0;
const requests = [],
  checkpoints = [],
  native = [];
const raw = client.raw.bind(client);
client.raw = async (path, body, owner) => {
  const entry = {
    path,
    through: body.through_position,
    operation_id: body.operation_id,
  };
  try {
    const value = await raw(path, body, owner);
    requests.push({
      ...entry,
      status: 200,
      watermark: value.result?.consumed_through,
    });
    return value;
  } catch (error) {
    requests.push({ ...entry, status: error.status, code: error.code });
    throw error;
  }
};
const rt = await boot(
  pkg,
  root,
  async function* () {
    modelCalls++;
    const query = phase === "seed" && modelCalls === 1;
    const send = phase === "seed" && modelCalls === 2;
    if (query || send) {
      yield { type: "block-start", index: 0, blockType: "tool-call" };
      yield {
        type: "block-end",
        index: 0,
        block: {
          type: "tool-call",
          id: query ? "query-position-3" : "one-explicit-send",
          name: "mcp__bb__" + (query ? config.query : "send_message"),
          arguments: JSON.stringify(
            query
              ? {
                  message_id: config.message_id,
                  ...(config.query === "get_context"
                    ? { before_limit: 0, after_limit: 0 }
                    : {}),
                }
              : {
                  target_account: config.peer,
                  content: [
                    { type: "text", text: "one authorized synthetic reply" },
                  ],
                },
          ),
        },
      };
    }
    yield {
      type: "finish",
      reason: { kind: query || send ? "tool-calls" : "stop" },
    };
  },
  (kind, data) => {
    if (kind === "event")
      native.push({ type: data.event.type, turn: data.event.data.turn });
  },
);
const agent = await rt.open("r3-gap-" + config.query, phase !== "seed");
await client.bind(agent.session.id);
const mcp = await rt.load("dsh-mcp-client");
const mcpFiber = await rt.ctx.plugin(mcp, {
  serverName: "bb",
  transport: "stdio",
  command: "uv",
  args: [
    "run",
    "--project",
    resolve("dsh-plugin"),
    "--locked",
    "bb-dsh-plugin",
  ],
  env: {
    BB_CLIENT_BASE_URL: config.origin,
    BB_CONSUMER_STATE_FILE: client.stateFile,
  },
  failOnStartupError: true,
});
const bridge = await new Bridge(
  rt.ctx,
  agent,
  client,
  resolve(root, "state"),
  async (name) =>
    checkpoints.push({
      name,
      watermark: (
        await client.call("chat/consumption", { account: config.peer })
      ).consumed_through,
    }),
).mount();
bridge.installOperations();
const cursor = async () =>
  (await client.call("chat/consumption", { account: config.peer }))
    .consumed_through;
const output = (result) =>
  console.log(
    JSON.stringify({
      ...result,
      modelCalls,
      requests,
      checkpoints,
      native,
      model: "deterministic double; real native host/MCP/Dart/FastAPI",
    }),
  );
try {
  if (phase === "seed") {
    assert.equal(await cursor(), 0);
    agent.followup({
      id: "query-instruction",
      role: "user",
      source: { kind: "user" },
      content: [
        {
          type: "text",
          text: "Query only the specified later message, then explicitly send one reply.",
        },
      ],
    });
    await bridge.drain();
    const rows = bridge.journal.list();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].position, 3);
    assert.equal(rows[0].state, "presented");
    assert.equal(await cursor(), 0);
    assert.ok(
      requests.some((r) => r.code === "consumption_gap" && r.status === 409),
    );
    const operations = bridge.operations.status();
    assert.equal(operations.length, 1);
    assert.equal(operations[0].state, "succeeded");
    assert.equal(modelCalls, 3);
    await bridge.flush();
    await writeFile(
      resolve(root, "seed.json"),
      JSON.stringify({ row: rows[0], operations, identity: client.identity }),
    );
    output({
      status: "PASS",
      checkpoint: "gap-durable",
      watermark: 0,
      rowState: "presented",
      position: 3,
      operations,
    });
    await new Promise(() => setInterval(() => {}, 1000));
  } else {
    const seed = JSON.parse(await readFile(resolve(root, "seed.json")));
    const old = new Client(config.origin, root);
    old.identity = seed.identity;
    old.owner = client.owner;
    await assert.rejects(
      old.call("chat/ack_messages", {
        account: config.peer,
        through_position: 3,
      }),
      (e) =>
        e.status === 409 &&
        ["stale_binding", "stale_identity"].includes(e.code),
    );
    old.close();
    assert.equal(await cursor(), phase === "recover" ? 0 : 4);
    const identity = client.identity,
      owner = client.owner;
    const guards = [];
    for (const [fault, code] of [
      ["wrong-owner", "stale_binding"],
      ["old-generation", "stale_identity"],
      ["old-revision", "stale_binding"],
    ]) {
      if (fault === "wrong-owner") client.owner = "x".repeat(43);
      if (fault === "old-generation")
        client.identity = {
          ...identity,
          auth_generation: "obsolete-generation",
        };
      if (fault === "old-revision")
        client.identity = {
          ...identity,
          binding_revision: identity.binding_revision - 1,
        };
      try {
        await assert.rejects(
          bridge.recover(),
          (e) => e.status === 409 && e.code === code,
        );
        guards.push({ fault, code, status: 409 });
      } finally {
        client.identity = identity;
        client.owner = owner;
      }
    }
    try {
      await bridge.recover();
    } catch (error) {
      output({
        status: "FAIL",
        recoveryRejected: error.code,
        httpStatus: error.status,
        rowState: bridge.journal.list()[0].state,
        watermark: await cursor(),
      });
      throw error;
    }
    assert.equal(
      modelCalls,
      0,
      "recover must never replay the successful query/send turn",
    );
    if (phase === "recover") {
      assert.equal(await cursor(), 0, "gap is not permission to consume ahead");
      assert.equal(bridge.journal.list()[0].state, "presented");
    }
    await bridge.tick(config.peer);
    await bridge.drain();
    await bridge.tick(config.peer);
    await bridge.drain();
    assert.equal(await cursor(), 4);
    const rows = bridge.journal.list().sort((a, b) => a.position - b.position);
    assert.deepEqual(
      rows.map((r) => [r.position, r.state]),
      [1, 2, 3, 4].map((p) => [p, "completed"]),
    );
    const original = rows[2];
    for (const key of [
      "nativeId",
      "attempt",
      "turn",
      "requestDigest",
      "receiptId",
    ])
      assert.equal(
        original[key],
        seed.row[key],
        "successful query evidence remains unchanged",
      );
    const events = agent.session.snapshotEvents();
    const calls = events
      .filter((e) => e.type === "assistant/message")
      .flatMap((e) => e.data.message.content)
      .filter((b) => b.type === "tool-call");
    assert.deepEqual(
      calls.map((b) => b.id),
      ["query-position-3", "one-explicit-send"],
    );
    for (const row of rows.filter((r) => r.position !== 3))
      assert.equal(
        events.filter(
          (e) => e.type === "user/message" && e.data.id === row.nativeId,
        ).length,
        1,
      );
    assert.deepEqual(bridge.operations.status(), seed.operations);
    assert.ok(
      requests.some(
        (r) =>
          r.path === "/v2/operations/get" &&
          r.operation_id === seed.operations[0].operation_id,
      ),
    );
    assert.equal(requests.filter((r) => r.path.includes("send_")).length, 0);
    const messages = await client.call("chat/read_messages", {
      account: config.peer,
      after_position: 0,
      limit: 50,
    });
    assert.equal(
      messages.items.length,
      4,
      "three inputs plus exactly one original send",
    );
    if (phase === "replay") assert.equal(modelCalls, 0);
    output({
      status: "PASS",
      watermark: 4,
      positions: rows.map((r) => r.position),
      original_query_reexecuted: false,
      original_operation: seed.operations[0],
      business_messages: messages.items.length,
      outbound_native_calls_total: 1,
      restored_binding_rejects_old: true,
      recovery_guard_rejections: guards,
    });
  }
} finally {
  await bridge.close();
  await mcpFiber.dispose();
  client.close();
  await rt.close();
}
