import assert from 'node:assert/strict';
import { fork, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile, cp, readdir } from 'node:fs/promises';
import { resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const [pkgArg, outArg] = process.argv.slice(2);
assert.ok(pkgArg && outArg && process.env.MULTICA_CLI_PATH, 'Usage: node run.mjs <stock DSH package> <evidence parent> (Multica task)');
const pkg = resolve(pkgArg), parent = resolve(outArg), here = fileURLToPath(new URL('.', import.meta.url));
await mkdir(parent, { recursive: true });
const root = await mkdtemp(resolve(parent, 'dea467-journal-'));
const sha = value => createHash('sha256').update(value).digest('hex');
const files = ['dsh-agent-loop/lib/index.js', 'dsh-agent/lib/types/runtime-types.d.ts', 'dsh-llm/lib/index.js', 'dsh-tools/lib/index.js',
  'dsh-session/lib/index.js', 'dsh-session-persistence-jsonl/lib/index.js', 'dsh-storage-domain/lib/index.js', 'dsh-storage-json/lib/index.js'];
const sources = {};
for (const name of files) sources[name] = sha(await readFile(resolve(pkg, 'node_modules/@deepseek-ai', name)));
assert.equal(sources[files[0]], 'cf57e3ecd487ac5c2553455aaa5cef2c6fb41e6bd61be5aa455675d1d7193033');
const sourceCode = {};
for (const name of await readdir(here)) if (/\.(mjs|py)$/.test(name)) sourceCode[name] = sha(await readFile(resolve(here, name)));
await writeFile(resolve(root, 'sources.json'), JSON.stringify({ node: process.version, sources, probe: sourceCode }, null, 2) + '\n');
const commands = [];
async function run(name, phase, edge = 'none', crash = false) {
  const dir = resolve(root, name); await mkdir(dir, { recursive: true });
  const child = fork(resolve(here, 'worker.mjs'), [pkg, dir, phase, edge], {
    cwd: root, silent: true, env: { PATH: process.env.PATH, LANG: 'C.UTF-8', DSH_HOME: resolve(dir, 'home') },
  });
  let stdout = '', stderr = '', expired = false; const trace = [];
  function kill() {
    const daemon = JSON.parse(execFileSync(process.env.MULTICA_CLI_PATH, ['daemon', 'status', '--output', 'json'], { encoding: 'utf8', timeout: 10000 }));
    assert.ok(Number.isInteger(daemon.pid)); assert.notEqual(daemon.pid, child.pid); child.kill('SIGKILL');
  }
  const deadline = setTimeout(() => { expired = true; kill(); }, 20000);
  child.stdout.on('data', value => { stdout += value; }); child.stderr.on('data', value => { stderr += value; });
  child.on('message', item => { trace.push(item); if (crash && item.kind === 'checkpoint') kill(); });
  let status;
  try { status = await new Promise((done, reject) => { child.on('error', reject); child.on('close', (code, signal) => done({ code, signal })); }); }
  finally { clearTimeout(deadline); }
  const record = { name, phase, edge, ...status, expired, stdout, stderr, trace };
  commands.push({ name, phase, edge, ...status });
  await writeFile(resolve(dir, `${phase}-${edge}-trace.json`), JSON.stringify(record, null, 2) + '\n');
  await writeFile(resolve(root, 'commands.json'), JSON.stringify(commands, null, 2) + '\n');
  assert.equal(expired, false, stderr); assert.equal(status.code, crash ? null : 0, stderr);
  assert.equal(status.signal, crash ? 'SIGKILL' : null);
  if (crash) {
    assert.equal(trace.filter(item => item.kind === 'checkpoint').length, 1);
    await cp(resolve(dir, 'sessions'), resolve(dir, `crash-prefix-${phase}-${edge}`), { recursive: true });
  }
  console.log(JSON.stringify({ name, phase, ...status, result: trace.find(item => item.kind === 'result') }));
}
await run('silent-control', 'control');
await run('provider-error', 'provider-error');
for (const edge of ['journal-received', 'attempt-prepared', 'accepted', 'claimed', 'dispatch-intent', 'provider-entered', 'presented',
  'turn-flushed', 'client-confirmed', 'client-acked', 'operation-intent', 'sent-before-receipt']) {
  await run(edge, 'crash', edge, true);
  await run(edge, 'recover', edge);
}
await run('recovery-interrupted', 'crash', 'accepted', true);
await run('recovery-interrupted', 'recover-crash', 'pending-removed', true);
await run('recovery-interrupted', 'recover', 'pending-removed');
for (const name of files) assert.equal(sha(await readFile(resolve(pkg, 'node_modules/@deepseek-ai', name))), sources[name]);
const summary = { scope: 'public inbox retirement + BB metadata journal + deterministic provider + client TEST DOUBLE',
  assertions: 'PASS', external_sources_unchanged: true, workers: commands.length, crashes: commands.filter(c => c.signal === 'SIGKILL').length,
  NOT_PROVEN: ['real client multi-consumer/identity contract', 'wait/event competition', 'session rebuild', 'in-flight downloads', 'production plugin/real model'],
  product_gate: 'NOT COMPLETE; do not infer six-criterion acceptance from this component matrix' };
await writeFile(resolve(root, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({ evidence: relative(process.cwd(), root), ...summary }, null, 2));
