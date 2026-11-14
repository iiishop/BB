// Real standalone Dart + FastAPI + official MCP + unchanged native DSH.
// Fault injection discards a real successful MCP send result before journaling.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { boot } from "../journal/host.mjs";
import { Client } from "../../bundle/client.js";
import { Bridge } from "../../bundle/bridge.js";
const [pkg, root, configPath, phase] = process.argv.slice(2);
const config = JSON.parse(await readFile(configPath));
const client = new Client(config.origin, resolve(root, "bridge"));
let modelCalls = 0,
  lost = 0,
  queryFailure = false;
const raw = client.raw.bind(client),
  requests = [];
client.raw = async (path, body, owner) => {
  if (queryFailure && path === "/v2/operations/get")
    throw new TypeError("injected lost query response");
  try {
    const value = await raw(path, body, owner);
    requests.push({ path, status: 200, through: body.through_position });
    return value;
  } catch (e) {
    requests.push({ path, status: e.status, code: e.code });
    throw e;
  }
};
const rt = await boot(
  pkg,
  resolve(root, "host"),
  async function* () {
    modelCalls++;
    const send = phase === "seed" && modelCalls === 1;
    if (send) {
      yield { type: "block-start", index: 0, blockType: "tool-call" };
      yield {
        type: "block-end",
        index: 0,
        block: {
          type: "tool-call",
          id: "send-once",
          name: "mcp__bb__send_message",
          arguments: JSON.stringify({
            target_account: config.peer,
            content: [{ type: "text", text: "one synthetic send" }],
          }),
        },
      };
    }
    yield { type: "finish", reason: { kind: send ? "tool-calls" : "stop" } };
  },
  () => {},
);
const agent = await rt.open("dea470-isolation", phase === "cold");
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
  resolve(root, "bridge"),
  async (name) => {
    if (name === "operation-result" && lost++ === 0)
      throw new TypeError("lost successful MCP response");
  },
).mount();
bridge.installOperations();
const cursor = async (account) =>
  (await client.call("chat/consumption", { account })).consumed_through;
async function inbound(peer, nonce) {
  const login = await fetch(config.api + "/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ account: peer, password: "Abc123" }),
  });
  assert.equal(login.status, 200);
  const { token } = await login.json();
  const sent = await fetch(config.api + "/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer " + token,
    },
    body: JSON.stringify({
      target_account: config.account,
      client_nonce: nonce,
      content: [{ type: "text", text: nonce }],
    }),
  });
  assert.equal(sent.status, 200);
}
async function poll(peer) {
  await bridge.poll(peer);
  await bridge.drain();
}
try {
  if (phase === "seed") {
    agent.followup({
      id: "send-command",
      role: "user",
      source: { kind: "user" },
      content: [{ type: "text", text: "Send one synthetic reply" }],
    });
    await bridge.drain();
    assert.equal(lost, 1);
    assert.equal(bridge.operations.status()[0].state, "dispatching");
    await inbound(config.peer, "a-after-lost-send");
    await inbound(config.peerB, "b-after-lost-send");
    await poll(config.peer);
    assert.equal(await cursor(config.peer), 0);
    const before = modelCalls;
    await poll(config.peerB);
    assert.ok(modelCalls > before, "peer B must reach the real native session");
    assert.equal(await cursor(config.peerB), 1);
    queryFailure = true;
    await bridge.recover();
    assert.equal(bridge.operations.status()[0].state, "uncertain");
    await inbound(config.peerB, "b-after-network-error");
    await poll(config.peerB);
    assert.equal(await cursor(config.peerB), 2);
    assert.equal(await cursor(config.peer), 0);
    queryFailure = false;
    await bridge.recover();
    assert.equal(bridge.operations.status()[0].state, "succeeded");
    await poll(config.peer);
    await poll(config.peer);
    assert.equal(await cursor(config.peer), 2);
    // Reserve an admitted-to-bridge but never-sent plan. The actual client answers 404.
    const absentExec = {
      agent,
      callId: "absent-manual",
      name: "mcp__bb__send_message",
      arguments: {
        operation_id: "absent-stable",
        target_account: config.peer,
        content: [],
      },
    };
    await bridge.operations.prepare(absentExec);
    await bridge.recover();
    assert.equal(
      bridge.operations.status().find((r) => r.operation_id === "absent-stable")
        .state,
      "failed_absent",
    );
    await assert.rejects(
      bridge.operations.prepare(absentExec),
      /do not redispatch/,
    );
    assert.ok(
      requests.some((r) => r.path === "/v2/operations/get" && r.status === 404),
    );
  } else {
    await bridge.recover();
    await poll(config.peer);
    await poll(config.peerB);
    assert.equal(modelCalls, 0, "cold recovery does not replay consumed input");
    assert.equal(
      bridge.operations.status().find((r) => r.operation_id === "absent-stable")
        .state,
      "failed_absent",
    );
  }
  const messages = await client.call("chat/read_messages", {
    account: config.peer,
    after_position: 0,
    limit: 50,
  });
  assert.equal(
    messages.items.filter((i) => i.message.sender_account === config.account)
      .length,
    1,
  );
  assert.equal(await cursor(config.peer), 2);
  assert.equal(await cursor(config.peerB), 2);
  assert.equal(bridge.journal.list().length, 4);
  assert.ok(bridge.journal.list().every((r) => r.state === "completed"));
  const native = agent.session.snapshotEvents();
  const sends = native
    .filter((e) => e.type === "assistant/message")
    .flatMap((e) => e.data.message.content)
    .filter(
      (b) => b.type === "tool-call" && b.name === "mcp__bb__send_message",
    );
  assert.equal(sends.length, 1);
  for (const row of bridge.journal.list())
    assert.equal(
      native.filter(
        (e) => e.type === "user/message" && e.data.id === row.nativeId,
      ).length,
      1,
    );
  console.log(
    JSON.stringify({
      status: "PASS",
      phase,
      modelCalls,
      sends: sends.length,
      watermarkA: 2,
      watermarkB: 2,
      completedInputs: 4,
      operations: bridge.operations.status(),
      model: "deterministic double",
      host_client_mcp: "real",
      requests,
    }),
  );
} finally {
  await bridge.close();
  await mcpFiber.dispose();
  client.close();
  await rt.close();
}
