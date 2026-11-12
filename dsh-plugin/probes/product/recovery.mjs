// Execute product bridge code against stock DSH and the real v2 client.
import assert from "node:assert/strict";
import { readFile, writeFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import { boot } from "../journal/host.mjs";
import { Client } from "../../bundle/client.js";
import { Bridge } from "../../bundle/bridge.js";
const [pkg, root, configPath, cut, phase] = process.argv.slice(2);
const config = JSON.parse(await readFile(configPath));
const client = new Client(config.origin, resolve(root, "state"));
const requests = [],
  native = [];
let modelCalls = 0;
const raw = client.raw.bind(client);
client.raw = async (path, body, owner) => {
  try {
    const value = await raw(path, body, owner);
    requests.push({ path, status: 200, through: body.through_position });
    return value;
  } catch (e) {
    requests.push({ path, status: e.status });
    throw e;
  }
};
const rt = await boot(
  pkg,
  root,
  async function* () {
    modelCalls++;
    if (cut === "provider-unknown") await checkpoint("provider-unknown");
    const wait =
      cut.startsWith("wait-") && phase === "crash" && modelCalls === 1;
    const send =
      cut === "operation-result" && phase === "crash" && modelCalls === 1;
    if (wait) {
      yield { type: "block-start", index: 0, blockType: "tool-call" };
      yield {
        type: "block-end",
        index: 0,
        block: {
          type: "tool-call",
          id: "real-wait",
          name: "mcp__bb__wait_messages",
          arguments: JSON.stringify({
            account: config.peer,
            seen_position: 0,
            timeout: 30,
          }),
        },
      };
    }
    if (send) {
      yield { type: "block-start", index: 0, blockType: "tool-call" };
      yield {
        type: "block-end",
        index: 0,
        block: {
          type: "tool-call",
          id: "real-send",
          name: "mcp__bb__send_message",
          arguments: JSON.stringify({
            target_account: config.peer,
            content: [{ type: "text", text: "synthetic stable product send" }],
          }),
        },
      };
    }
    yield {
      type: "finish",
      reason: { kind: wait || send ? "tool-calls" : "stop" },
    };
  },
  (kind, data) => native.push({ kind, ...data }),
);
const agent = await rt.open("product-recovery", phase === "recover");
const oldName =
  phase === "recover" &&
  (await readdir(resolve(root, "state"))).find((n) => n.startsWith("binding-"));
const old = oldName
  ? JSON.parse(await readFile(resolve(root, "state", oldName)))
  : null;
await client.bind(agent.session.id);
if (old) {
  const stale = new Client(config.origin, root);
  stale.identity = old.identity;
  stale.owner = old.owner_key;
  await assert.rejects(
    stale.call("chat/ack_messages", {
      account: config.peer,
      through_position: 1,
    }),
    (e) => e.status === 409 && e.code === "stale_binding",
  );
  stale.close();
}
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
const before = await client.call("chat/consumption", { account: config.peer });
async function checkpoint(name) {
  if (
    phase === "crash" &&
    name ===
      (cut === "wait-claimed"
        ? "claimed"
        : cut === "wait-confirmed"
          ? "confirmed"
          : cut)
  ) {
    await writeFile(
      resolve(root, "before.json"),
      JSON.stringify({ modelCalls, requests, native }),
    );
    console.log(JSON.stringify({ checkpoint: cut }));
    await new Promise(() => setInterval(() => {}, 1000));
  }
}
const bridge = await new Bridge(
  rt.ctx,
  agent,
  client,
  resolve(root, "state"),
  checkpoint,
).mount();
bridge.installOperations();
try {
  if (phase === "crash") {
    if (cut.startsWith("wait-"))
      agent.followup({
        id: "wait-instruction",
        role: "user",
        source: { kind: "user" },
        content: [
          { type: "text", text: "synthetic instruction: wait for BB input" },
        ],
      });
    else await bridge.poll(config.peer);
    await bridge.drain();
    throw new Error("Did not reach crash barrier");
  }
  await bridge.recover();
  await bridge.drain();
  const after = await client.call("chat/consumption", { account: config.peer });
  const rows = bridge.status().items;
  assert.equal(rows.length, 1);
  if (["dispatching", "provider-unknown", "operation-result"].includes(cut)) {
    assert.equal(rows[0].state, "uncertain");
    assert.equal(after.consumed_through, 0);
    assert.equal(modelCalls, 0);
    await bridge.poll(config.peer);
    await bridge.drain();
    assert.equal(modelCalls, 0);
  } else {
    assert.equal(rows[0].state, "completed", JSON.stringify(bridge.status()));
    assert.equal(after.consumed_through, 1);
    assert.equal(
      modelCalls,
      ["claimed", "wait-claimed", "pending"].includes(cut) ? 1 : 0,
    );
  }
  if (cut === "operation-result") {
    const operations = bridge.operations.status();
    assert.equal(operations.length, 1);
    assert.equal(operations[0].state, "succeeded");
    const page = await client.call("chat/read_messages", {
      account: config.peer,
      after_position: 0,
      limit: 100,
    });
    assert.equal(page.items.length, 2);
    assert.ok(requests.some((r) => r.path === "/v2/operations/get"));
    assert.equal(
      requests.filter((r) => r.path === "/v2/chat/send_message").length,
      0,
    );
  }
  const result = {
    operations: bridge.operations.status(),
    old_binding_ack: "409 stale_binding",
    case: cut,
    status: "PASS",
    provider: "deterministic double",
    before: before.consumed_through,
    after: after.consumed_through,
    modelCalls,
    rows,
    requests,
  };
  await writeFile(
    resolve(root, "recovered.json"),
    JSON.stringify({ result, native }, null, 2) + "\n",
  );
  console.log(JSON.stringify(result));
} finally {
  await bridge.close();
  await mcpFiber.dispose();
  client.close();
  await rt.close();
}
