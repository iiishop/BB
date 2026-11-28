import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { setImmediate as settle } from 'node:timers/promises';
import test from 'node:test';
import { Client, ClientFailure } from '../../bundle/client.js';

// Supply only the two DSH host packages; exercise the shipped apply/refresh loop.
const peers = new Map([
  ['@deepseek-ai/dsh-mcp-client', 'export {};'],
  ['@deepseek-ai/schemastery', 'const z = new Proxy({}, {get: () => () => z}); export default z;'],
]);
const hooks = registerHooks({ resolve(name, context, next) {
  return peers.has(name)
    ? { shortCircuit: true, url: `data:text/javascript,${encodeURIComponent(peers.get(name))}` }
    : next(name, context);
} });
const { apply } = await import('../../bundle/index.js');
hooks.deregister();

test('repeated unbound 401s retry bind without recycling the login MCP', async (t) => {
  const values = { enabled: true, clientUrl: 'http://127.0.0.1:1', targetSession: 'test', peerAccount: '', pollMs: 60000 };
  const config = Object.fromEntries(Object.keys(values).map(k => [k, { get: () => values[k] }]));
  const agent = { session: { id: 'test' } };
  const listeners = {}, starts = [], disposals = [];
  const bind = t.mock.method(Client.prototype, 'bind', () => { throw new ClientFailure('unauthenticated', 401); });
  let teardown, status;
  await apply({
    profileContext: { dir: '.' }, agents: { get: () => agent }, inject() {},
    on(event, fn) { listeners[event] = fn; },
    effect(fn) { const cleanup = fn(); if (cleanup) teardown = cleanup; },
    tools: { register(tool) { status = tool.execute; } }, systemPrompt: { section() {} },
    plugin(_, { env }) { starts.push(env); return { dispose: () => { disposals.push(env); } }; },
  }, config);
  t.after(() => teardown());
  async function refresh() { listeners['loader/volatile-update'](); await settle(); }
  await refresh(); await refresh();
  assert.equal(bind.mock.callCount(), 3);
  assert.equal((await status()).state, 'login_required');
  assert.deepEqual(starts, [{ BB_CLIENT_BASE_URL: values.clientUrl }]);
  assert.deepEqual(disposals, []);
  const run = name => listeners['tools/pre-execute']({ name, agent }, () => 'allow');
  for (const name of ['login_account', 'register_account']) assert.equal(await run(`mcp__bb__${name}`), 'allow');
  assert.equal((await run('mcp__bb__send_message')).kind, 'deny');
  values.clientUrl = 'http://127.0.0.1:2';
  await refresh();
  assert.deepEqual(disposals, [starts[0]]);
  assert.deepEqual(starts[1], { BB_CLIENT_BASE_URL: values.clientUrl });
  values.enabled = false;
  await refresh();
  assert.deepEqual(disposals, starts);
  assert.equal(starts.length, 2);
});
