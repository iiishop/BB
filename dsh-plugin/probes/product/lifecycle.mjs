import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { mkdir, writeFile } from "node:fs/promises";

const [packageRoot, evidenceRoot, bundlePath] = process.argv.slice(2);
const root = resolve(evidenceRoot);
assert.equal(
  process.env.DSH_HOME,
  resolve(root, "home"),
  "Run through run.mjs for isolation",
);
const require = createRequire(resolve(packageRoot, "package.json"));
const load = (name) =>
  import(pathToFileURL(require.resolve(`@deepseek-ai/${name}`)));
const app = await load("dsh-app-boot");
const profileDir = resolve(root, "profile");
const anchor = resolve(packageRoot, "package.json");
await mkdir(root, { recursive: true });
app.initProfile(profileDir, []);
// Workspace-owned boot composition; profile files are written only by host services.
const configPath = resolve(root, "host.yml");
await writeFile(
  configPath,
  JSON.stringify(
    [
      "llm",
      "session",
      "session-projection",
      "system-prompt",
      "tools",
      "agent",
      "agent-loop",
      "attachment-local",
      "config-editor",
      "settings",
      "plugin-manager",
    ].map((name) => ({ id: name, name: `@deepseek-ai/dsh-${name}` })),
  ),
);
const results = [];
let ctx;
async function boot() {
  const profile = app.loadProfileDirectory("bb-probe", profileDir, anchor);
  assert.equal(profile.skippedBundles.length, 0);
  const context = {
    name: "bb-public-probe",
    dir: profileDir,
    patchPath: profile.patchPath,
    installAnchor: anchor,
    cwd: root,
    home: resolve(root, "home"),
    startedBundles: profile.layers.map((layer) => layer.packageName),
    overlays: [],
    telemetryDisabledEnv: "1",
  };
  const witness = { mounts: 0, disposals: 0, updates: 0 };
  const resolution = await app.createRuntimeResolution({
    installAnchor: anchor,
    profile,
    home: context.home,
  });
  ctx = await app.boot(
    "bb-probe",
    configPath,
    app.readProfilePatches("bb-probe", context, profile),
    async (host) => {
      host.provide("profileContext", context);
      host.provide("probeWitness", witness);
      await host.plugin(app.PluginPackages, { resolution });
    },
    pathToFileURL(resolve(profileDir, "package.json")).href,
  );
  assert.ok(ctx.pluginManager && ctx.settings && ctx.tools);
  return witness;
}
function countTool() {
  return ctx.tools.schemas().filter((tool) => tool.name === "bb_bridge_status")
    .length;
}
async function close(witness) {
  await ctx.fiber.dispose();

  ctx = undefined;
}
try {
  let witness = await boot();
  assert.equal(countTool(), 0);

  const installed = await ctx.pluginManager.installBundle(bundlePath);
  assert.equal(
    installed.application,
    "restart-required",
    JSON.stringify(installed),
  );
  results.push({ case: "install", application: installed.application });
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 1);
  const names = ctx.tools.schemas().map((t) => t.name);
  for (const name of [
    "register_account",
    "login_account",
    "list_conversations",
    "get_message",
    "get_context",
    "send_message",
  ])
    assert.ok(names.includes("mcp__bb__" + name), name);
  assert.ok(!names.includes("mcp__bb__ack_messages"));
  const form = ctx.settings.describe().find((f) => f.ns === "bb-bridge");
  assert.ok(form, "product settings form");
  await ctx.settings.update(
    form.ns,
    { peerAccount: "12345678", enabled: false },
    form.revision,
  );
  await new Promise((r) => setTimeout(r, 1200));
  assert.equal(
    ctx.tools.schemas().filter((t) => t.name.startsWith("mcp__bb__")).length,
    0,
    "disabling closes actual MCP registrations",
  );
  await assert.rejects(
    ctx.settings.update(form.ns, { peerAccount: "23456789" }, form.revision),
  );
  results.push({ case: "settings-disable", mcpToolsRemoved: true });
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 1);

  const status = await ctx.tools.execute({
    name: "bb_bridge_status",
    arguments: {},
    callId: "settings-restore",
    signal: new AbortController().signal,
  });
  assert.equal(status.isError, false);
  assert.equal(status.value.peerAccount, "12345678");
  assert.equal(status.value.enabled, false);
  const plugins = await ctx.pluginManager.listPlugins();
  const entry = plugins.find((row) => row.moduleName === "@bb/dsh-bridge");
  assert.ok(entry, JSON.stringify(plugins));
  const disabled = await ctx.pluginManager.setPluginEnabled(
    entry.entryId,
    false,
  );
  assert.equal(disabled.application, "restart-required");
  results.push({
    case: "restore-and-disable",
    application: disabled.application,
  });
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 0);

  const enabled = await ctx.pluginManager.setPluginEnabled(entry.entryId, true);
  assert.equal(enabled.application, "restart-required");
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 1);

  const runningRemoval = await ctx.pluginManager.removeBundle("@bb/dsh-bridge");
  assert.equal(runningRemoval.application, "failed");
  assert.equal(runningRemoval.error.code, "stop-profile");
  const deselected = await ctx.pluginManager.setBundleEnabled(
    "@bb/dsh-bridge",
    false,
  );
  assert.equal(deselected.application, "restart-required");
  results.push({
    case: "reenable-and-remove-running",
    tool_count: countTool(),
    error: runningRemoval.error.code,
  });
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 0);
  const removed = await ctx.pluginManager.removeBundle("@bb/dsh-bridge");
  assert.equal(
    removed.application,
    "restart-required",
    JSON.stringify(removed),
  );
  results.push({
    case: "remove-stopped-bundle",
    application: removed.application,
  });
  await close(witness);

  witness = await boot();
  assert.equal(countTool(), 0);

  assert.ok(
    !(await ctx.pluginManager.listBundles()).some(
      (row) => row.name === "@bb/dsh-bridge",
    ),
  );
  await close(witness);
  results.push({ case: "uninstalled-restart", tool_count: 0 });
  await writeFile(
    resolve(root, "lifecycle.json"),
    JSON.stringify(
      {
        results,
        limitations: [
          "No HMR: mutations correctly require restart",
          "Settings service exercised; browser UI NOT RUN",
          "Stock MCP subprocess loaded and disposed; model not used in lifecycle check",
        ],
      },
      null,
      2,
    ) + "\n",
  );
  console.log(JSON.stringify({ lifecycle: "PASS", results }));
} finally {
  if (ctx) await ctx.fiber.dispose();
}
