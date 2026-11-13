import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { boot } from '../native/profile.mjs';

const [packageRoot, root] = process.argv.slice(2);
const trace = [];
const requests = [];
let release, entered;
const started = new Promise(done => { entered = done; });
const gate = new Promise(done => { release = done; });
const runtime = await boot(packageRoot, resolve(root, 'boundary-sessions'),
  (kind, data) => trace.push({ kind, ...data }), async options => {
    requests.push(structuredClone(options.messages));
    if (requests.length === 1) { entered(); await gate; }
    if (options.messages.some(message => message.id === 'failure')) throw new Error('synthetic provider failure');
  });
const message = id => ({ id, role: 'user', source: { kind: 'user' },
  content: [{ type: 'text', text: `synthetic ${id}` }] });
try {
  const agent = await runtime.open('boundary-probe');
  for (const name of ['bbConfigure', 'bbDeliver', 'bbRecoverDeliveries', 'bbDeliveryStatus', 'bbEventCursor', 'bbAdvanceCursor']) {
    assert.equal(typeof agent[name], 'undefined', `${name} must be absent in stock host`);
  }
  agent.followup(message('first'));
  await started;
  assert.equal(agent.status, 'running');
  agent.followup(message('second'));
  agent.followup(message('third'));
  assert.throws(() => agent.followup(message('second')), /already pending/);
  release();
  await agent.whenIdle();
  assert.equal(await runtime.ctx.sessions.flush(agent.session), true);
  assert.equal(requests.length, 3);
  assert.deepEqual(requests.map(messages => messages.filter(m => m.role === 'user').at(-1).id), ['first', 'second', 'third']);
  const facts = agent.session.snapshotEvents();
  assert.equal(facts.filter(event => event.type === 'turn/end').length, 3);
  assert.equal(facts.filter(event => event.type === 'user/message').length, 3);
  assert.ok(!trace.some(event => event.kind === 'agent.error'));

  const failed = await runtime.open('failure-probe');
  failed.followup(message('failure'));
  await failed.whenIdle();
  assert.equal(await runtime.ctx.sessions.flush(failed.session), true);
  assert.equal(trace.filter(event => event.kind === 'agent.error').length, 1);
  const failedFacts = failed.session.snapshotEvents();
  const end = failedFacts.find(event => event.type === 'turn/end');
  assert.ok(end);
  assert.equal(end.data.reason.kind, 'error');
  assert.equal(failedFacts.filter(event => event.type === 'assistant/message').length, 0);
  const result = { busy: { calls: 3, turns: 3, order: ['first', 'second', 'third'], pending_duplicate_rejected: true },
    failure: { model_calls: 1, turn_end: end.data, assistant_messages: 0, consumed_through: null },
    trace, requests, scope: 'Real stock driver, deterministic provider. BB wait matching, real model/image and internal ACK NOT RUN.' };
  await writeFile(resolve(root, 'boundaries.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify({ boundaries: 'PASS', busy: result.busy, failure: result.failure }));
} finally { release(); await runtime.close(); }
