// Native arbitration and mixed pending recovery against the real v2 client.
import assert from 'node:assert/strict';
import { readFile, writeFile, access } from 'node:fs/promises';
import { setTimeout } from 'node:timers/promises';
import { resolve } from 'node:path';
import { boot } from './host.mjs';
import { JournalBridge, createJournal, eventKey, digest } from './bridge.mjs';
const [pkg, root, configPath, mode] = process.argv.slice(2);
const c = JSON.parse(await readFile(configPath)), calls = [], native = [], requests = [];
async function post(path, body) {
  const r = await fetch(c.origin + '/v2/' + path, { method: 'POST', headers: {
    'Content-Type': 'application/json', 'X-BB-Consumer-Key': c.owner_key },
    body: JSON.stringify({ ...body, expected_identity: c.identity }), signal: AbortSignal.timeout(35000) });
  calls.push({ path, status: r.status, position: body.through_position });
  assert.equal(r.status, 200, path); const v = await r.json(); assert.deepEqual(v.identity, c.identity); return v.result;
}
const page = await post('chat/read_messages', { account: c.peer, after_position: 0, limit: 100 });
let bridge, release, entered, lastMessages;
const keepAlive = mode === 'mixed-prepare' ? setInterval(() => {}, 1000) : undefined;
const started = new Promise(done => { entered = done; }), held = new Promise(done => { release = done; });
const runtime = await boot(pkg, root, async function* (request) {
  lastMessages = request.messages;
  requests.push(request.messages.map(m => ({ id: m.id, role: m.role })));
  if (mode === 'busy' && requests.length === 1) { entered(); await held; }
  if (mode === 'wait' && requests.length === 1) {
    yield { type: 'block-start', index: 0, blockType: 'tool-call' };
    yield { type: 'block-end', index: 0, block: { type: 'tool-call', id: 'native-wait', name: 'probe_wait', arguments: '{}' } };
    yield { type: 'finish', reason: { kind: 'tool-calls' } }; return;
  }
  yield { type: 'finish', reason: { kind: 'stop' } };
}, (kind, data) => native.push({ kind, ...data }));
const journal = await createJournal(runtime), agent = await runtime.open('shared-session', mode === 'mixed-recover');
const binding = { account: c.identity.account, consumer: c.identity.consumer_id, generation: 1, revision: 1 };
const events = page.items.map(item => ({ account: binding.account, consumer: binding.consumer, peer: c.peer,
  event_id: `incoming-${item.message.position}`, position: item.message.position, content: item.blocks }));
