// F5 contract regression derived from the Owner reproducer; client/model are doubles.
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { boot } from "../journal/host.mjs";
import { Bridge } from "../../bundle/bridge.js";
const root = await mkdtemp(process.argv[3] + "/operation-contract-");
let modelCalls = 0,
  operationGets = 0,
  messageReads = 0,
  sends = 0,
  missing = false;
const queriedIds = [];
const identity = {
  account: "10000001",
  consumer_id: "consumer-test",
  binding_revision: 1,
};
const fact = { operation_id: null, status: "succeeded" };
const rt = await boot(
  process.argv[2],
  root,
  async function* () {
    modelCalls++;
    if (modelCalls === 1) {
      yield { type: "block-start", index: 0, blockType: "tool-call" };
      yield {
        type: "block-end",
        index: 0,
        block: {
          type: "tool-call",
          id: "send-once",
          name: "mcp__bb__send_message",
          arguments: JSON.stringify({
            target_account: "10000002",
            content: [{ type: "text", text: "reply" }],
          }),
        },
      };
    }
    yield {
      type: "finish",
      reason: { kind: modelCalls === 1 ? "tool-calls" : "stop" },
    };
  },
  () => {},
);
const agent = await rt.open("operation-freeze");
const client = {
  identity,
  check: async () => {},
  call: async (path, args) => {
    if (path === "operations/get") {
      operationGets++;
      queriedIds.push(args.operation_id);
      if (missing) throw Object.assign(Error("unknown"), { status: 404 });
      return { ...fact };
    }
    if (path === "events/subscribe") return {};
    if (path === "events/read") return { items: [], has_more: false };
    if (path === "chat/consumption") return { consumed_through: 0 };
    if (path === "chat/read_messages") {
      messageReads++;
      return { items: [] };
    }
    throw Error(path);
  },
};
const disposers = [];
for (const name of ["send_message", "send_attachment", "start_download"])
  disposers.push(
    rt.ctx.tools.register({
      name: "mcp__bb__" + name,
      description: "test operation",
      parameters: {
        type: "object",
        properties: {
          operation_id: { type: "string" },
          target_account: { type: "string" },
          content: { type: "array", items: { type: "object" } },
        },
        required: ["operation_id"],
      },
      output: {
        schema: { type: "object" },
        render: (_, v) => [{ type: "text", text: JSON.stringify(v) }],
      },
      execute: async (args) => {
        sends++;
        fact.operation_id = args.operation_id;
        throw Error(
          "simulated lost response AFTER client committed successful send",
        );
      },
    }),
  );
const bridge = await new Bridge(rt.ctx, agent, client, root).mount();
bridge.installOperations();
try {
  agent.followup({
    id: "trigger",
    role: "user",
    source: { kind: "user" },
    content: [{ type: "text", text: "Send one reply" }],
  });
  await bridge.drain();
  assert.equal(fact.status, "succeeded");
  assert.ok(fact.operation_id);
  const queried = await client.call("operations/get", {
    operation_id: fact.operation_id,
  });
  assert.equal(queried.status, "succeeded");
  for (let i = 0; i < 3; i++) await bridge.tick("10000002");
  assert.equal(sends, 1);
  assert.equal(bridge.operations.status()[0].state, "dispatching");
  assert.equal(messageReads, 0);
  missing = true;
  await bridge.recover();
  assert.equal(bridge.operations.status()[0].state, "failed_absent");
  await bridge.tick("10000002");
  assert.equal(messageReads, 1);
  missing = false;
  await bridge.recover();
  await bridge.tick("10000002");
  assert.equal(messageReads, 2);
  assert.equal(sends, 1);
  assert.ok(queriedIds.every((id) => id === fact.operation_id));
  assert.equal(bridge.operations.status()[0].state, "succeeded");
  console.log(
    JSON.stringify({
      status: "PASS",
      classification:
        "DEA-470: absent lookup terminates locally; original ID remains reserved",
      model: "deterministic double",
      client: "fault double",
      host: "stock",
      sends,
      operationGets,
      messageReads,
      afterTicks: 3,
      original_id_only: true,
      absent_releases_input_without_resend: true,
    }),
  );
} finally {
  await bridge.close();
  for (const d of disposers) d();
  await rt.close();
  await rm(root, { recursive: true, force: true });
}
