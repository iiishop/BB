// Independent plugin process, one shared client authority; no capability logging.
import { readFile } from 'node:fs/promises';
import { access } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { setTimeout } from 'node:timers/promises';
const [path, label] = process.argv.slice(2), c = JSON.parse(await readFile(path));
console.log(JSON.stringify({ ready: true }));
const deadline = Date.now() + 15000;
for (;;) {
  try { await access(join(dirname(path), 'owner-go')); break; } catch {}
  if (Date.now() > deadline) throw new Error('release barrier deadline');
  await setTimeout(10);
}
{
  const r = await fetch(c.origin + '/v2/consumers/bind', { method: 'POST', headers: {
    'Content-Type': 'application/json', 'X-BB-Consumer-Key': c.owner_key },
    body: JSON.stringify({ expected_auth: c.auth, consumer_id: c.identity.consumer_id,
      expected_binding_revision: c.identity.binding_revision, session_id: label }), signal: AbortSignal.timeout(10000) });
  const v = await r.json();
  console.log(JSON.stringify({ status: r.status, code: v.error?.code, identity: v.identity }));
}
