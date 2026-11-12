// Run every worker in the foreground, with no account/profile/provider environment.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile, readdir } from 'node:fs/promises';
import { resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const [packageArg, outputArg] = process.argv.slice(2);
assert.ok(packageArg && outputArg, 'Usage: node run.mjs <DSH package root> <evidence parent>');
assert.ok(process.env.MULTICA_CLI_PATH, 'Required for exact child/daemon safety checks');
const packageRoot = resolve(packageArg);
const parent = resolve(outputArg);
await mkdir(parent, { recursive: true });
const root = await mkdtemp(resolve(parent, 'dea467-public-'));
const here = fileURLToPath(new URL('.', import.meta.url));
const repo = resolve(here, '../../..');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const sources = {};
const names = ['cordis', 'cordis-plugin-loader', 'dsh-agent', 'dsh-agent-loop', 'dsh-session',
  'dsh-session-persistence', 'dsh-session-persistence-jsonl', 'dsh-app-boot', 'dsh-plugin-manager',
  'dsh-settings', 'dsh-config-editor', 'dsh-storage-domain', 'dsh-storage-json', 'dsh-llm', 'dsh-tools'];
const versions = { dsh: JSON.parse(await readFile(resolve(packageRoot, 'package.json'))).version };
for (const name of names) {
  const dir = `node_modules/@deepseek-ai/${name}`;
  const meta = JSON.parse(await readFile(resolve(packageRoot, dir, 'package.json')));
  versions[name] = meta.version;
  for (const file of ['package.json', 'lib/index.js', 'lib/types/index.d.ts']) {
    try { sources[`${dir}/${file}`] = hash(await readFile(resolve(packageRoot, dir, file))); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
const skill = 'node_modules/@deepseek-ai/dsh-agent-preset/skills/cordis-plugin-development/';
for (const file of ['SKILL.md', 'references/host-plugin.md', 'references/practices.md', 'references/verification.md']) {
  sources[skill + file] = hash(await readFile(resolve(packageRoot, skill, file)));
}
const types = {
  'dsh-agent/lib/types/runtime-types.d.ts': /send\(|followup\(|steer\(|inject\(|whenIdle\(|runMaintenance|agent\/created|agent\/inbox\/claimed/,
  'dsh-session/lib/types/index.d.ts': /flush\(|snapshotEvents\(|pendingInbox\(/,
  'dsh-session-persistence/lib/types/handle.d.ts': /flush\(|read\(/,
  'dsh-settings/lib/types/index.d.ts': /describe\(|update\(|mutate\(/,
  'dsh-plugin-manager/lib/types/index.d.ts': /installBundle\(|setPluginEnabled\(|removeBundle\(/,
  'dsh-storage-domain/lib/types/domain.d.ts': /put\(|close\(|get\(/,
};
const signatures = {};
for (const [path, pattern] of Object.entries(types)) {
  const key = `node_modules/@deepseek-ai/${path}`;
  const source = await readFile(resolve(packageRoot, key), 'utf8');
  sources[key] = hash(source);
  signatures[path] = source.split('\n').flatMap((line, index) => pattern.test(line) ? [{ line: index + 1, declaration: line.trim() }] : []);
}
const probeSources = {};
async function inventory(dir) {
  for (const file of await readdir(dir, { withFileTypes: true })) {
    const path = resolve(dir, file.name);
    if (file.isDirectory()) await inventory(path);
    else probeSources[relative(repo, path)] = hash(await readFile(path));
  }
}
await inventory(here);
await inventory(resolve(here, '../native'));
const inventoryResult = { base: '2f5a0bb57fb7845c8b26eea6c3978f5a1845b403', node: process.version,
  platform: process.platform, arch: process.arch, versions, sources, signatures, probeSources };
await writeFile(resolve(root, 'sources.json'), JSON.stringify(inventoryResult, null, 2) + '\n');
assert.equal(versions.dsh, '0.2.1-rc.5', 'Retarget explicitly for another host version');
assert.equal(sources['node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js'],
  'cf57e3ecd487ac5c2553455aaa5cef2c6fb41e6bd61be5aa455675d1d7193033', 'Requires pinned STOCK AgentLoop, never patched');
const commands = [];
async function run(script, args, limit = 30000, multica = false) {
  const env = { PATH: process.env.PATH, LANG: 'C.UTF-8', DSH_HOME: resolve(root, 'home'),
    DSH_TELEMETRY_DISABLED: '1', ...(multica ? { MULTICA_CLI_PATH: process.env.MULTICA_CLI_PATH,
      MULTICA_DAEMON_PORT: process.env.MULTICA_DAEMON_PORT } : {}) };
  const child = spawn(process.execPath, [script, ...args], { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '', timedOut = false;
  const deadline = setTimeout(() => {
    timedOut = true;
    const daemon = JSON.parse(execFileSync(process.env.MULTICA_CLI_PATH, ['daemon', 'status', '--output', 'json'], { encoding: 'utf8', timeout: 10000 }));
    assert.ok(Number.isInteger(daemon.pid));
    assert.notEqual(child.pid, daemon.pid);
    child.kill('SIGKILL');
  }, limit);
  child.stdout.on('data', data => { stdout += data; });
  child.stderr.on('data', data => { stderr += data; });
  let result;
  try {
    result = await new Promise((done, reject) => {
      child.on('error', reject);
      child.on('close', (code, signal) => done({ code, signal }));
    });
  } finally { clearTimeout(deadline); }
  const record = { script: relative(repo, script), args, ...result, timedOut, stdout, stderr };
  commands.push(record);
  await writeFile(resolve(root, 'commands.json'), JSON.stringify(commands, null, 2) + '\n');
  assert.equal(result.code, 0, stdout + stderr);
  assert.equal(timedOut, false);
  console.log(JSON.stringify({ script: record.script, code: result.code, stdout: stdout.slice(-1200) }));
}
await run(resolve(here, 'lifecycle.mjs'), [packageRoot, root], 60000);
await run(resolve(here, 'storage.mjs'), [packageRoot, root, 'write']);
await run(resolve(here, 'storage.mjs'), [packageRoot, root, 'read']);
await run(resolve(here, 'boundaries.mjs'), [packageRoot, root]);
await run(resolve(here, '../native/run.mjs'), [packageRoot, root], 60000, true);
// Verify probes have not modified any of the hashed installed package files.
for (const [path, expected] of Object.entries(sources)) assert.equal(hash(await readFile(resolve(packageRoot, path))), expected, path);
const summary = { gate: 'BLOCKED', probe_assertions: 'PASS', stock_sources_unchanged: true,
  lifecycle: 'PASS (restart lifecycle; settings service, no rendered UI)',
  storage: 'Valid state cold reopen PASS; invalid put accepted, cold reopen rejects (GAP)',
  boundaries: 'Busy FIFO and provider failure PASS, deterministic provider only',
  recovery: '4 SIGKILL checkpoints; accepted pending and claimed-unpresented input not driven on resume',
  not_run: ['real provider/vision', 'Flutter', 'BB MCP/client/server integration', 'BB wait/event matching',
    'account-switch/download integration', 'old ACK migration', 'HMR and browser settings', 'patched-host control'],
  command_count: commands.length };
await writeFile(resolve(root, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({ evidence: root, ...summary }, null, 2));
