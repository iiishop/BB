import assert from 'node:assert/strict';
import { open, mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { boot } from './host.mjs';
import { JournalBridge, createJournal, eventKey, digest } from './bridge.mjs';

const [pkg, root, phase, crashAt = 'none'] = process.argv.slice(2);
process.on('message', () => {});
await mkdir(root, { recursive: true });
const trace = [];
const emit = (kind, data) => { const item = { kind, ...data }; trace.push(item); process.send?.(item); };
const binding = { account: '10000001', consumer: 'consumer-a', generation: 1, revision: 1 };
let identity = binding;
const event = { account: binding.account, consumer: binding.consumer, peer: '10000002', event_id: 'event-1', position: 1,
  content: [{ type: 'text', text: 'synthetic input' }] };
// Deliberately a test double. Real Dart/FastAPI tests are a separate entry point.
const clientPath = resolve(root, 'client-double.json');
let clientFacts;
try { clientFacts = JSON.parse(await readFile(clientPath)); } catch (e) { if (e.code !== 'ENOENT') throw e; clientFacts = { operations: {}, confirmed: {}, watermarks: {}, commits: 0 }; }
async function saveClient() { const file = await open(clientPath, 'w'); await file.writeFile(JSON.stringify(clientFacts)); await file.sync(); await file.close(); }
const client = {
  identity: () => identity,
  async confirm({ binding: captured, key, position }) { assert.deepEqual(captured, identity); clientFacts.confirmed[key] = position; await saveClient(); },
  async ack({ binding: captured, key, peer, position }) {
    assert.deepEqual(captured, identity); assert.equal(clientFacts.confirmed[key], position);
    const scope = `${captured.account}/${captured.consumer}/${peer}`;
    const before = clientFacts.watermarks[scope] ?? 0;
    assert.ok(position <= before + 1, 'consumption_gap');
    clientFacts.watermarks[scope] = Math.max(before, position); await saveClient();
  },
  async query(operation_id) { emit('operation-query', { operation_id }); return clientFacts.operations[operation_id] ?? null; },
  async send(operation_id, args) {
    emit('operation-send', { operation_id });
    assert.equal(clientFacts.operations[operation_id], undefined, 'unexpected repeated send');
    clientFacts.commits++;
    const result = { operation_id, status: 'succeeded', message_id: 'synthetic-outbound-1', digest: digest(args) };
    clientFacts.operations[operation_id] = result; await saveClient(); return result;
  },
};
let bridge, runtime, journal, modelCalls = 0;
async function checkpoint(edge) {
  if (!['crash', 'recover-crash'].includes(phase) || edge !== crashAt) return;
  await bridge.flush();
  emit('checkpoint', { edge, row: journal.get('events', eventKey(event)), facts: bridge.agent.session.snapshotEvents() });
  await new Promise(() => {});
}
async function* provider(options) {
  modelCalls++;
  await checkpoint('provider-entered');
  if (phase === 'provider-error') throw new Error('synthetic provider uncertainty');
  const tool = ['sent-before-receipt', 'operation-intent'].includes(crashAt) && modelCalls === 1;
  if (tool) {
    yield { type: 'block-start', index: 0, blockType: 'tool-call' };
    yield { type: 'block-end', index: 0, block: { type: 'tool-call', id: 'provider-call-1', name: 'probe_send', arguments: '{}' } };
  }
  // No text blocks on the ordinary path: a successful silent turn.
  yield { type: 'finish', reason: { kind: tool ? 'tool-calls' : 'stop' } };
}
runtime = await boot(pkg, root, provider, (kind, data) => emit(kind, data));
journal = await createJournal(runtime);
const agent = await runtime.open('journal-session', phase.startsWith('recover'));
bridge = new JournalBridge(runtime.ctx, agent, journal, binding, client, checkpoint);
await bridge.mount();
const unregister = runtime.ctx.tools.register({ name: 'probe_send', description: 'Synthetic operation planning witness',
  parameters: { type: 'object', properties: {} }, output: { schema: { type: 'object', additionalProperties: true }, render: (_, value) => [{ type: 'text', text: JSON.stringify(value) }] },
  async execute(_, exec) {
    const source = agent.session.snapshotEvents().findLast(e => e.type === 'assistant/message' && e.data.message.content.some(b => b.type === 'tool-call' && b.id === exec.callId));
    assert.ok(source, 'tool must have a durable assistant plan origin');
    await bridge.flush();
    const ordinal = source.data.message.content.findIndex(b => b.type === 'tool-call' && b.id === exec.callId);
    const logicalKey = `${eventKey(event)}/${agent.session.id}/${source.seq}/${ordinal}`;
    return bridge.operation(logicalKey, { target_account: event.peer, content: [{ type: 'text', text: 'synthetic outbound' }] });
  } });
try {
  if (phase.startsWith('recover')) {
    await Promise.all(Array.from({ length: 12 }, () => bridge.reconcile(event)));
    // Reconcile persisted logical plans, never ask the model to recreate intent.
    for (const [key, plan] of journal.domain.table('operations').entries()) {
      const result = await bridge.operation(plan.key, plan.args);
      assert.equal(result.operation_id, plan.operation_id);
      await assert.rejects(bridge.operation(plan.key, { different: true }), /different payload/);
    }
  } else {
    await Promise.all(Array.from({ length: 12 }, () => bridge.accept(event)));
  }
  await bridge.drain();
  if (phase.endsWith('crash')) throw new Error(`checkpoint not reached: ${crashAt}`);
  const row = journal.get('events', eventKey(event));
  const uncertain = phase === 'provider-error' || ['dispatch-intent', 'provider-entered', 'presented', 'sent-before-receipt', 'operation-intent'].includes(crashAt);
  assert.equal(row.state, uncertain ? 'uncertain' : 'completed');
  assert.equal(modelCalls, phase === 'recover' && uncertain || phase === 'recover' && ['turn-flushed', 'client-confirmed', 'client-acked'].includes(crashAt) ? 0 : 1);
  const facts = agent.session.snapshotEvents();
  const pending = [...agent.inbox.nextTurn, ...agent.inbox.nextStep];
  assert.equal(pending.length, 0);
  const projections = facts.filter(e => e.type === 'user/message' && row.attempts.some(a => a.id === e.data.id));
  assert.equal(projections.length, 1, 'retired attempts must never be model-projected');
  const watermark = clientFacts.watermarks[`${binding.account}/${binding.consumer}/${event.peer}`] ?? 0;
  assert.equal(watermark, uncertain ? 0 : 1);
  if (crashAt === 'sent-before-receipt') {
    assert.equal(clientFacts.commits, 1);
    assert.equal(trace.filter(e => e.kind === 'operation-send').length, 0);
  }
  if (crashAt === 'operation-intent') assert.equal(clientFacts.commits, 0);
  // No repeated provider or consumption on later replay, even after idle.
  await bridge.accept(event); await bridge.drain();
  await assert.rejects(bridge.accept({ ...event, content: [{ type: 'text', text: 'conflict' }] }), /different content/);
  identity = { ...binding, generation: 2 };
  await assert.rejects(bridge.accept(event), /stale/);
  identity = binding;
  const result = { phase, crashAt, modelCalls, row, pending: pending.length,
    insertions: facts.filter(e => e.type === 'agent/inbox/spliced').flatMap(e => e.data.inserted).map(m => m.id),
    projections: projections.map(e => e.data.id), watermark, clientFacts,
    operations: [...journal.domain.table('operations').entries()], trace, facts };
  await writeFile(resolve(root, `${phase}.json`), JSON.stringify(result, null, 2) + '\n');
  emit('result', { phase, crashAt, state: row.state, attempts: row.attempts.length, modelCalls, projections: projections.length, watermark, commits: clientFacts.commits });
} finally {
  unregister(); await bridge.close();
  await assert.rejects(bridge.accept(event), /disposed/);
  await journal.close(); await runtime.close(); process.disconnect?.();
}