const receipt = new Map(page.items.map(x => [x.message.position, x.presentation.receipt_id]));
const commits = [];
const client = { identity: () => binding,
  async confirm({ position, attempt, digest }) { await post('chat/confirm_presentation', {
    receipt_ids: [receipt.get(position)], attempt_id: attempt, request_digest: digest }); },
  async ack({ position }) { await post('chat/ack_messages', { account: c.peer, through_position: position }); commits.push(position); },
};
const foreign = id => ({ id, role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text: 'unrelated synthetic input' }] });
let unregister = () => {};
try {
  if (mode === 'wait') {
    await post('events/subscribe', { peer_account: c.peer });
    const cursor = (await post('events/read', { after_cursor: 0 })).next_cursor;
    const seen = Math.max(0, ...events.map(e => e.position));
    let claims = 0, wakes = 0, waitItems, waitTurn, passive, claimKey, claimedPosition;
    const claim = async (position, source) => {
      // One plugin's serialized reservation, durably journaled before either wake.
      const key = digest([binding.account, binding.consumer, position]);
      if (journal.get('events', key)) return false;
      // Reserve synchronously before awaiting disk; callbacks share this fact.
      if (claims) { assert.equal(position, claimedPosition, 'different input needs its own claim'); return false; }
      claims++; claimKey = key; claimedPosition = position;
      await journal.put('events', key, { binding, event_id: `wait-${position}`, peer: c.peer,
        position, digest: digest(position), state: 'active', attempts: [] });
      native.push({ kind: 'notification-claim', source, position }); return true;
    };
    runtime.ctx.on('agent/pre-step', (p, next) => { if (p.agent === agent) waitTurn = p.turn; return next(); });
    unregister = runtime.ctx.tools.register({ name: 'probe_wait', description: 'Wait on real BB client with shared passive claim',
      parameters: { type: 'object', properties: {} }, output: { schema: { type: 'object', additionalProperties: true },
        render: (_, v) => v.items.flatMap(x => x.blocks) },
      async execute() {
        const waiting = post('chat/wait_messages', { account: c.peer, seen_position: seen, timeout: 30 });
        passive = post('events/wait', { after_cursor: cursor, timeout: 30 }).then(async value => {
          const positions = value.items.map(x => x.event.position).filter(x => x > seen);
          assert.ok(positions.length); await claim(Math.min(...positions), 'passive');
          // A native wait is active: passive delivery uses that same wake slot.
          return positions;
        });
        console.log(JSON.stringify({ checkpoint: 'native-wait-active' }));
        const value = await waiting; waitItems = value.items;
        assert.equal(waitItems.length, 1); await claim(waitItems[0].message.position, 'wait'); wakes++;
        await passive; return value;
      } });
    agent.followup(foreign('wait-command')); await agent.whenIdle();
    assert.equal(claims, 1); assert.equal(wakes, 1); assert.equal(requests.length, 2);
    const facts = agent.session.snapshotEvents();
    assert.ok(facts.some(e => e.type === 'turn/end' && e.data.turn === waitTurn && e.data.reason.kind === 'completed'));
    const toolResult = facts.find(e => e.type === 'tool/result');
    assert.ok(toolResult, 'native tool result must exist before display confirmation');
    assert.equal(toolResult.data.message.isError, false);
    const presented = lastMessages.find(m => m.id === toolResult.data.message.id);
    assert.ok(presented, 'tool result must reach the next actual provider request');
    assert.deepEqual(presented.content, waitItems.flatMap(x => x.blocks));
    assert.equal(await runtime.ctx.sessions.flush(agent.session), true);
    const before = (await post('chat/consumption', { account: c.peer })).consumed_through;
    // Only new event was displayed: earlier history remains unconsumed unless empty.
    assert.equal(seen, 0, 'wait case requires its own fresh peer history'); assert.equal(before, 0);
    await post('chat/confirm_presentation', { receipt_ids: waitItems.map(x => x.presentation.receipt_id),
      attempt_id: 'native-wait-attempt', request_digest: digest(lastMessages) });
    await post('chat/ack_messages', { account: c.peer, through_position: waitItems[0].message.position });
    commits.push(waitItems[0].message.position);
    assert.equal((await post('chat/consumption', { account: c.peer })).consumed_through, waitItems[0].message.position);
    const settled = journal.get('events', claimKey); settled.state = 'completed';
    await journal.put('events', claimKey, settled);
    assert.equal(claimedPosition, waitItems[0].message.position);
    native.push({ kind: 'wait-proof', claims, wakes, before, position: waitItems[0].message.position,
      request_digest: digest(lastMessages), tool_result_seq: toolResult.seq });
  } else {
    bridge = new JournalBridge(runtime.ctx, agent, journal, binding, client, async edge => {
      if (mode === 'mixed-prepare' && edge === 'accepted') {
        console.log(JSON.stringify({ checkpoint: 'mixed-pending-durable', pending: agent.inbox.nextTurn.map(x => x.id) }));
        await new Promise(() => {});
      }
    });
    await bridge.mount();
    if (mode === 'mixed-prepare') {
      agent.send(foreign('foreign-before'), 'next-turn', false);
      await bridge.accept(events[0]); throw new Error('must crash at checkpoint');
    } else if (mode === 'mixed-recover') {
      await Promise.all(Array.from({ length: 12 }, () => bridge.reconcile(events[0])));
      await bridge.drain();
      agent.followup(foreign('foreign-after')); await bridge.drain();
      const row = journal.get('events', eventKey(events[0]));
      const ids = agent.session.snapshotEvents().filter(e => e.type === 'user/message').map(e => e.data.id);
      assert.equal(row.attempts.length, 2); assert.equal(row.attempts[0].state, 'retired');
      assert.deepEqual(ids.sort(), ['foreign-before', 'foreign-after', row.attempts[1].id].sort());
      assert.equal(requests.length, 3); assert.deepEqual(commits, [events[0].position]);
      assert.equal(agent.inbox.nextTurn.length, 0);
    } else if (mode === 'busy') {
      assert.equal(events.length, 1);
      await bridge.accept(events[0]); await started;
      console.log(JSON.stringify({ checkpoint: 'busy-provider-held' }));
      const deadline = Date.now() + 20000;
      for (;;) {
        try { await access(resolve(root, 'arrived')); break; } catch {}
        assert.ok(Date.now() < deadline, 'new messages barrier deadline'); await setTimeout(10);
      }
      const later = await post('chat/read_messages', { account: c.peer, after_position: events[0].position, limit: 100 });
      assert.equal(later.items.length, 2);
      for (const item of later.items) {
        receipt.set(item.message.position, item.presentation.receipt_id);
        events.push({ account: binding.account, consumer: binding.consumer, peer: c.peer,
          event_id: `incoming-${item.message.position}`, position: item.message.position, content: item.blocks });
      }
      await Promise.all(events.slice(1).flatMap(e => Array.from({ length: 12 }, () => bridge.accept(e))));
      assert.equal((await post('chat/consumption', { account: c.peer })).consumed_through, 0);
      assert.equal(agent.inbox.nextTurn.length, 2); release(); await bridge.drain();
      assert.deepEqual(commits, events.map(e => e.position)); assert.equal(requests.length, 3);
      await Promise.all(events.map(e => bridge.accept(e))); await bridge.drain(); assert.equal(requests.length, 3);
    } else throw new Error('unknown mode');
  }
  assert.equal([...journal.domain.table('operations').entries()].length, 0);
  const result = { mode, outbound_operations: 0, provider: 'deterministic double', client: 'real Dart/FastAPI', requests, commits,
    native, calls, watermark: (await post('chat/consumption', { account: c.peer })).consumed_through };
  await writeFile(resolve(root, mode + '.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify({ mode, provider_calls: requests.length, commits, watermark: result.watermark }));
} finally { clearInterval(keepAlive); release(); unregister(); if (bridge) await bridge.close(); await journal.close(); await runtime.close(); }
