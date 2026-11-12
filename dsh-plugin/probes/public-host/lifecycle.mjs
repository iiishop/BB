import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { mkdir, writeFile } from 'node:fs/promises';

const [packageRoot, evidenceRoot] = process.argv.slice(2);
const root = resolve(evidenceRoot);
assert.equal(process.env.DSH_HOME, resolve(root, 'home'), 'Run through run.mjs for isolation');
const require = createRequire(resolve(packageRoot, 'package.json'));
const load = name => import(pathToFileURL(require.resolve(`@deepseek-ai/${name}`)));
const app = await load('dsh-app-boot');
const profileDir = resolve(root, 'profile');
const anchor = resolve(packageRoot, 'package.json');
await mkdir(root, { recursive: true });
app.initProfile(profileDir, []);
// Workspace-owned boot composition; profile files are written only by host services.
const configPath = resolve(root, 'host.yml');
await writeFile(configPath, JSON.stringify(['llm', 'session', 'session-projection', 'system-prompt', 'tools', 'config-editor', 'settings', 'plugin-manager']
  .map(name => ({ id: name, name: `@deepseek-ai/dsh-${name}` }))));
const results = [];
let ctx;
async function boot() {
  const profile = app.loadProfileDirectory('bb-probe', profileDir, anchor);
  assert.equal(profile.skippedBundles.length, 0);
  const context = { name: 'bb-public-probe', dir: profileDir, patchPath: profile.patchPath,
    installAnchor: anchor, cwd: root, home: resolve(root, 'home'),
    startedBundles: profile.layers.map(layer => layer.packageName), overlays: [],
    telemetryDisabledEnv: '1' };
  const witness = { mounts: 0, disposals: 0, updates: 0 };
  const resolution = await app.createRuntimeResolution({ installAnchor: anchor, profile, home: context.home });
  ctx = await app.boot('bb-probe', configPath, app.readProfilePatches('bb-probe', context, profile), async host => {
    host.provide('profileContext', context);
    host.provide('probeWitness', witness);
    await host.plugin(app.PluginPackages, { resolution });
  }, pathToFileURL(resolve(profileDir, 'package.json')).href);
  assert.ok(ctx.pluginManager && ctx.settings && ctx.tools);
  return witness;
}
function countTool() { return ctx.tools.schemas().filter(tool => tool.name === 'bb_probe_state').length; }
async function close(witness) {
  await ctx.fiber.dispose();
  assert.equal(witness.disposals, witness.mounts, 'every fixture effect must unwind');
  assert.equal(witness.read, undefined);
  ctx = undefined;
}
try {
  let witness = await boot();
  assert.equal(countTool(), 0);
  const bundlePath = fileURLToPath(new URL('./bundle', import.meta.url));
  const installed = await ctx.pluginManager.installBundle(bundlePath);
  assert.equal(installed.application, 'restart-required', JSON.stringify(installed));
  results.push({ case: 'install', application: installed.application });
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 1);
  assert.equal(witness.read(), 'initial');
  const form = ctx.settings.describe().find(form => form.ns === 'bb-public-host-probe');
  assert.ok(form);
  await ctx.settings.update(form.ns, { label: 'saved-synthetic' }, form.revision);
  assert.equal(witness.read(), 'saved-synthetic');
  assert.equal(witness.mounts, 1, 'volatile edit must not remount');
  await assert.rejects(ctx.settings.update(form.ns, { label: 'stale' }, form.revision), /changed|revision|conflict/i);
  results.push({ case: 'settings', value: witness.read(), mounts: witness.mounts, updates: witness.updates });
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 1);
  assert.equal(witness.read(), 'saved-synthetic');
  const plugins = await ctx.pluginManager.listPlugins();
  const entry = plugins.find(row => row.moduleName === '@bb-probe/public-host');
  assert.ok(entry, JSON.stringify(plugins));
  const disabled = await ctx.pluginManager.setPluginEnabled(entry.entryId, false);
  assert.equal(disabled.application, 'restart-required');
  results.push({ case: 'restore-and-disable', value: witness.read(), application: disabled.application });
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 0);
  assert.equal(witness.mounts, 0);
  const enabled = await ctx.pluginManager.setPluginEnabled(entry.entryId, true);
  assert.equal(enabled.application, 'restart-required');
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 1);
  assert.equal(witness.read(), 'saved-synthetic');
  const runningRemoval = await ctx.pluginManager.removeBundle('@bb-probe/public-host');
  assert.equal(runningRemoval.application, 'failed');
  assert.equal(runningRemoval.error.code, 'stop-profile');
  const deselected = await ctx.pluginManager.setBundleEnabled('@bb-probe/public-host', false);
  assert.equal(deselected.application, 'restart-required');
  results.push({ case: 'reenable-and-remove-running', tool_count: countTool(), error: runningRemoval.error.code });
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 0);
  const removed = await ctx.pluginManager.removeBundle('@bb-probe/public-host');
  assert.equal(removed.application, 'restart-required', JSON.stringify(removed));
  results.push({ case: 'remove-stopped-bundle', application: removed.application });
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 0);
  assert.equal(witness.mounts, 0);
  assert.ok(!(await ctx.pluginManager.listBundles()).some(row => row.name === '@bb-probe/public-host'));
  await close(witness);
  results.push({ case: 'uninstalled-restart', tool_count: 0 });
  await writeFile(resolve(root, 'lifecycle.json'), JSON.stringify({ results,
    limitations: ['No HMR: mutations correctly require restart', 'Settings service exercised; browser UI NOT RUN',
      'Disposable fixture has no display metadata or background connections; real bridge lifecycle NOT RUN'] }, null, 2) + '\n');
  console.log(JSON.stringify({ lifecycle: 'PASS', results }));
} finally {
  if (ctx) await ctx.fiber.dispose();
}
