// Synthetic authorized plan, real stock storage/Session and real v2 client HTTP.
// The private config contains a consumer capability; never log or attach it.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { boot } from './host.mjs';

const [pkg, root, configPath, phase] = process.argv.slice(2);
const config = JSON.parse(await readFile(configPath));
const origin = new URL(config.origin);
assert.equal(origin.protocol, 'http:'); assert.equal(origin.hostname, '127.0.0.1');
const calls = [];
async function post(path, body) {
  calls.push({ path, operation_id: body.operation_id });
  const response = await fetch(new URL(path, origin), { method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-BB-Consumer-Key': config.owner_key },
    body: JSON.stringify({ ...body, expected_identity: config.identity }),
    redirect: 'error', signal: AbortSignal.timeout(10000) });
  assert.equal(response.status, 200, `v2 ${path} failed (${response.status})`);
  const value = await response.json();
  assert.deepEqual(value.identity, config.identity);
  return value.result;
}
const runtime = await boot(pkg, root, async function* () { throw new Error('No model dispatch during synthetic plan recovery'); }, () => {});
const { z, ctx, domainModule } = runtime;
const schema = z.object({ account: z.string(), consumer_id: z.string(), operation_id: z.string(),
  args: z.object({ target_account: z.string(), content: z.array(z.object({ type: z.literal('text'), text: z.string() }).strict()) }).strict(),
  status: z.enum(['prepared', 'succeeded']) }).strict();
const domain = await ctx.storageDomain.open(domainModule.defineDomain({ name: 'bb_v2_operation_probe', version: 1,
  tables: { plans: domainModule.domainTable(schema) } }));
await runtime.open(`v2-operation-${phase}`);
try {
  const plans = domain.table('plans');
  let plan = plans.get('authorized-plan');
  if (phase === 'crash') {
    assert.equal(plan, undefined);
    plan = { account: config.identity.account, consumer_id: config.identity.consumer_id,
      operation_id: `bb-${randomUUID()}`, args: { target_account: config.peer,
        content: [{ type: 'text', text: 'synthetic v2 stable operation' }] }, status: 'prepared' };
    await plans.put('authorized-plan', schema.parse(plan));
    await post('/v2/chat/send_message', { ...plan.args, operation_id: plan.operation_id });
    await writeFile(resolve(root, 'before-crash.json'), JSON.stringify({ calls, operation_id: plan.operation_id, status: plan.status }, null, 2));
    console.log(JSON.stringify({ checkpoint: 'sent-before-receipt' }));
    const keepAlive = setInterval(() => {}, 1000);
    try { await new Promise(() => {}); } finally { clearInterval(keepAlive); }
  } else {
    assert.equal(phase, 'recover'); assert.ok(plan, 'plan must survive process death');
    assert.equal(plan.account, config.identity.account); assert.equal(plan.consumer_id, config.identity.consumer_id);
    // A fresh generation/binding authorizes query of this original account/consumer's plan.
    const result = await post('/v2/operations/get', { operation_id: plan.operation_id });
    assert.equal(result.operation_id, plan.operation_id); assert.equal(result.status, 'succeeded');
    await plans.put('authorized-plan', schema.parse({ ...plan, status: 'succeeded' }));
    assert.equal(calls.filter(c => c.path === '/v2/chat/send_message').length, 0);
    const evidence = { operation_id: plan.operation_id, sends_after_restart: 0, model_requests: 0,
      position: result.message.position, calls, different_host_session: true };
    await writeFile(resolve(root, 'recovered.json'), JSON.stringify(evidence, null, 2) + '\n');
    console.log(JSON.stringify(evidence));
  }
} finally { await domain.close(); await runtime.close(); }
