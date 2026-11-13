// Real v2 confirmation/ACK, stock host, deterministic model. Ignore one real
// successful response to simulate plugin receipt loss; no client ledger double.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { boot } from './host.mjs';
import { JournalBridge, createJournal, eventKey } from './bridge.mjs';

const [pkg, root, configPath, mode] = process.argv.slice(2);
const config = JSON.parse(await readFile(configPath));
const origin = new URL(config.origin);
assert.equal(origin.hostname, '127.0.0.1'); assert.equal(origin.protocol, 'http:');
const calls = [], native = [];
async function post(path, body) {
  const response = await fetch(new URL(path, origin), { method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-BB-Consumer-Key': config.owner_key },
    body: JSON.stringify({ ...body, expected_identity: config.identity }),
    signal: AbortSignal.timeout(10000), redirect: 'error' });
  calls.push({ path, status: response.status, through_position: body.through_position });
  assert.equal(response.status, 200, `${path}: ${response.status}`);
  const value = await response.json(); assert.deepEqual(value.identity, config.identity); return value.result;
}
const page = await post('/v2/chat/read_messages', { account: config.peer, after_position: 0, limit: 100 });
assert.ok(page.items.length && !page.has_more);
const receipts = page.items.map(item => item.presentation.receipt_id);
const through = Math.max(...page.items.map(item => item.message.position));
let providerCalls = 0, lost = false;
const runtime = await boot(pkg, root, async function* () {
  providerCalls++; yield { type: 'finish', reason: { kind: 'stop' } };
}, (kind, data) => native.push({ kind, ...data }));
const journal = await createJournal(runtime), agent = await runtime.open(`real-settlement-${mode}`);
// The bridge's legacy probe shape is local metadata only; every HTTP request
// carries the actual opaque v2 generation/revision from the private config.
const binding = { account: config.identity.account, consumer: config.identity.consumer_id, generation: 1, revision: 1 };
const client = {
  identity: () => binding,
  async confirm({ attempt, digest }) {
    await post('/v2/chat/confirm_presentation', { attempt_id: attempt, request_digest: digest, receipt_ids: receipts });
    if (mode === 'confirm-lost' && !lost) { lost = true; throw new Error('injected local loss of successful confirm response'); }
  },
  async ack({ position }) {
    await post('/v2/chat/ack_messages', { account: config.peer, through_position: position });
    if (mode === 'ack-lost' && !lost) { lost = true; throw new Error('injected local loss of successful ACK response'); }
  },
};
const bridge = new JournalBridge(runtime.ctx, agent, journal, binding, client);
await bridge.mount();
const event = { account: binding.account, consumer: binding.consumer, peer: config.peer,
  event_id: mode, position: through, content: page.items.flatMap(item => item.blocks) };
try {
  const before = await post('/v2/chat/consumption', { account: config.peer });
  assert.equal(before.consumed_through, 0);
  await bridge.accept(event); await assert.rejects(bridge.drain(), AggregateError);
  assert.equal(providerCalls, 1); assert.equal(journal.get('events', eventKey(event)).state, 'active');
  const interrupted = await post('/v2/chat/consumption', { account: config.peer });
  assert.equal(interrupted.consumed_through, mode === 'confirm-lost' ? 0 : through);
  await bridge.reconcile(event); await bridge.drain();
  const after = await post('/v2/chat/consumption', { account: config.peer });
  assert.equal(after.consumed_through, through); assert.equal(providerCalls, 1);
  assert.equal(journal.get('events', eventKey(event)).state, 'completed');
  const result = { mode, real_client: true, provider: 'deterministic double', providerCalls,
    projections: agent.session.snapshotEvents().filter(e => e.type === 'user/message').length,
    before: before.consumed_through, interrupted: interrupted.consumed_through, after: after.consumed_through, calls };
  assert.equal(result.projections, 1);
  await writeFile(resolve(root, 'evidence.json'), JSON.stringify({ result, native }, null, 2) + '\n');
  console.log(JSON.stringify(result));
} finally { await bridge.close(); await journal.close(); await runtime.close(); }
