// Foreground crash/restart matrix; saves only synthetic runtime evidence.
import assert from 'node:assert/strict';
import { fork, execFileSync } from 'node:child_process';
import { mkdir, writeFile, mkdtemp, cp, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const [packageRoot, outputParent] = process.argv.slice(2);
if (!packageRoot || !outputParent) throw new Error('Usage: node run.mjs <installed dsh package> <evidence parent>');
await mkdir(resolve(outputParent), { recursive: true });
const root = await mkdtemp(resolve(outputParent, 'native-gate-'));
const worker = fileURLToPath(new URL('./worker.mjs', import.meta.url));
const runs = [];
const currentDaemonPid = () => {
  assert.ok(process.env.MULTICA_CLI_PATH, 'Multica daemon check required before forced termination');
  return JSON.parse(execFileSync(process.env.MULTICA_CLI_PATH, ['daemon', 'status', '--output', 'json'],
    { encoding: 'utf8', timeout: 10000 })).pid;
};
async function run(phase, sessionId, crash = false) {
  const trace = [];
  let stdout = '', stderr = '';
  const child = fork(worker, [resolve(packageRoot), resolve(root, 'sessions'), phase, sessionId], {
    cwd: root, silent: true,
    // Exclude account/model credentials and personal profile configuration from workers.
    env: { PATH: process.env.PATH, LANG: 'C.UTF-8' },
  });
  const killExactChild = () => {
    assert.notEqual(child.pid, currentDaemonPid());
    child.kill('SIGKILL');
  };
  let failure;
  const deadline = setTimeout(() => {
    failure = new Error(`Worker deadline exceeded: ${phase}`);
    killExactChild();
  }, 20000);
  child.stdout.on('data', value => { stdout += value; });
  child.stderr.on('data', value => { stderr += value; });
  child.on('message', message => {
    trace.push(message);
    if (crash && message.kind === 'checkpoint') killExactChild();
  });
  const result = await new Promise((resolveRun, rejectRun) => {
    child.on('error', rejectRun);
    child.on('close', (code, signal) => resolveRun({ code, signal }));
  });
  clearTimeout(deadline);
  const record = { phase, session_id: sessionId, ...result, trace, stdout, stderr };
  runs.push(record);
  await writeFile(resolve(root, `${phase}-${sessionId}.json`), JSON.stringify(record, null, 2) + '\n');
  if (failure) throw failure;
  assert.equal(result.code, crash ? null : 0, stderr);
  assert.equal(result.signal, crash ? 'SIGKILL' : null);
  if (crash) assert.equal(trace.filter(item => item.kind === 'checkpoint').length, 1);
  // Preserve the actual on-disk crash prefix BEFORE native resume appends repair events.
  if (crash) await cp(resolve(root, 'sessions'), resolve(root, 'crash-prefixes', phase), { recursive: true });
  console.log(JSON.stringify({ phase, session_id: sessionId, ...result }));
  return trace.find(item => item.kind === 'result');
}

await writeFile(resolve(root, 'profile.json'), JSON.stringify({
  name: 'bb-dea466-native-probe', composition: 'dsh-plugin/probes/native/profile.mjs',
  storage: './sessions', compression: 'none', model: 'deterministic test double',
  personal_profiles: false, credentials: false,
}, null, 2));
const sources = {};
for (const file of ['dsh-agent-loop/lib/index.js', 'dsh-agent/lib/types/runtime-types.d.ts',
  'dsh-session/lib/index.js', 'dsh-session-persistence-jsonl/lib/index.js',
  'dsh-session-persistence/lib/types/handle.d.ts']) {
  sources[file] = createHash('sha256').update(await readFile(resolve(packageRoot, 'node_modules/@deepseek-ai', file))).digest('hex');
}
await writeFile(resolve(root, 'sources.json'), JSON.stringify({ node: process.version, sources }, null, 2));
await run('control', 'control');
const recovered = [];
for (const phase of ['before-accept', 'after-accept-before-receipt', 'after-receipt-before-turn', 'after-claim-before-model']) {
  await run(phase, phase, true);
  recovered.push(await run(`recover-${phase}`, phase));
}
const claimed = recovered.at(-1);
assert.equal(claimed.before.state, 'accepted_unpresented');
assert.equal(claimed.after.state, 'accepted_unpresented');
assert.equal(claimed.model_requests, 0);
const summary = {
  conclusion: 'BLOCKED: native admission reconciles, but accepted work is not automatically driven after restart; claimed input is no longer pending or projected',
  runtime: 'actual Cordis + DSH AgentLoop + JSONL', model: 'deterministic test double',
  process_crashes: 4, worker_runs: runs.length,
  recoveries: recovered.map(item => ({ phase: item.phase, before: item.before.state,
    after: item.after.state, insertions: item.after.insertions, model_requests: item.model_requests,
    consumed_through: item.after.consumed_through })),
  scope: 'admission/recovery gate only; scheduler wait/download/turn-end matrix NOT RUN',
};
await writeFile(resolve(root, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({ evidence_directory: root, ...summary }, null, 2));
