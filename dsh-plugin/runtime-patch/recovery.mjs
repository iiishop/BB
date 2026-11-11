// Experimental, version-locked native recovery hooks. No independent driver.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { appendPluginRecord, pluginRecordOf } from '@deepseek-ai/dsh-session';

const RECORD = 'plugin:bb/delivery-v1';
const serial = Symbol('bb-admission-serialization');
const VERSION = 'bb-recovery-1';
const PREFIX = 'bb-event-';
const record = (agent, data) => appendPluginRecord(agent.session, RECORD, { version: VERSION, ...data });
export const checkpoint = (agent, phase) => agent.ctx.parallel('bb-recovery/checkpoint', { agent, phase });
async function flush(agent) {
  assert.ok(agent.ctx.get('sessionPersistence'), 'BB requires persistent sessions');
  assert.equal(await agent.ctx.sessions.flush(agent.session), true);
}
function exclusive(agent, action) {
  const next = (agent[serial] ?? Promise.resolve()).then(action);
  agent[serial] = next.catch(() => {});
  return next;
}
function identity(agent, key) {
  assert.deepEqual(Object.keys(key).sort(), ['account', 'event_id', 'session_id']);
  assert.match(key.account, /^\d{8}$/);
  assert.equal(key.session_id, agent.session.id, 'session binding mismatch');
  assert.ok(typeof key.event_id === 'string' && key.event_id.length > 0 && key.event_id.length <= 200);
  return PREFIX + createHash('sha256').update(JSON.stringify([key.account, key.session_id, key.event_id])).digest('hex');
}
export function states(agent) {
  const events = agent.session.snapshotEvents();
  const items = new Map();
  const claims = new Map();
  for (const event of events) {
    const entry = pluginRecordOf(event);
    if (!entry?.type.startsWith('plugin:bb/')) continue;
    assert.equal(entry.type, RECORD, 'unsupported BB record');
    const data = entry.data;
    assert.equal(data.version, VERSION, 'unsupported BB recovery version');
    assert.ok(['accepted', 'claimed', 'recovered', 'dispatch'].includes(data.op), 'unknown BB operation');
    if (data.op === 'accepted') {
      const id = identity(agent, data.key);
      assert.equal(id, data.message.id);
      assert.equal(data.logical_turn_id, id);
      assert.equal(data.message.role, 'user');
      assert.ok(!items.has(id), 'duplicate acceptance record');
      items.set(id, { ...data, accepted_seq: event.seq, claims: [], dispatches: [], completed: false });
    } else {
      const item = items.get(data.id);
      assert.ok(item, 'BB record without acceptance');
      assert.equal(data.logical_turn_id, data.id);
      if (data.op === 'claimed') {
        assert.ok(Number.isSafeInteger(data.turn) && data.turn > 0);
        item.claims.push(data);
        const ids = claims.get(data.turn) ?? new Set();
        ids.add(data.id);
        claims.set(data.turn, ids);
      }
      if (data.op === 'dispatch') item.dispatches.push(data);
    }
  }
  // Refuse adoption of owned identities whose guard records were lost or stripped.
  for (const event of events) {
    const messages = event.type === 'agent/inbox/spliced' ? event.data.inserted
      : event.type === 'user/message' ? [event.data] : [];
    for (const message of messages) {
      if (message.id.startsWith(PREFIX)) assert.ok(items.has(message.id), 'BB_STATE_LOST');
    }
  }
  const completedTurns = new Set(events.filter(event => event.type === 'turn/end'
    && event.data.reason?.kind === 'completed').map(event => event.data.turn));
  const pending = new Set([...agent.inbox.nextTurn, ...agent.inbox.nextStep].map(message => message.id));
  for (const item of items.values()) {
    item.completed = item.dispatches.length > 0 && item.dispatches.every(dispatch => completedTurns.has(dispatch.turn));
    item.pending = pending.has(item.message.id);
    item.state = item.completed ? 'completed'
      : item.dispatches.length ? 'dispatch_uncertain'
        : item.pending ? 'accepted_pending' : 'accepted_recoverable';
  }
  return items;
}
export function status(agent, key) {
  const item = states(agent).get(identity(agent, key));
  return item ? { state: item.state, logical_turn_id: item.logical_turn_id,
    accepted_seq: item.accepted_seq, claims: item.claims, dispatches: item.dispatches,
    consumed_through: null } : { state: 'absent', consumed_through: null };
}
function blocked(items) {
  return [...items.values()].filter(item => item.state === 'dispatch_uncertain').map(item => item.logical_turn_id);
}

