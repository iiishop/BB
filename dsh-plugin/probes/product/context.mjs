import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { boot } from "../journal/host.mjs";
import { Client } from "../../bundle/client.js";
import { Bridge } from "../../bundle/bridge.js";
const [pkg, root, configPath, phase] = process.argv.slice(2),
  config = JSON.parse(await readFile(configPath));
const nativeRoot = ["rebuilt", "uncertain"].includes(phase)
  ? resolve(root, "rebuilt")
  : phase === "lost"
    ? resolve(root, "lost")
    : root;
const client = new Client(config.origin, resolve(root, "state"));
let bridge,
  modelCalls = 0;
const requests = [],
  watermarks = [],
  projected = [];
const raw = client.raw.bind(client);
client.raw = async (path, body, owner) => {
  requests.push({
    path,
    through_position: body.through_position,
    receipt_ids: body.receipt_ids,
  });
  return raw(path, body, owner);
};
const rt = await boot(
  pkg,
  nativeRoot,
  async function* (options) {
    modelCalls++;
    projected.push(options.messages);
    watermarks.push(
      (await client.call("chat/consumption", { account: config.peer }))
        .consumed_through,
    );
    if (phase === "uncertain")
      throw new Error("deterministic unknown model result");
    yield { type: "finish", reason: { kind: "stop" } };
  },
  () => {},
  { images: true },
);
const session = phase === "seed" ? "context-original" : "context-fresh";
const agent = await rt.open(session, ["resume", "uncertain"].includes(phase));
await client.bind(session);
bridge = await new Bridge(
  rt.ctx,
  agent,
  client,
  resolve(root, "state"),
).mount();
try {
  const before = (
    await client.call("chat/consumption", { account: config.peer })
  ).consumed_through;
  if (phase === "lost") {
    await assert.rejects(
      bridge.recover(),
      (e) =>
        e.code === "recovery_session_required" &&
        e.required_sessions.includes("context-fresh"),
    );
    assert.ok(bridge.journal.list().some((r) => r.state === "uncertain"));
    assert.equal(modelCalls, 0);
    const result = {
      phase,
      status: "PASS",
      recovery: "REJECTED_original_native_session_required",
      uncertain_retained: true,
      watermark: before,
      modelCalls,
    };
    await writeFile(
      resolve(root, phase + ".json"),
      JSON.stringify(result, null, 2) + "\n",
    );
    console.log(JSON.stringify(result));
  } else {
    await bridge.recover();
    await bridge.poll(config.peer);
    await bridge.drain();
    const after = (
      await client.call("chat/consumption", { account: config.peer })
    ).consumed_through;
    const rows = bridge.journal.list();
    const added = rows.filter((r) => r.position > before);
    assert.equal(
      added.length,
      phase === "seed" ? 3 : 1,
      "history must never become new jobs",
    );
    const current = added.at(-1),
      message = projected.at(-1)?.find((m) => m.id === current.nativeId);
    const bootstrap = message?.content
      .filter((b) => b.type === "text")
      .map((b) => {
        try {
          return JSON.parse(b.text);
        } catch {
          return {};
        }
      })
      .find((x) => x.kind === "history_context");
    if (phase === "new" || phase === "rebuilt") {
      assert.ok(bootstrap);
      assert.equal(bootstrap.context_only, true);
      assert.equal(bootstrap.consumed_through, before);
      assert.equal(bootstrap.included.length, before);
      assert.ok(bootstrap.included.every((x) => x.position <= before));
      assert.equal(
        watermarks[0],
        before,
        "historical context must not consume before the model returns",
      );
      assert.equal(
        agent.session.snapshotEvents().filter((e) => e.type === "user/message")
          .length,
        1,
        "one increment, one native input",
      );
      assert.equal(
        message.content.filter((b) => b.type === "image").length,
        2,
        "ordered historical images survive real native projection",
      );
      const refs = message.content
        .filter((b) => b.type === "image")
        .map((b) => b.attachment);
      assert.notDeepEqual(refs[0], refs[1]);
      for (const [i, ref] of refs.entries())
        assert.deepEqual(
          Buffer.from((await rt.ctx.attachments.readImage(ref)).data),
          Buffer.from(config.images[i], "base64"),
          "native historical image bytes retain red/blue order",
        );
      assert.equal(
        current.bootstrap.session_created_at,
        agent.session.header.createdAt,
      );
    } else if (phase === "resume") {
      assert.equal(bootstrap, undefined);
      assert.equal(
        requests.filter((r) => r.path === "/v2/chat/get_context").length,
        0,
        "restored session remains incremental",
      );
      const same = rows.filter(
        (r) =>
          r.bootstrap?.session_id === session &&
          r.bootstrap.session_created_at === agent.session.header.createdAt,
      );
      assert.equal(same.length, 1, "one durable session/peer initialization");
    }
    if (phase === "uncertain") {
      assert.equal(after, before);
      assert.equal(current.state, "uncertain");
    } else assert.equal(after, before + added.length);
    assert.equal(
      requests.filter((r) => r.path.includes("send_")).length,
      0,
      "context cannot produce outbound sends",
    );
    const confirmed = requests
      .filter((r) => r.path === "/v2/chat/confirm_presentation")
      .flatMap((r) => r.receipt_ids);
    assert.ok(
      confirmed.every((id) => added.some((r) => r.receiptId === id)),
      "no history receipt may be confirmed",
    );
    const result = {
      phase,
      status: "PASS",
      before,
      after,
      modelCalls,
      history: bootstrap
        ? {
            included: bootstrap.included,
            budget: bootstrap.budget,
            missing_positions: bootstrap.missing_positions,
          }
        : null,
      new_jobs: added.length,
      confirmed_receipts: confirmed.length,
      provider: "deterministic double",
      native_images:
        message?.content.filter((b) => b.type === "image").length ?? 0,
      requests,
    };
    await writeFile(
      resolve(root, phase + ".json"),
      JSON.stringify(result, null, 2) + "\n",
    );
    console.log(JSON.stringify(result));
  }
} finally {
  await bridge.close();
  client.close();
  await rt.close();
}
