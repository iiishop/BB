import assert from 'node:assert/strict';
import { open } from 'node:fs/promises';
import { resolve } from 'node:path';
import { boot } from '../probes/native/profile.mjs';

const [packageRoot, root, phase, sessionId] = process.argv.slice(2);
process.on('message', () => {});
const trace = [];
const emit = (kind, data) => { const item = { kind, ...data }; trace.push(item); process.send?.(item); };
let runtime;
const key = { account: '10000001', session_id: sessionId, event_id: 'event-1' };
const content = [{ type: 'text', text: 'synthetic event-1' }];
async function witness(name, data) {
  const file = await open(resolve(root, `${sessionId}-${name}.json`), 'wx');
  await file.writeFile(JSON.stringify(data) + '\n');
  await file.sync();
  await file.close();
}
async function stop(label, agent) {
  if (agent) await runtime.ctx.sessions.flush(agent.session);
  emit('checkpoint', { label, facts: agent?.session.snapshotEvents() });
  await new Promise(() => {});
}
runtime = await boot(packageRoot, resolve(root, 'sessions'), (kind, data) => emit(kind, data), async options => {
  if (phase === 'provider-entered') {
    await witness('provider', { message_ids: options.messages.map(message => message.id), provider_entered: true });
    await stop('provider-entered');
  }
});
const crashHooks = {
  'after-accept-before-receipt': 'accepted-before-receipt',
  'after-claim-before-model': 'claimed-before-model',
  'recover-interrupted': 'recovered-before-wake',
  'intent-before-provider': 'dispatch-intent-before-call',
};
runtime.ctx.on('bb-recovery/checkpoint', async ({ agent, phase: edge }) => {
  if (edge === crashHooks[phase]) await stop(edge, agent);
});
const isResume = phase.startsWith('recover') || phase === 'completed-replay' || phase === 'legacy';
const agent = await runtime.open(sessionId, isResume);
const before = agent.session.snapshotEvents();
const send12 = () => Promise.all(Array.from({ length: 12 }, () => agent.bbDeliver(key, content)));
const finish = async () => {
  await agent.whenIdle();
  await runtime.ctx.sessions.flush(agent.session);
};
if (phase === 'before-accept') {
  await stop(phase, agent);
} else if (phase === 'after-receipt-before-turn') {
  await agent.runMaintenance(async () => {
    const receipt = await agent.bbDeliver(key, content);
    await witness('receipt', receipt);
    await stop(phase, agent);
  });
} else if (phase in crashHooks && !isResume || phase === 'provider-entered') {
  await agent.bbDeliver(key, content);
  await finish();
  throw new Error('Crash edge was not reached');
} else if (phase === 'recover-interrupted') {
  throw new Error('Resume checkpoint was not reached');
} else {
  const receipts = await send12();
  await finish();
  const state = agent.bbDeliveryStatus(key);
  const uncertain = phase === 'recover-uncertain';
  assert.equal(state.state, 'completed');
  assert.equal(state.consumed_through, null);
  const snapshot = agent.session.snapshotEvents();
  const owned = snapshot.filter(event => event.type === 'plugin:bb/delivery-v1');
  const acceptances = owned.filter(event => event.data.op === 'accepted');
  assert.equal(acceptances.length, 1);
  const logicalIds = new Set(owned.map(event => event.data.logical_turn_id).filter(Boolean));
  assert.equal(logicalIds.size, 1, 'recovery must preserve one logical turn');
  const projected = snapshot.filter(event => event.type === 'user/message' && event.data.id === state.logical_turn_id);
  assert.equal(projected.length, 1);
  const expectedCalls = phase === 'completed-replay' ? 0 : 1;
  assert.equal(trace.filter(item => item.kind === 'model.request').length, expectedCalls);
  // Live completed/uncertain replays never add a physical turn, acceptance or model call.
  await send12();
  await finish();
  assert.deepEqual(agent.session.snapshotEvents(), snapshot);
  await assert.rejects(agent.bbDeliver({ ...key, session_id: 'wrong' }, content), /session binding mismatch/);
  await assert.rejects(agent.bbDeliver({ ...key, account: '10000002' }, content), /account binding mismatch/);
  await assert.rejects(agent.bbDeliver(key, [{ type: 'text', text: 'conflict' }]), /different content/);
  if (phase === 'legacy') assert.deepEqual(snapshot.slice(0, before.length), before);
  if (phase === 'isolation') {
    const other = await runtime.open('account-b-session');
    const otherKey = { account: '10000002', session_id: 'account-b-session', event_id: key.event_id };
    await Promise.all(Array.from({ length: 12 }, () => other.bbDeliver(otherKey, content)));
    await other.whenIdle();
    await runtime.ctx.sessions.flush(other.session);
    assert.equal(other.bbDeliveryStatus(otherKey).state, 'completed');
    assert.notEqual(other.bbDeliveryStatus(otherKey).logical_turn_id, state.logical_turn_id);
    const sameAccount = await runtime.open('account-a-new-session');
    const nextKey = { ...key, session_id: 'account-a-new-session' };
    await sameAccount.bbDeliver(nextKey, content);
    await sameAccount.whenIdle();
    await runtime.ctx.sessions.flush(sameAccount.session);
    assert.notEqual(sameAccount.bbDeliveryStatus(nextKey).logical_turn_id, state.logical_turn_id);
    assert.equal(trace.filter(item => item.kind === 'model.request').length, 3);
  }
  const handle = await runtime.ctx.sessionPersistence.open(sessionId, 'read');
  const durable = await handle.read();
  await handle.close();
  assert.ok(!trace.some(item => item.kind === 'agent.error'), 'native driver failed');
  emit('result', { phase, state, versions: runtime.versions,
    provider_calls: trace.filter(item => item.kind === 'model.request').length,
    physical_turn_starts: snapshot.filter(event => event.type === 'turn/start').length,
    inbox_insertions: snapshot.filter(event => event.type === 'agent/inbox/spliced'
      && event.data.inserted.some(message => message.id === state.logical_turn_id)).length,
    logical_turns: logicalIds.size, acceptances: acceptances.length,
    receipt_count: receipts.length, durable_events: durable.events,
  });
}
await runtime.close();
process.disconnect?.();
