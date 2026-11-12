import assert from 'node:assert/strict';
import { open } from 'node:fs/promises';
import { resolve } from 'node:path';
import { boot } from './profile.mjs';
import { AdmissionProbe } from './adapter.mjs';

const [packageRoot, storageRoot, phase, sessionId] = process.argv.slice(2);
// Keep the owned IPC channel referenced while awaiting the parent's forced crash.
process.on('message', () => {});
const event = { account: '10000001', session_id: sessionId, event_id: 'event-1', type: 'message.available', payload: 'synthetic hello' };
const trace = [];
const emit = (kind, data) => {
  const record = { kind, ...data };
  trace.push(record);
  process.send?.(record);
};
const runtime = await boot(packageRoot, storageRoot, (kind, data) => emit(kind, data));
const resume = phase.startsWith('recover-');
const agent = await runtime.open(sessionId, resume);
const adapter = new AdmissionProbe(runtime.ctx, agent, event.account);
const checkpoint = async (label, data = {}) => {
  await runtime.ctx.sessions.flush(agent.session);
  emit('checkpoint', { label, ...data, facts: agent.session.snapshotEvents() });
  // The parent SIGKILLs this exact worker here. This is not graceful disposal.
  await new Promise(() => {});
};

if (phase === 'before-accept') {
  await checkpoint(phase, { state: adapter.inspect(event) });
} else if (phase === 'after-accept-before-receipt') {
  // A real wake is requested, held by the documented maintenance boundary.
  // The adapter caller never receives/persists an acceptance receipt here.
  await agent.runMaintenance(async () => {
    agent.followup(adapter.message(event));
    await checkpoint(phase, { state: adapter.inspect(event) });
  });
} else if (phase === 'after-receipt-before-turn') {
  await agent.runMaintenance(async () => {
    const receipt = await adapter.accept(event, { wake: true });
    // A caller-side receipt witness, never consulted by the dedup/recovery adapter.
    const file = await open(resolve(storageRoot, '..', `${sessionId}.receipt.json`), 'wx');
    await file.writeFile(JSON.stringify(receipt) + '\n');
    await file.sync();
    await file.close();
    emit('receipt', { receipt });
    await checkpoint(phase, { state: adapter.inspect(event) });
  });
} else if (phase === 'after-claim-before-model') {
  runtime.ctx.on('agent/request', async ({ agent: current }, next) => {
    if (current !== agent) return next();
    await checkpoint(phase, { state: adapter.inspect(event) });
    return next();
  });
  agent.followup(adapter.message(event));
  await agent.whenIdle();
  throw new Error('Expected the checkpoint to block before any model request');
} else if (resume) {
  const before = adapter.inspect(event);
  const receipts = await Promise.all(Array.from({ length: 12 }, () =>
    new AdmissionProbe(runtime.ctx, agent, event.account).accept(event, { wake: true })));
  await agent.whenIdle();
  await runtime.ctx.sessions.flush(agent.session);
  const result = adapter.inspect(event);
  assert.equal(result.insertions, 1, 'adapter must not enqueue an accepted event again');
  assert.equal(receipts.filter(item => item.disposition === 'new').length, before.state === 'absent' ? 1 : 0);
  assert.equal(result.history_projected, before.state === 'absent');
  assert.equal(result.consumed_through, null);
  await assert.rejects(adapter.accept({ ...event, account: '10000002' }), /account binding mismatch/);
  await assert.rejects(adapter.accept({ ...event, session_id: 'other-session' }), /session binding mismatch/);
  await assert.rejects(adapter.accept({ ...event, payload: 'conflicting content' }), /different payload/);
  let duplicateWakeRejected = false;
  if (result.pending) {
    assert.throws(() => agent.followup(adapter.message(event)), /already pending/);
    duplicateWakeRejected = true;
  }
  const stored = await runtime.ctx.sessionPersistence.open(sessionId, 'read');
  const durable = await stored.read();
  await stored.close();
  emit('result', {
    phase, versions: runtime.versions, before, after: result,
    model_requests: trace.filter(item => item.kind === 'model.request').length,
    duplicate_wake_rejected: duplicateWakeRejected,
    status: agent.status, durable_events: durable.events,
  });
} else if (phase === 'control') {
  // Prove the model double and real driver can complete turns in this composition.
  agent.followup(adapter.message(event));
  await agent.whenIdle();
  await runtime.ctx.sessions.flush(agent.session);
  assert.equal(adapter.inspect(event).history_projected, true);
  // Stock ID uniqueness is only pending-list uniqueness, not lifetime idempotency.
  agent.followup(adapter.message(event));
  await agent.whenIdle();
  await runtime.ctx.sessions.flush(agent.session);
  assert.equal(adapter.inspect(event).insertions, 2);
  assert.equal(trace.filter(item => item.kind === 'model.request').length, 2);
  emit('result', { phase, versions: runtime.versions, state: adapter.inspect(event),
    model_requests: 2, facts: agent.session.snapshotEvents() });
} else {
  throw new Error(`Unknown phase: ${phase}`);
}
await runtime.close();
process.disconnect?.();
