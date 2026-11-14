import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { mkdir, writeFile, readFile } from "node:fs/promises";

const [packageRoot, evidenceRoot, bundlePath, clientConfig] =
  process.argv.slice(2);
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
      "session-persistence-jsonl",
      "attachment-local",
      "config-editor",
      "settings",
      "plugin-manager",
    ].map((name) => ({
      id: name,
      name: `@deepseek-ai/dsh-${name}`,
      config:
        name === "session-persistence-jsonl"
          ? { root: resolve(root, "sessions"), compression: "none" }
          : name === "attachment-local"
            ? { dshHome: resolve(root, "home") }
            : {},
    })),
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
const client = JSON.parse(await readFile(clientConfig));
let handle, unregister;
const modelRequests = [];
const plannedQueries = [];
let lastBridgeError;
let callNumber = 0,
  lastTool;
async function tool(name, args = {}, agent = handle?.agent) {
  const r = await ctx.tools.execute({
    name,
    arguments: args,
    callId: "product-call-" + ++callNumber,
    agent,
    signal: new AbortController().signal,
  });
  lastTool = r;
  assert.equal(r.isError, false, JSON.stringify(r.content));
  assert.ok(!r.value?.isError, JSON.stringify(r.content));
  return r.value?.structuredContent ?? r.value;
}
async function explicitRead(name, args) {
  await handle.agent.whenIdle();
  plannedQueries.push({name,args});
  handle.agent.followup({id: "explicit-" + ++callNumber, role:"user", source:{kind:"user"}, content:[{type:"text",text:"Explicitly query the requested BB messages."}]});
  await handle.agent.whenIdle();
}
async function until(fn) {
  const end = Date.now() + 15000;
  while (Date.now() < end) {
    if (await fn()) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(
    "product readiness deadline: " + JSON.stringify(lastBridgeError),
  );
}
async function settings(values) {
  const form = ctx.settings.describe().find((f) => f.ns === "bb-bridge");
  await ctx.settings.update(form.ns, values, form.revision);
}
try {
  await boot();
  const installed = await ctx.pluginManager.installBundle(bundlePath);
  assert.equal(installed.application, "restart-required");
  await close();
  await boot();
  ctx.on("bb-bridge/error", (e) => {
    lastBridgeError = e;
  });
  const llm = await load("dsh-llm");
  class Model extends llm.LlmAdapter {
    async resolveModel(provider, id) {
      return {
        provider,
        id,
        name: "PRODUCT MODEL DOUBLE",
        inputModalities: ["text", "image"],
        context: { contextWindow: 8192 },
      };
    }
    async *stream(options) {
      modelRequests.push(
        options.messages.map((m) => ({
          id: m.id,
          role: m.role,
          content: m.content,
        })),
      );
      const query = plannedQueries.shift();
      if (query) {
        yield { type: "block-start", index: 0, blockType: "tool-call" };
        yield { type: "block-end", index: 0, block: { type: "tool-call", id: "explicit-query-" + modelRequests.length, name: "mcp__bb__" + query.name, arguments: JSON.stringify(query.args) } };
      }
      yield { type: "finish", reason: { kind: query ? "tool-calls" : "stop" } };
    }
  }
  unregister = ctx.llm.registerAdapter(["product-double"], new Model());
  handle = await ctx.agents.create({
    sessionId: "installed-product",
    agentOptions: { provider: "product-double", model: "fixed" },
  });
  // Exercise the installed index.js live configuration getter, not a copied
  // filter or a settings-service substitute for rendered UI evidence.
  const scopePeer = await fetch(client.api + "/auth/register", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({username: "ScopeB", password: "Abc123"}),
  }).then(async r=>{assert.equal(r.status,201);return r.json();});
  const scopeAuth = await fetch(client.api + "/auth/login", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({account:scopePeer.account, password:"Abc123"}),
  }).then(async r=>{assert.equal(r.status,200);return r.json();});
  const scopeMessage = await fetch(client.api + "/messages", {
    method: "POST", headers: {"Content-Type": "application/json", Authorization: "Bearer " + scopeAuth.token},
    body: JSON.stringify({target_account:client.account, client_nonce:crypto.randomUUID(), content:[{type:"text",text:"scope B"}]}),
  });
  assert.equal(scopeMessage.status,200);
  await settings({
    clientUrl: client.origin,
    targetSession: "installed-product",
    pollMs: 30000,
    peerAccount: client.peer,
  });
  await until(async () => {
    try {
      const r = await tool("mcp__bb__view_nickname");
      return !!r;
    } catch {
      return false;
    }
  });
  await until(async()=> (await tool("bb_bridge_status")).recovery.notifications.pending?.state === "collecting");
  await settings({peerAccount:scopePeer.account,pollMs:250});
  // An already scheduled 30s timer keeps its deadline; a public volatile
  // update after the fixed aggregation window explicitly requests a refresh.
  await new Promise(r=>setTimeout(r,1100));
  await settings({pollMs:500});
  const notices=()=>modelRequests.flat().filter(m=>m.id?.startsWith("bb-notice-"));
  await until(async()=> notices().length>0);
  const summary=JSON.parse(notices()[0].content[0].text);
  assert.deepEqual(summary.conversations.map(c=>c.peer_account),[scopePeer.account]);
  await settings({peerAccount:""});
  await tool("mcp__bb__update_nickname", { value: "Installed Profile" });
  assert.equal(
    (await tool("mcp__bb__view_nickname")).username,
    "Installed Profile",
  );
  await tool("mcp__bb__update_signature", {
    value: "native protected profile",
  });
  assert.equal(
    (await tool("mcp__bb__view_signature")).signature,
    "native protected profile",
  );
  const avatar = await tool("mcp__bb__update_avatar", {
    base64: client.images[0],
  });
  const shownAvatar = await tool("mcp__bb__view_avatar");
  assert.equal(shownAvatar.avatar_version, avatar.avatar_version);
  assert.ok(lastTool.value.content.some((block) => block.type === "image"));
  // Explicit register/login remain real MCP calls, never a direct server auth shortcut.
  const registered = await tool("mcp__bb__register_account", {
    username: "InstalledBundle",
    password: "Abc123",
  });
  assert.match(registered.account, /^[1-9][0-9]{7}$/);
  await tool("mcp__bb__login_account", {
    account: registered.account,
    password: "Abc123",
  });
  // Account switch fences the old instance; explicit setting toggle grants a new binding.
  await settings({ enabled: false });
  await until(async () =>
    ctx.tools.schemas().every((t) => !t.name.startsWith("mcp__bb__")),
  );
  await handle.dispose();
  handle = await ctx.agents.create({
    sessionId: "installed-new-account",
    agentOptions: { provider: "product-double", model: "fixed" },
  });
  await settings({ enabled: true, targetSession: "installed-new-account" });
  await until(async () =>
    ((s) =>
      s.state === "bound" &&
      s.recovery.identity.account === registered.account)(
      await tool("bb_bridge_status"),
    ),
  );
  const sent = await tool("mcp__bb__send_message", {
    target_account: client.peer,
    operation_id: "installed-explicit-send",
    content: [{ type: "text", text: "synthetic installed outgoing" }],
  });
  const id = sent.id ?? sent.message?.id;
  assert.ok(id, JSON.stringify(sent));
  const got = await tool("mcp__bb__get_message", { message_id: id });
  assert.equal(got.item.message.id, id);
  const context = await tool("mcp__bb__get_context", {
    message_id: id,
    before_limit: 1,
    after_limit: 1,
  });
  assert.ok(context.items.some((i) => i.message.id === id));
  await tool("mcp__bb__read_messages", {
    account: client.peer,
    after_position: 0,
    limit: 10,
  });
  await explicitRead("get_message", {message_id: id});
  await until(async () =>
    (await tool("bb_bridge_status")).recovery.items.some(
      (r) => r.messageId === id && r.state === "completed",
    ),
  );
  assert.ok(modelRequests.length > 0);
  const ops = (await tool("bb_bridge_status")).recovery.operations;
  assert.equal(ops[0].operation_id, "installed-explicit-send");
  assert.equal(ops[0].state, "succeeded");
  const page = await tool("mcp__bb__read_messages", {
    account: client.peer,
    after_position: 0,
    limit: 10,
  });
  assert.equal(page.items.length, 1, "silent final response must not send");
  assert.ok(ctx.get("attachments"), "attachment service visible");
  const info = await ctx.llm.resolveModelInfo("product-double", "fixed");
  assert.ok(info.inputModalities.includes("image"));
  await ctx.attachments.saveImages([
    { data: Buffer.from(client.images[0], "base64"), mediaType: "image/png" },
  ]);
  const mixed = await tool("mcp__bb__send_message", {
    target_account: client.peer,
    content: [
      { type: "text", text: "text-A" },
      {
        type: "image",
        source: {
          base64: client.images[0],
          filename: "red.png",
          mime_type: "image/png",
        },
      },
      { type: "text", text: "text-B" },
      {
        type: "image",
        source: {
          base64: client.images[1],
          filename: "blue.png",
          mime_type: "image/png",
        },
      },
    ],
  });
  assert.match(
    mixed.operation_id,
    /^bb-[a-f0-9]{64}$/,
    "bridge generated and returned operation ID",
  );
  const media = await tool("mcp__bb__get_message", { message_id: mixed.id });
  assert.deepEqual(
    media.item.message.content.map((b) => b.type),
    ["text", "image", "text", "image"],
  );
  assert.deepEqual(
    lastTool.value.content.map((b) => b.type),
    ["text", "text", "image", "text", "image"],
    "actual MCP order",
  );
  await explicitRead("get_message", {message_id: mixed.id});
  await until(async () =>
    (await tool("bb_bridge_status")).recovery.items.some(
      (r) => r.messageId === mixed.id && r.state === "completed",
    ),
  );
  const presented = modelRequests
    .flat()
    .find(
      (m) =>
        m.content.some((b) => b.type === "text" && b.text.includes(mixed.id)) &&
        m.content.filter((b) => b.type === "image").length === 2,
    );
  assert.ok(
    presented,
    "two actual native attachment blocks reached the provider",
  );
  assert.deepEqual(
    presented.content.map((b) => b.type),
    ["text", "image", "text", "image"],
  );
  assert.ok(presented.content[0].text.includes("text-A") && presented.content[0].text.includes(mixed.id));
  assert.ok(presented.content[2].text.includes("text-B"));
  assert.notDeepEqual(
    presented.content[1].attachment,
    presented.content[3].attachment,
  );
  for (const block of presented.content.filter((b) => b.type === "image"))
    assert.ok(
      (await ctx.attachments.readImage(block.attachment)).data.length > 0,
    );
  const attachment = await tool("mcp__bb__send_attachment", {
    target_account: client.peer,
    source: {
      base64: Buffer.from("synthetic attachment").toString("base64"),
      mime_type: "text/plain",
      filename: "probe.txt",
    },
  });
  const task = await tool("mcp__bb__start_download", {
    media_id: attachment.attachment.media_id,
    directory: resolve(root, "downloads"),
  });
  await until(
    async () =>
      (await tool("mcp__bb__get_download", { task_id: task.task_id }))
        .status === "succeeded",
  );
  await until(async () =>
    (await tool("bb_bridge_status")).recovery.items.some(
      (r) => r.kind === "download" && r.state === "completed",
    ),
  );
  await explicitRead("get_message", {message_id: attachment.id});
  await until(async () =>
    (await tool("bb_bridge_status")).recovery.items.some(
      (r) => r.messageId === attachment.id && r.state === "completed",
    ),
  );
  const previousJobs = (await tool("bb_bridge_status")).recovery.items.length;
  await settings({ enabled: false });
  await until(async () =>
    ctx.tools.schemas().every((t) => !t.name.startsWith("mcp__bb__")),
  );
  await handle.dispose();
  handle = await ctx.agents.create({
    sessionId: "installed-settled-rebuilt",
    agentOptions: { provider: "product-double", model: "fixed" },
  });
  await settings({ enabled: true, targetSession: "installed-settled-rebuilt" });
  await until(async () => (await tool("bb_bridge_status")).state === "bound");
  const increment = await tool("mcp__bb__send_message", {
    target_account: client.peer,
    content: [{ type: "text", text: "new session increment" }],
  });
  await explicitRead("get_message", {message_id: increment.id});
  await until(async () =>
    (await tool("bb_bridge_status")).recovery.items.some(
      (r) => r.messageId === increment.id && r.state === "completed",
    ),
  );
  const current = modelRequests
    .at(-1)
    .find((m) =>
      m.content.some((b) => b.type === "text" && b.text.includes(increment.id)),
    );
  assert.ok(current, "explicit new-session query reaches provider");
  assert.ok(!current.content.some(b => b.type === "text" && b.text.includes('"kind":"history_context"')), "no unsolicited history bootstrap");
  assert.equal((await tool("bb_bridge_status")).recovery.items.length, previousJobs + 1);
  await explicitRead("read_messages", {account:client.peer,after_position:0,limit:10});
  const historicalImages = modelRequests.at(-1).flatMap(m=>m.content).filter(b=>b.type === "image");
  assert.equal(historicalImages.length, 2, "explicit history still returns ordered images");
  for (const [i, block] of historicalImages.entries())
    assert.deepEqual(Buffer.from((await ctx.attachments.readImage(block.attachment)).data), Buffer.from(client.images[i], "base64"));
  await settings({ enabled: false });
  await until(async () =>
    ctx.tools.schemas().every((t) => !t.name.startsWith("mcp__bb__")),
  );
  const count = modelRequests.length;
  await new Promise((r) => setTimeout(r, 750));
  assert.equal(modelRequests.length, count);
  await handle.dispose();
  handle = undefined;
  unregister();
  unregister = undefined;
  await close();
  const result = {
    installed_product: "PASS",
    register_login: "real MCP/real client",
    queries: "real MCP/real client",
    automatic_consumption: false,
    installed_peer_change: "A to B during collecting; B only",
    explicit_model_display_confirmed: true,
    explicit_sends: 4,
    explicit_new_session_history: true,
    historical_image_bytes_order: "red,blue",
    historical_jobs: 0,
    two_ordered_images: true,
    download_callback: true,
    model_calls: count,
    disabled_no_new_calls: true,
    provider: "deterministic double",
  };
  await writeFile(
    resolve(root, "installed.json"),
    JSON.stringify(result, null, 2) + "\n",
  );
  console.log(JSON.stringify(result));
} finally {
  if (handle) await handle.dispose();
  if (unregister) unregister();
  if (ctx) await ctx.fiber.dispose();
}
