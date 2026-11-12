import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { boot } from './host.mjs';
import { JournalBridge, createJournal, eventKey } from './bridge.mjs';

const [pkg, root] = process.argv.slice(2);
await mkdir(root, { recursive: true });
const binding = { account: '10000001', consumer: 'consumer-a', generation: 1, revision: 1 };
let identity = binding, release, entered;
const started = new Promise(done => { entered = done; });
const wait = new Promise(done => { release = done; });
const requests = [], commits = [];
let watermark = 0;
const runtime = await boot(pkg, root, async function* (request) {
  requests.push(request.messages.filter(m => m.role === 'user').map(m => m.id));
  if (requests.length === 1) { entered(); await wait; }
  yield { type: 'finish', reason: { kind: 'stop' } };
}, () => {});
const journal = await createJournal(runtime);
const agent = await runtime.open('busy-session');
const confirmed = new Set();
const client = { identity: () => identity,
  async confirm({ key }) { confirmed.add(key); },
  async ack({ key, position }) { assert.ok(confirmed.has(key)); assert.equal(position, watermark + 1); watermark = position; commits.push(position); },
};
const bridge = new JournalBridge(runtime.ctx, agent, journal, binding, client);
await bridge.mount();
const events = [1, 2, 3].map(position => ({ account: binding.account, consumer: binding.consumer,
  peer: '10000002', event_id: `busy-${position}`, position, content: [{ type: 'text', text: `synthetic ${position}` }] }));
try {
  await bridge.accept(events[0]); await started;
  await Promise.all(events.slice(1).flatMap(event => Array.from({ length: 12 }, () => bridge.accept(event))));
  assert.equal(watermark, 0, 'queued/received must not be consumed');
  assert.equal(agent.inbox.nextTurn.length, 2);
  release(); await bridge.drain();
  assert.equal(requests.length, 3);
  assert.deepEqual(commits, [1, 2, 3]);
  for (const event of events) assert.equal(journal.get('events', eventKey(event)).state, 'completed');
  await Promise.all(events.map(event => bridge.accept(event))); await bridge.drain();
  assert.equal(requests.length, 3);
  const before = [...journal.domain.table('events').entries()];
  await assert.rejects(journal.put('events', 'invalid', { position: 'bad' }));
  assert.deepEqual([...journal.domain.table('events').entries()], before, 'write validation must precede persistence');
  // In-flight callback and session rebuild are deliberately fail-closed, not accepted as successful rebind.
  identity = { ...binding, generation: 2 };
  await assert.rejects(bridge.accept({ ...events[2], event_id: 'stale-callback', position: 4 }), /stale/);
  identity = binding;
  await writeFile(resolve(root, 'busy.json'), JSON.stringify({ provider_calls: requests.length, requests, commits,
    queued_watermark: 0, final_watermark: watermark, stale_callback: 'rejected', invalid_write: 'rejected before persistence',
    limits: 'Client confirmation double; real wait/download/session-rebind integration NOT RUN' }, null, 2) + '\n');
  console.log(JSON.stringify({ busy: 'PASS', provider_calls: requests.length, commits }));
} finally { release(); await bridge.close(); await journal.close(); await runtime.close(); }
