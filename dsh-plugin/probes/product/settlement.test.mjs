// Component fault injection only. live.py BB_PRODUCT_CASES=gap is the real seam.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Bridge } from "../../bundle/bridge.js";

function settlement(failAt, error) {
  let row = {
    key: "input",
    state: "presented",
    nativeId: "projected",
    turn: 1,
    position: 3,
    peer: "10000002",
    receiptId: "receipt",
  };
  const requests = [],
    checkpoints = [];
  const b = new Bridge(
    { sessions: { flush: async () => true } },
    {
      session: {
        snapshotEvents: () => [
          {
            type: "tool/result",
            data: { message: { id: "projected", isError: false } },
          },
          {
            type: "turn/end",
            data: { turn: 1, reason: { kind: "completed" } },
          },
        ],
      },
    },
    {
      identity: { account: "10000001", consumer_id: "consumer" },
      check: async () => {},
      call: async (path) => {
        requests.push(path);
        if (path === failAt) throw error;
        return { consumed_through: 0 };
      },
    },
    "/unused-component-root",
    async (name) => checkpoints.push(name),
  );
  b.journal = {
    list: () => [row],
    get: () => row,
    put: async (value) => {
      row = value;
    },
  };
  return { b, input: row, requests, checkpoints, current: () => row };
}
test("gap defers commit while retaining the successful turn's receipt", async () => {
  const s = settlement("chat/ack_messages", {
    status: 409,
    code: "consumption_gap",
  });
  await s.b.settle(s.input);
  assert.equal(s.current(), s.input);
  assert.equal(s.current().state, "presented");
  assert.deepEqual(s.checkpoints, ["turn-success", "confirmed"]);
  assert.deepEqual(s.requests, [
    "chat/confirm_presentation",
    "chat/consumption",
    "chat/ack_messages",
  ]);
});
for (const [path, status, code] of [
  ["chat/ack_messages", 409, "stale_identity"],
  ["chat/ack_messages", 409, "stale_binding"],
  ["chat/ack_messages", 409, "migration_required"],
  ["chat/ack_messages", 401, "unauthenticated"],
  ["chat/ack_messages", 500, "consumption_gap"],
  ["chat/confirm_presentation", 409, "consumption_gap"],
])
  test(`${path}: ${status} ${code} still rejects and preserves evidence`, async () => {
    const error = { status, code },
      s = settlement(path, error);
    await assert.rejects(s.b.settle(s.input), (e) => e === error);
    assert.equal(s.current(), s.input);
    assert.equal(s.current().state, "presented");
    assert.ok(!s.checkpoints.includes("acked"));
  });
