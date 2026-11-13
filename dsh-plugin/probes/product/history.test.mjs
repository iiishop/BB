import test from "node:test";
import assert from "node:assert/strict";
import { History, HISTORY_BUDGET } from "../../bundle/history.js";

function harness(items, overrides = {}) {
  const page = {
    peer_account: "10000002",
    anchor_message_id: "new",
    range: { start_position: 1, end_position: 9 },
    before_has_more: true,
    missing_positions: [4],
    missing_truncated: false,
    missing_media_ids: ["missing-image"],
    reply_relations: "unsupported",
    items,
  };
  const journal = [];
  const bridge = {
    agent: { session: { id: "native", header: { createdAt: 1 } } },
    journal: { list: () => journal },
    client: {
      call: async (path) =>
        path === "chat/consumption" ? { consumed_through: 8 } : page,
    },
    async content(item) {
      return [
        { type: "text", text: JSON.stringify(item.message) },
        ...item.blocks.map((b) =>
          b.type === "image"
            ? { type: "image", attachment: { id: b.data } }
            : b,
        ),
      ];
    },
    ...overrides,
  };
  return {
    history: new History(bridge),
    journal,
    bridge,
    row: {
      key: "new",
      peer: "10000002",
      messageId: "new",
      position: 9,
      session: "native",
    },
  };
}
const item = (n, blocks) => ({
  message: {
    id: "m" + n,
    position: n,
    sender_account: "10000001",
    target_account: "10000002",
    created_at: "synthetic",
    kind: "body",
    content: blocks.map((b) =>
      b.type === "image" ? { type: "image", media_id: "image-" + n } : b,
    ),
  },
  blocks,
});

test("bounded history preserves order, labels omissions and never commits receipts", async () => {
  const h = harness([
    item(1, [{ type: "text", text: "x".repeat(20000) }]),
    item(2, [
      { type: "text", text: "before" },
      { type: "image", data: "AQ==", mime_type: "image/png" },
      { type: "text", text: "between" },
      { type: "image", data: "Ag==", mime_type: "image/png" },
      { type: "image", data: "Aw==", mime_type: "image/png" },
    ]),
  ]);
  const result = await h.history.prepare(h.row);
  assert.deepEqual(
    result.metadata.included.map((x) => x.message_id),
    ["m2"],
  );
  assert.deepEqual(
    result.content.map((x) => x.type),
    ["text", "text", "text", "image", "text", "image", "text"],
  );
  assert.ok(result.metadata.omitted.some((x) => x.reason === "text_budget"));
  assert.ok(
    result.metadata.omitted.some(
      (x) => x.reason === "image_budget" && x.block_index === 4,
    ),
  );
  assert.deepEqual(result.metadata.missing_positions, [4]);
  assert.deepEqual(result.metadata.missing_media_ids, ["missing-image"]);
  assert.equal(result.metadata.before_has_more, true);
  assert.equal(result.metadata.continuation.exact.tool, "get_message");
  assert.ok(
    result.content.reduce(
      (n, b) => n + (b.type === "text" ? Buffer.byteLength(b.text) : 0),
      0,
    ) <= HISTORY_BUDGET.text_bytes,
  );
});

test("session birth and peer scope initialization; unconsumed history is excluded", async () => {
  const h = harness([
    item(1, [{ type: "text", text: "old" }]),
    item(8, [{ type: "text", text: "unconsumed" }]),
  ]);
  h.bridge.client.call = async (path) =>
    path === "chat/consumption"
      ? { consumed_through: 1 }
      : {
          peer_account: "10000002",
          anchor_message_id: "new",
          range: { start_position: 1, end_position: 9 },
          items: [
            item(1, [{ type: "text", text: "old" }]),
            item(8, [{ type: "text", text: "unconsumed" }]),
          ],
          before_has_more: false,
          missing_positions: [],
          missing_truncated: false,
          reply_relations: "unsupported",
        };
  const first = await h.history.prepare(h.row);
  assert.deepEqual(
    first.metadata.included.map((x) => x.position),
    [1],
  );
  assert.equal(first.metadata.omitted[0].reason, "unconsumed_not_history");
  h.journal.push({ key: "prior", bootstrap: first.metadata });
  assert.deepEqual(await h.history.prepare(h.row), { content: [] });
  h.bridge.agent.session.header.createdAt = 2;
  assert.ok((await h.history.prepare(h.row)).metadata);
});

test("missing historical image is explicit; large metadata also respects text budget", async () => {
  const blocks = Array.from({ length: 100 }, () => ({
    type: "image",
    data: "AQ==",
    mime_type: "image/png",
  }));
  const h = harness(Array.from({ length: 8 }, (_, i) => item(i + 1, blocks)));
  const original = h.bridge.content;
  h.bridge.content = async (i) => {
    if (i.blocks.some((b) => b.type === "image"))
      throw new Error("missing native media");
    return original(i);
  };
  const r = await h.history.prepare(h.row);
  assert.equal(r.content.filter((b) => b.type === "image").length, 0);
  assert.ok(r.metadata.omitted_details_truncated);
  assert.ok(r.metadata.omitted_count > 8);
  assert.ok(
    r.content.reduce(
      (n, b) => n + (b.type === "text" ? Buffer.byteLength(b.text) : 0),
      0,
    ) <= HISTORY_BUDGET.text_bytes,
  );
});
