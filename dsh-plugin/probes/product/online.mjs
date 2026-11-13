// Only the provider and one transient failure are injected; all business facts
// come from the actual standalone Dart API and FastAPI SQLite service.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { boot } from "../journal/host.mjs";
import { Client } from "../../bundle/client.js";
import { Bridge } from "../../bundle/bridge.js";
const [pkg, root, configPath] = process.argv.slice(2);
const config = JSON.parse(await readFile(configPath));
let failures = 0,
  modelCalls = 0;
const requests = [],
  native = [],
  states = [];
const proxy = createServer(async (req, res) => {
  try {
    const parts = [];
    for await (const part of req) parts.push(part);
    if (
      config.cut === "context" &&
      req.url === "/v2/chat/get_context" &&
      !failures
    ) {
      failures++;
      requests.push({ path: req.url, status: 503, injected: true });
      res.writeHead(503, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          error: {
            code: "storage_unavailable",
            message: "isolated one-shot failure",
            fields: [],
          },
        }),
      );
      return;
    }
    const headers = { ...req.headers };
    delete headers.host;
    delete headers.connection;
    delete headers["content-length"];
    const response = await fetch(config.origin + req.url, {
      method: req.method,
      headers,
      body: Buffer.concat(parts),
    });
    const bytes = Buffer.from(await response.arrayBuffer());
    requests.push({ path: req.url, status: response.status });
    res.writeHead(response.status, { "Content-Type": "application/json" });
    res.end(bytes);
  } catch {
    res.writeHead(502);
    res.end();
  }
});
await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
const client = new Client(
  `http://127.0.0.1:${proxy.address().port}`,
  resolve(root, "state"),
);
const rt = await boot(
  pkg,
  root,
  async function* () {
    modelCalls++;
    yield { type: "finish", reason: { kind: "stop" } };
  },
  (kind, data) => {
    if (kind === "event")
      native.push({ type: data.event.type, turn: data.event.data.turn });
  },
);
const agent = await rt.open("online-" + config.cut);
await client.bind(agent.session.id);
const bridge = await new Bridge(
  rt.ctx,
  agent,
  client,
  resolve(root, "state"),
  async (name) => {
    if (config.cut !== "context" && name === config.cut && !failures) {
      failures++;
      throw Object.assign(new Error("one-shot projection failure"), {
        status: 503,
      });
    }
  },
).mount();
const cursor = async () =>
  (await client.call("chat/consumption", { account: config.peer }))
    .consumed_through;
try {
  await assert.rejects(
    bridge.tick(config.peer),
    (error) => error.status === 503,
  );
  for (let n = 0; n < 4; n++) {
    await bridge.tick(config.peer);
    await bridge.drain();
    states.push({
      tick: n + 1,
      watermark: await cursor(),
      rows: bridge.status().items,
    });
  }
  const facts = agent.session.snapshotEvents();
  const projections = facts
    .filter((e) => e.type === "user/message")
    .flatMap((e) =>
      e.data.content
        .filter((b) => b.type === "text")
        .flatMap((b) => {
          try {
            const v = JSON.parse(b.text);
            return v.platform === "BB" && v.message?.position
              ? [v.message.position]
              : [];
          } catch {
            return [];
          }
        }),
    );
  const result = {
    failures,
    watermark: await cursor(),
    projections,
    modelCalls,
    states,
    requests,
    native,
    explicit_recover_calls: 0,
    model: "deterministic double; real stock DSH/Dart/FastAPI",
  };
  try {
    assert.equal(failures, 1);
    assert.equal(result.watermark, 2);
    assert.deepEqual(projections.sort(), [1, 2]);
    assert.ok(bridge.journal.list().every((r) => r.state === "completed"));
    assert.equal(facts.filter((e) => e.type === "tool/call").length, 0);
    const calls = modelCalls;
    await bridge.tick(config.peer);
    await bridge.drain();
    assert.equal(modelCalls, calls);
  } catch (error) {
    console.log(JSON.stringify({ ...result, status: "FAIL" }));
    throw error;
  }
  console.log(JSON.stringify({ ...result, status: "PASS" }));
} finally {
  await bridge.close();
  await rt.close();
  await new Promise((resolve) => proxy.close(resolve));
}
