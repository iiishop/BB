// Real CLIENT API boundary; no credentials or server API access in this worker.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { boot } from './host.mjs';
import { JournalBridge, createJournal } from './bridge.mjs';

const [pkg, root, configPath, phase] = process.argv.slice(2);
const config = JSON.parse(await readFile(configPath));
const origin = new URL(config.origin);
assert.equal(origin.protocol, 'http:'); assert.equal(origin.hostname, '127.0.0.1');
const calls = [];
async function post(path, body) {
  calls.push({ path, operation_id: body.operation_id });
  const response = await fetch(new URL(path, origin), { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body), redirect: 'error', signal: AbortSignal.timeout(10000) });
  return { status: response.status, body: await response.json() };
}
const runtime = await boot(pkg, root, async function* () { throw new Error('No model call permitted during operation reconciliation'); }, () => {});
const journal = await createJournal(runtime);
// New Session for the second process, same stable consumer and persisted logical plan.
const agent = await runtime.open(`operation-${phase}`);
const binding = { account: config.account, consumer: 'stable-operation-consumer', generation: 1, revision: 1 };
const client = { identity: () => binding,
  async query(operation_id) { const value = await post('/operations/get', { operation_id });
    if (value.status === 404) return null; assert.equal(value.status, 200); return value.body; },
  async send(operation_id, args) { const value = await post('/chat/send_message', { ...args, operation_id });
    assert.equal(value.status, 200); return { operation_id, status: 'succeeded', message: value.body }; },
};
const bridge = new JournalBridge(runtime.ctx, agent, journal, binding, client, async edge => {
  if (phase !== 'crash' || edge !== 'sent-before-receipt') return;
  await writeFile(resolve(root, 'live-before-crash.json'), JSON.stringify({ calls, plans: [...journal.domain.table('operations').entries()] }, null, 2));
  console.log(JSON.stringify({ checkpoint: edge }));
  const keepAlive = setInterval(() => {}, 1000);
  try { await new Promise(() => {}); } finally { clearInterval(keepAlive); }
});
await bridge.mount();
try {
  const plans = [...journal.domain.table('operations').entries()];
  const key = phase === 'crash' ? 'synthetic-authorized-plan-1' : plans[0][1].key;
  const args = phase === 'crash' ? { target_account: config.peer, content: [{ type: 'text', text: 'synthetic stable operation' }] } : plans[0][1].args;
  const result = await bridge.operation(key, args);
  assert.equal(phase, 'recover', 'crash checkpoint must fire');
  assert.equal(result.status, 'succeeded');
  assert.equal(calls.filter(call => call.path === '/chat/send_message').length, 0);
  assert.equal(result.operation_id, plans[0][1].operation_id);
  await writeFile(resolve(root, 'live-operation.json'), JSON.stringify({ result: { operation_id: result.operation_id, status: result.status, message_id: result.message.id }, calls,
    model_requests: 0, different_host_session: true, real_client: true }, null, 2) + '\n');
  console.log(JSON.stringify({ result: 'PASS', operation_id: result.operation_id, sends_after_restart: 0 }));
} finally { await bridge.close(); await journal.close(); await runtime.close(); }
