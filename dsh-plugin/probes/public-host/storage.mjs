import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { writeFile } from 'node:fs/promises';

const [packageRoot, root, phase] = process.argv.slice(2);
assert.ok(['write', 'read'].includes(phase));
const require = createRequire(resolve(packageRoot, 'package.json'));
const load = name => import(pathToFileURL(require.resolve(`@deepseek-ai/${name}`)));
const { Context } = await load('cordis');
const ctx = new Context();
const domainModule = await load('dsh-storage-domain');
const domainRequire = createRequire(require.resolve('@deepseek-ai/dsh-storage-domain'));
const { z } = await import(pathToFileURL(domainRequire.resolve('zod')));
const spec = domainModule.defineDomain({ name: 'bb_probe_bindings', version: 1,
  tables: { consumers: domainModule.domainTable(z.object({ account: z.string(), generation: z.number().int(), received: z.number().int() })) } });
const value = { account: '10000001', generation: 2, received: 7 };
try {
  for (const [name, config] of [['dsh-storage', {}], ['dsh-storage-json', { root: resolve(root, 'domain-data') }],
    ['dsh-storage-domain', { backend: 'json' }]]) {
    const mod = await load(name);
    await ctx.plugin(mod.default ?? mod, config);
  }
  const domain = await ctx.storageDomain.open(spec);
  const table = domain.table('consumers');
  if (phase === 'write') {
    await table.put('stable-consumer', value);
  }
  assert.deepEqual(table.get('stable-consumer'), value);
  assert.equal(table.get('bad'), undefined);
  await domain.close();
  const badSpec = domainModule.defineDomain({ ...spec, name: 'bb_probe_invalid' });
  if (phase === 'write') {
    const invalid = await ctx.storageDomain.open(badSpec);
    // Negative control: this release validates at OPEN, but put() accepts an invalid record.
    await invalid.table('consumers').put('bad', { ...value, generation: 'invalid' });
    assert.equal(invalid.table('consumers').get('bad').generation, 'invalid');
    await invalid.close();
  } else {
    await assert.rejects(ctx.storageDomain.open(badSpec), error => error.code === 'invalid-record');
  }
  await writeFile(resolve(root, `storage-${phase}.json`), JSON.stringify({ phase, state: value,
    result: 'PASS_WITH_GAP', invalid_record: phase === 'write' ? 'put accepted invalid schema' : 'cold open rejected invalid-record',
    scope: 'Public domain persistence, separate-process reopen. No atomic transaction with Session/BB client proven.' }, null, 2) + '\n');
  console.log(JSON.stringify({ storage: phase, result: 'PASS_WITH_GAP' }));
} finally { await ctx.fiber.dispose(); }
