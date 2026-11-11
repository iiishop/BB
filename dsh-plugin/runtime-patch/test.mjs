// Reproducible foreground tests of original failure and patched native recovery.
import assert from 'node:assert/strict';
import { fork, execFileSync, spawnSync } from 'node:child_process';
import { mkdir, writeFile, mkdtemp, readFile, cp } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const plugin = resolve(here, '..');
const [original, patched] = process.argv.slice(2).map(value => resolve(value));
assert.ok(original && patched, 'Usage: node test.mjs <original runtime> <patched runtime>');
await mkdir(resolve(plugin, '.evidence'), { recursive: true });
const root = await mkdtemp(resolve(plugin, '.evidence/recovery-'));
console.log(JSON.stringify({ evidence_directory: root }));
const verification = spawnSync('uv', ['run', '--no-project', 'python', resolve(here, 'install.py'),
  '--verify', '--destination', patched], { encoding: 'utf8', timeout: 60000 });
await writeFile(resolve(root, 'runtime-verification.json'), JSON.stringify(verification, null, 2));
assert.equal(verification.status, 0, verification.stderr);
const baseline = spawnSync(process.execPath, [resolve(plugin, 'probes/native/run.mjs'), original, resolve(root, 'baseline')],
  { encoding: 'utf8', timeout: 60000, maxBuffer: 10 * 1024 * 1024 });
await writeFile(resolve(root, 'baseline-command.json'), JSON.stringify(baseline, null, 2));
assert.equal(baseline.status, 0, baseline.stderr);
console.log('Original negative regression reproduced (exit 0, recovery gate FAIL).');
await cp(resolve(here, 'lock.json'), resolve(root, 'lock.json'));
const runs = [];
async function run(phase, sessionId, crash = false, runtimePath = patched, legacy = false) {
  const trace = [];
  let stdout = '', stderr = '';
  const worker = legacy ? resolve(plugin, 'probes/native/worker.mjs') : resolve(here, 'worker.mjs');
  const args = legacy ? [runtimePath, resolve(root, 'sessions'), phase, sessionId] : [runtimePath, root, phase, sessionId];
  const child = fork(worker, args, { cwd: root, silent: true, env: { PATH: process.env.PATH, LANG: 'C.UTF-8' } });
  const kill = () => {
    const daemon = JSON.parse(execFileSync(process.env.MULTICA_CLI_PATH,
      ['daemon', 'status', '--output', 'json'], { encoding: 'utf8', timeout: 10000 }));
    assert.notEqual(child.pid, daemon.pid);
    child.kill('SIGKILL');
  };
  let timedOut = false;
  const deadline = setTimeout(() => { timedOut = true; kill(); }, 20000);
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.on('message', message => {
    trace.push(message);
    if (crash && message.kind === 'checkpoint') kill();
  });
  const result = await new Promise((done, fail) => {
    child.on('error', fail);
    child.on('close', (code, signal) => done({ code, signal }));
  });
  clearTimeout(deadline);
  const entry = { phase, session_id: sessionId, ...result, stdout, stderr, trace };
  runs.push(entry);
  const label = `${String(runs.length).padStart(2, '0')}-${phase}-${sessionId}`;
  await writeFile(resolve(root, `${label}.json`), JSON.stringify(entry, null, 2) + '\n');
  assert.equal(timedOut, false, stderr);
  assert.equal(result.code, crash ? null : 0, stderr);
  assert.equal(result.signal, crash ? 'SIGKILL' : null);
  if (crash) {
    assert.equal(trace.filter(item => item.kind === 'checkpoint').length, 1);
    await cp(resolve(root, 'sessions'), resolve(root, 'crash-prefixes', label), { recursive: true });
  }
  console.log(JSON.stringify({ phase, session_id: sessionId, ...result }));
  return trace.find(item => item.kind === 'result');
}

const results = [];
results.push(await run('control', 'control'));
results.push(await run('completed-replay', 'control'));
for (const phase of ['before-accept', 'after-accept-before-receipt', 'after-receipt-before-turn', 'after-claim-before-model']) {
  await run(phase, phase, true);
  results.push(await run('recover', phase));
  results.push(await run('completed-replay', phase));
}
await run('after-claim-before-model', 'double-crash', true);
await run('recover-interrupted', 'double-crash', true);
results.push(await run('recover', 'double-crash'));
results.push(await run('completed-replay', 'double-crash'));
for (const phase of ['intent-before-provider', 'provider-entered']) {
  await run(phase, phase, true);
  results.push(await run('recover-uncertain', phase));
}
results.push(await run('isolation', 'account-a-session'));
await run('control', 'legacy', false, original, true);
results.push(await run('legacy', 'legacy'));

// Two independent observations bracket the external boundary; native recovery cannot distinguish them.
const uncertain = results.filter(item => item.phase === 'recover-uncertain');
assert.equal(uncertain.length, 2);
assert.ok(uncertain.every(item => item.state.state === 'completed' && item.provider_calls === 1));
const providerWitness = JSON.parse(await readFile(resolve(root, 'provider-entered-provider.json'), 'utf8'));
assert.equal(providerWitness.provider_entered, true);
let absentWitness = false;
try { await readFile(resolve(root, 'intent-before-provider-provider.json')); }
catch (error) { assert.equal(error.code, 'ENOENT'); absentWitness = true; }
assert.ok(absentWitness);
const summary = {
  patch: 'bb-recovery-2', baseline: 'Original failure assertions preserved and reproduced',
  bounded_recovery_tests: 'PASS', overall_delivery_gate: 'Bounded R2 reasoning matrix PASS; business and client integration require separate evidence',
  model: 'DETERMINISTIC TEST DOUBLE; real model/vision NOT RUN',
  processes: runs.length, forced_sigkills: runs.filter(item => item.signal === 'SIGKILL').length,
  results: results.map(({ phase, state, provider_calls, physical_turn_starts, inbox_insertions, logical_turns, acceptances }) =>
    ({ phase, state, provider_calls, physical_turn_starts, inbox_insertions, logical_turns, acceptances })),
};
await writeFile(resolve(root, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({ evidence_directory: root, ...summary }, null, 2));
