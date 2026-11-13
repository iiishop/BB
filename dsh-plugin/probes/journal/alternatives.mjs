import assert from 'node:assert/strict';
import { writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { boot } from '../native/profile.mjs';

const [pkg, root] = process.argv.slice(2);
await mkdir(root, { recursive: true });
const requests = [];
const runtime = await boot(pkg, resolve(root, 'sessions'), () => {}, async request => { requests.push({ session: request.sessionId, ids: request.messages.filter(m => m.role === 'user').map(m => m.id) }); });
const message = id => ({ id, role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text: 'same synthetic business event' }] });
try {
  const replace = await runtime.open('replace-candidate');
  replace.send(message('old'), 'next-turn', false);
  assert.equal(replace.inbox.replace('old', message('new')), true);
  assert.throws(() => replace.followup(message('new')), /already pending/);
  await replace.whenIdle();
  assert.equal(requests.length, 0);
  assert.equal(replace.inbox.nextTurn.length, 1);

  const steer = await runtime.open('steer-candidate');
  steer.send(message('old'), 'next-turn', false);
  steer.steer(message('new'));
  await steer.whenIdle();
  assert.deepEqual(requests[0].ids, ['new', 'old']);

  const cancel = await runtime.open('idle-cancel-candidate');
  cancel.send(message('old'), 'next-turn', false);
  cancel.send(message('unrelated'), 'next-turn', false);
  cancel.cancel({ kind: 'user' });
  assert.equal(cancel.inbox.nextTurn.length, 0, 'bulk cancel removes unrelated pending input too');
  cancel.followup(message('new'));
  await cancel.whenIdle();
  assert.equal(requests.filter(r => r.session === 'idle-cancel-candidate').length, 1);
  const result = { replace_then_followup: 'pending duplicate rejected; no wake', steer_without_retirement: 'two copies in one model request',
    idle_cancel_then_followup: 'bulk cancellation also discards unrelated pending input', requests,
    selected: 'public per-ID inbox.remove + Session flush + persistent attempt + followup under runMaintenance' };
  await writeFile(resolve(root, 'alternatives.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result));
} finally { await runtime.close(); }