export function deliver(agent, key, content) {
  // Snapshot caller inputs before admission yields to another operation.
  key = structuredClone(key);
  content = structuredClone(content);
  return exclusive(agent, async () => {
    const id = identity(agent, key);
    const items = states(agent);
    for (const item of items.values()) assert.equal(item.key.account, key.account, 'account binding mismatch');
    const message = { id, role: 'user', source: { kind: 'user' }, content };
    const prior = items.get(id);
    if (prior) assert.deepEqual(prior.message, message, 'same event key with different content');
    if (blocked(items).length) return { ...status(agent, key), blocked: blocked(items) };
    if (!prior) {
      // The native log is the sole authority. A durable acceptance without an inbox
      // insertion is recoverable from its retained content; no external receipt table.
      record(agent, { op: 'accepted', key, logical_turn_id: id, message });
      agent.send(message, 'next-turn', false);
      await flush(agent);
      await checkpoint(agent, 'accepted-before-receipt');
    }
    await recoverUnlocked(agent);
    return { ...status(agent, key), disposition: prior ? 'existing' : 'new' };
  });
}

async function recoverUnlocked(agent) {
  const items = states(agent);
  const uncertain = blocked(items);
  if (uncertain.length) return { blocked: uncertain };
  // A live driver may own a claim. Recovery must never reinsert it mid-turn.
  if (agent.status === 'running') return { blocked: [] };
  for (const item of items.values()) {
    if (item.completed || item.pending) continue;
    record(agent, { op: 'recovered', id: item.message.id,
      logical_turn_id: item.logical_turn_id, previous_claims: item.claims });
    agent.send(item.message, 'next-turn', false);
  }
  await flush(agent);
  if ([...items.values()].some(item => !item.completed)) {
    await checkpoint(agent, 'recovered-before-wake');
    if (agent.inbox.hasPending) agent.wakeDriver(); // Native implementation, inside the patched loop.
  }
  return { blocked: [] };
}
export const recover = agent => exclusive(agent, () => recoverUnlocked(agent));

export async function claimed(agent, messages, position) {
  const items = states(agent);
  let owned = false;
  for (const message of messages) {
    const item = items.get(message.id);
    if (!item) continue;
    assert.equal(item.dispatches.length, 0, 'BB uncertain delivery cannot be claimed again');
    record(agent, { op: 'claimed', id: message.id, logical_turn_id: item.logical_turn_id, ...position });
    owned = true;
  }
  if (owned) {
    await flush(agent);
    await checkpoint(agent, 'claimed-before-model');
  }
}
export function shouldAppend(agent, message) {
  if (!states(agent).has(message.id)) return true;
  const prior = agent.session.snapshotEvents().find(event => event.type === 'user/message' && event.data.id === message.id);
  if (prior) assert.deepEqual(prior.data, message, 'BB projected content changed');
  return !prior;
}
export async function beforeModel(agent, turn, step) {
  const items = [...states(agent).values()].filter(item => item.claims.some(claim => claim.turn === turn));
  for (const item of items) {
    assert.ok(!item.dispatches.some(dispatch => dispatch.turn === turn && dispatch.step === step),
      'BB_DISPATCH_UNCERTAIN: no automatic provider retry');
    record(agent, { op: 'dispatch', id: item.message.id, logical_turn_id: item.logical_turn_id, turn, step });
  }
  if (items.length) {
    // MUST precede preparedCall.stream(), including synchronous provider side effects.
    await flush(agent);
    await checkpoint(agent, 'dispatch-intent-before-call');
  }
}
export async function afterTurn(agent) {
  if (!states(agent).size) return;
  await flush(agent);
  await checkpoint(agent, 'turn-finished');
}
