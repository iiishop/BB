// Real stock driver + metadata journal; explicit client confirmation TEST DOUBLE.
// This does not prove the Dart client's commit-time fencing or v2 implementation.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { boot } from './host.mjs';
import { JournalBridge, createJournal, eventKey } from './bridge.mjs';

const [pkgArg, output] = process.argv.slice(2);
assert.ok(pkgArg && output, 'Usage: node settlement.mjs <fixed DSH package> <evidence parent>');
const pkg = resolve(pkgArg);
await mkdir(output, { recursive: true });
const root = await mkdtemp(resolve(output, 'dea467-settlement-'));
const sha = value => createHash('sha256').update(value).digest('hex');
const externalFiles = ['dsh-agent-loop/lib/index.js', 'dsh-agent/lib/types/runtime-types.d.ts',
  'dsh-llm/lib/index.js', 'dsh-tools/lib/index.js', 'dsh-session/lib/index.js',
  'dsh-session-persistence-jsonl/lib/index.js', 'dsh-storage-domain/lib/index.js', 'dsh-storage-json/lib/index.js'];
const external = {};
for (const file of externalFiles) external[file] = sha(await readFile(resolve(pkg, 'node_modules/@deepseek-ai', file)));
assert.equal(external[externalFiles[0]], 'cf57e3ecd487ac5c2553455aaa5cef2c6fb41e6bd61be5aa455675d1d7193033');
const probe = {};
for (const file of ['settlement.mjs', 'bridge.mjs', 'host.mjs']) {
  probe[file] = sha(await readFile(new URL(file, import.meta.url)));
}
await writeFile(resolve(root, 'sources.json'), JSON.stringify({ external, probe, node: process.version }, null, 2) + '\n');
const results = [];
for (const mode of ['confirm-before-commit', 'ack-after-commit', 'switch-after-confirm', 'switch-after-ack', 'dispose']) {
  const dir = resolve(root, mode); await mkdir(dir);
  const binding = { account: '10000001', consumer: 'consumer-one', generation: 1, revision: 1 };
  let identity = binding, providerCalls = 0, confirmCalls = 0, ackCalls = 0, commits = 0, failOnce = true;
  const watermarks = new Map(), confirmations = new Map(), events = [];
  const scope = value => JSON.stringify(value);
  const runtime = await boot(pkg, dir, async function* () {
    providerCalls++; yield { type: 'finish', reason: { kind: 'stop' } };
  }, (kind, value) => { if (kind === 'event' || kind === 'error') events.push({ kind, ...value }); });
  const journal = await createJournal(runtime), agent = await runtime.open(`settlement-${mode}`);
  const client = {
    identity: () => identity,
    async confirm(value) {
      confirmCalls++; assert.deepEqual(value.binding, identity);
      if (mode === 'confirm-before-commit' && failOnce) { failOnce = false; throw new Error('synthetic confirmation unavailable'); }
      const previous = confirmations.get(value.key);
      if (previous) assert.deepEqual(value, previous, 'retries cannot change confirmation intent');
      confirmations.set(value.key, value);
      if (mode === 'switch-after-confirm') identity = { ...binding, generation: 2 };
    },
    async ack(value) {
      ackCalls++; assert.deepEqual(value.binding, identity);
      assert.ok(confirmations.has(value.key));
      const key = scope(value.binding), previous = watermarks.get(key) ?? 0;
      assert.ok(value.position === previous || value.position === previous + 1);
      if (value.position > previous) { watermarks.set(key, value.position); commits++; }
      if (mode === 'ack-after-commit' && failOnce) { failOnce = false; throw new Error('synthetic ACK receipt lost after commit'); }
      if (mode === 'switch-after-ack') identity = { ...binding, generation: 2 };
    },
  };
  const bridge = new JournalBridge(runtime.ctx, agent, journal, binding, client);
  await bridge.mount();
  const event = { account: binding.account, consumer: binding.consumer, peer: '10000002',
    event_id: mode, position: 1, content: [{ type: 'text', text: `synthetic ${mode}` }] };
  let disposed = false;
  try {
    await bridge.accept(event);
    if (mode === 'dispose') await bridge.drain();
    else await assert.rejects(bridge.drain(), AggregateError);
    assert.equal(providerCalls, 1);
    const first = journal.get('events', eventKey(event));
    if (mode !== 'dispose') assert.equal(first.state, 'active', 'failed settlement must not be recorded as completed');
    if (mode === 'confirm-before-commit' || mode === 'ack-after-commit') {
      if (mode === 'confirm-before-commit') assert.equal(watermarks.get(scope(binding)) ?? 0, 0);
      await bridge.reconcile(event); await bridge.drain();
      assert.equal(journal.get('events', eventKey(event)).state, 'completed');
      assert.equal(providerCalls, 1, 'settlement retry must not redispatch model');
      assert.equal(commits, 1);
      assert.equal(confirmCalls, 2);
      assert.equal(ackCalls, mode === 'ack-after-commit' ? 2 : 1);
    } else if (mode.startsWith('switch')) {
      await assert.rejects(bridge.reconcile(event), /stale identity/);
      assert.equal(watermarks.get(scope(identity)) ?? 0, 0, 'new identity must not inherit old commit');
      assert.equal(ackCalls, mode === 'switch-after-confirm' ? 0 : 1);
      assert.equal(journal.get('events', eventKey(event)).state, 'active');
    } else {
      await bridge.close(); disposed = true;
      await assert.rejects(bridge.accept({ ...event, event_id: 'late-callback' }), /disposed/);
      // Native session remains usable; removed plugin observers cannot settle later turns.
      agent.followup({ id: 'post-dispose', role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text: 'synthetic native followup' }] });
      await agent.whenIdle();
      assert.equal(providerCalls, 2); assert.equal(confirmCalls, 1); assert.equal(ackCalls, 1);
    }
    const projections = agent.session.snapshotEvents().filter(e => e.type === 'user/message');
    assert.equal(projections.length, mode === 'dispose' ? 2 : 1);
    const result = { mode, assertions: 'PASS', providerCalls, confirmCalls, ackCalls, commits,
      original_watermark: watermarks.get(scope(binding)) ?? 0,
      current_watermark: watermarks.get(scope(identity)) ?? 0,
      journal_state: journal.get('events', eventKey(event)).state, projection_count: projections.length };
    results.push(result);
    await writeFile(resolve(dir, 'trace.json'), JSON.stringify({ result, events }, null, 2) + '\n');
  } finally {
    if (!disposed) await bridge.close();
    await journal.close(); await runtime.close();
  }
}
for (const file of externalFiles) assert.equal(sha(await readFile(resolve(pkg, 'node_modules/@deepseek-ai', file))), external[file]);
const summary = { assertions: 'PASS', cases: results, external_hashes_unchanged: true,
  scope: 'Real stock host; deterministic model and explicit confirmation/ACK TEST DOUBLE',
  NOT_PROVEN: ['real client commit-time identity fencing', 'in-flight disable cancellation', 'wait/event arbitration',
    'multi-process ownership', 'download recovery', 'v2 HTTP implementation', 'whole product gate'] };
await writeFile(resolve(root, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({ evidence: root, ...summary }));
