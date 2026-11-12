// Actual browser interactions with the installed stock Web UI, never a mock shell.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFile, writeFile, mkdir, stat } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
const [configPath, phase] = process.argv.slice(2);
const config = JSON.parse(await readFile(configPath));
const require = createRequire(config.playwright),
  { chromium } = require("playwright");
const url = (await readFile(config.host_log, "utf8")).match(
  /http:\/\/127\.0\.0\.1:\d+\/\?token=[A-Za-z0-9_-]+/,
)[0];
const origin = new URL(url).origin;
await mkdir(config.output, { recursive: true });
const browser = await chromium.launch({
  executablePath: config.chromium,
  headless: true,
  args: ["--no-sandbox"],
});
const context = await browser.newContext({
  viewport: { width: 1440, height: 1250 },
});
const errors = [],
  facts = [],
  metrics = {};
context.on("page", (p) => {
  p.setDefaultTimeout(15000);
  p.on("pageerror", (e) => errors.push(e.message));
});
const p = await context.newPage();
async function open(page) {
  await page.goto(url);
  await page.getByRole("button", { name: "Plugins", exact: true }).waitFor();
  await page.waitForTimeout(800);
  if (
    await page
      .getByRole("button", { name: "Continue", exact: true })
      .isVisible()
  )
    await page.getByRole("button", { name: "Continue", exact: true }).click();
  if (
    await page
      .getByRole("button", { name: "Add API Key", exact: true })
      .isVisible()
  ) {
    await page
      .getByRole("button", { name: "Add API Key", exact: true })
      .click();
    await page
      .getByRole("button", { name: "Configure later", exact: true })
      .click();
  }
  await page.getByRole("button", { name: "Plugins", exact: true }).click();
}
async function editor(page) {
  await page
    .getByRole("button", { name: "View BB Chat Bridge", exact: true })
    .click();
  await page.locator('.bb-settings input[name="clientUrl"]').waitFor();
}
async function save(page) {
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await page
    .getByText("Saved. Changes apply live; no host restart is required.", {
      exact: true,
    })
    .waitFor();
}
async function probe() {
  const r = await context.request.get(origin + "/api/bb-settings-test/probe");
  assert.equal(r.status(), 200);
  return r.json();
}
async function until(check) {
  const end = Date.now() + 18000;
  while (Date.now() < end) {
    const value = await probe();
    if (await check(value)) return value;
    await new Promise((r) => setTimeout(r, 80));
  }
  throw new Error("Settings gate deadline: " + JSON.stringify(await probe()));
}
async function screenshot(name, page = p) {
  await page.screenshot({
    path: resolve(config.output, name + ".png"),
    fullPage: true,
  });
}
function children() {
  const rows = execFileSync("ps", ["-eo", "pid=,ppid=,args="], {
    encoding: "utf8",
  })
    .trim()
    .split("\n")
    .map((s) => {
      const m = s.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
      return { pid: Number(m[1]), ppid: Number(m[2]), cmd: m[3] };
    });
  const all = new Set([config.host_pid]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const r of rows)
      if (all.has(r.ppid) && !all.has(r.pid)) {
        all.add(r.pid);
        changed = true;
      }
  }
  return rows
    .filter((r) => all.has(r.pid) && r.cmd.includes("bb-dsh-plugin"))
    .map((r) => r.pid);
}
async function gone(pids) {
  const deadline = Date.now() + 10000;
  for (const pid of pids) {
    while (Date.now() < deadline) {
      try {
        await stat("/proc/" + pid);
      } catch (error) {
        if (error.code === "ENOENT") break;
        throw error;
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    await assert.rejects(stat("/proc/" + pid), (e) => e.code === "ENOENT");
  }
}
try {
  await open(p);
  if (phase === "edit") {
    await p.getByRole("button", { name: "Add plugin", exact: true }).click();
    await p
      .getByRole("textbox", { name: "Package name or address" })
      .fill(config.bundle);
    await p.getByRole("button", { name: "Install", exact: true }).click();
    await p.getByRole("button", { name: "Enable now", exact: true }).click();
    await p
      .getByRole("button", { name: "View BB Chat Bridge", exact: true })
      .waitFor();
  }
  await editor(p);
  assert.equal(await p.locator(".bb-settings input").count(), 5);
  if (phase === "edit") {
    await p.locator('.bb-settings input[name="clientUrl"]').fill(config.origin);
    await p
      .locator('.bb-settings input[name="targetSession"]')
      .fill("settings-fixture");
    await p.locator('.bb-settings input[name="peerAccount"]').fill(config.peer);
    await p.locator('.bb-settings input[name="pollMs"]').fill("1500");
    await save(p);
    await until((r) => r.bridge?.state === "bound");
    const safeStatus = await (
      await context.request.get(origin + "/api/bb-bridge/status")
    ).json();
    assert.deepEqual(Object.keys(safeStatus).sort(), [
      "error",
      "required_sessions",
      "state",
    ]);
    assert.ok(
      [401, 403].includes(
        (await fetch(origin + "/api/bb-bridge/status")).status,
      ),
    );
    await p.getByText("Connected and bound", { exact: false }).waitFor();
    await screenshot("01-connected-form");
    facts.push(
      "five editable fields; native save; real-client binding; owner-only safe status",
    );
    const before = await probe();
    const invalid = await context.request.post(
      origin + "/api/bb-settings-test/invalid",
    );
    const validation = await invalid.json();
    assert.equal(validation.rejected.length, 9);
    assert.ok(validation.rejected.every(Boolean));
    assert.equal(validation.unchanged, true);
    await p
      .locator('.bb-settings input[name="clientUrl"]')
      .fill("https://example.invalid");
    assert.equal(
      await p
        .getByRole("button", { name: "Save changes", exact: true })
        .isDisabled(),
      true,
    );
    await screenshot("02-invalid-value");
    await p
      .getByRole("button", { name: "Reload saved values", exact: true })
      .click();
    assert.equal((await probe()).form.revision, before.form.revision);
    facts.push(
      "UI invalid value blocked; nine host invalid writes preserve revision/value",
    );
    // Two actual pages retain different edit revisions. No mocked transport.
    await p.locator('.bb-settings input[name="pollMs"]').fill("1700");
    const second = await context.newPage();
    await open(second);
    await editor(second);
    await second.locator('.bb-settings input[name="pollMs"]').fill("1800");
    await save(second);
    await p
      .getByText("Configuration changed elsewhere.", { exact: false })
      .waitFor();
    await p.getByRole("button", { name: "Save changes", exact: true }).click();
    await p.getByText("Save was refused.", { exact: false }).waitFor();
    assert.equal((await probe()).form.value.pollMs, 1800);
    await screenshot("03-stale-revision");
    await second.close();
    await p
      .getByRole("button", { name: "Reload saved values", exact: true })
      .click();
    await p.locator('.bb-settings input[name="pollMs"]').fill("1500");
    await save(p);
    facts.push(
      "two-page stale revision refused; winner preserved; explicit reload",
    );
    const login = await fetch(config.api + "/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ account: config.peer, password: "Abc123" }),
    });
    const token = (await login.json()).token;
    const sent = await fetch(config.api + "/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + token,
      },
      body: JSON.stringify({
        target_account: config.account,
        client_nonce: "settings-ui-inbound",
        content: [{ type: "text", text: "synthetic settings lifecycle input" }],
      }),
    });
    assert.equal(sent.status, 200);
    const message = await sent.json();
    await until(
      (r) =>
        r.calls === 1 + r.titleRequests &&
        r.turns === 1 &&
        r.bridge?.recovery.items.some(
          (x) => x.messageId === message.id && x.state === "completed",
        ),
    );
    const completed = await probe();
    assert.equal(completed.nativeInputs, 1);
    metrics.before_disable = {
      provider_calls: completed.calls,
      title_requests: completed.titleRequests,
      bb_inputs: completed.nativeInputs,
      turns: completed.turns,
    };
    const owned = children();
    assert.ok(owned.length >= 1);
    await p.locator('.bb-settings input[name="enabled"]').uncheck();
    await save(p);
    await until((r) => r.mcpTools === 0);
    await gone(owned);
    await p
      .getByText("Connection status: Disabled", { exact: false })
      .waitFor();
    await screenshot("04-disabled-cleanup");
    await p.locator('.bb-settings input[name="enabled"]').check();
    await save(p);
    await until((r) => r.bridge?.state === "bound" && r.mcpTools > 0);
    const resumed = await probe();
    assert.equal(resumed.calls, completed.calls);
    assert.equal(resumed.turns, 1);
    assert.equal(resumed.nativeInputs, 1);
    metrics.after_enable = {
      provider_calls: resumed.calls,
      bb_inputs: resumed.nativeInputs,
      tools: resumed.mcpTools,
    };
    facts.push(
      "disable removes MCP tools and owned processes; enable binds without replay",
    );
    await open(p);
    await editor(p);
    assert.equal(
      await p.locator('.bb-settings input[name="pollMs"]').inputValue(),
      "1500",
    );
    const expected = {
      clientUrl: config.origin,
      targetSession: "settings-fixture",
      peerAccount: config.peer,
      enabled: true,
      pollMs: 1500,
    };
    assert.deepEqual((await probe()).form.value, expected);
    await writeFile(
      resolve(config.output, "expected.json"),
      JSON.stringify(expected, null, 2) + "\n",
    );
    await p.getByRole("button", { name: "Account menu", exact: true }).click();
    await p.getByText("Settings", { exact: true }).click();
    const settingsDialog = p.getByRole("dialog");
    await settingsDialog
      .getByRole("button", { name: "BB Chat Bridge", exact: true })
      .click();
    assert.equal(
      await settingsDialog
        .locator('.bb-settings input[name="clientUrl"]')
        .inputValue(),
      config.origin,
    );
    await settingsDialog
      .locator('.bb-settings input[name="pollMs"]')
      .fill("1600");
    await save(settingsDialog);
    assert.equal((await probe()).form.value.pollMs, 1600);
    await settingsDialog
      .locator('.bb-settings input[name="pollMs"]')
      .fill("1500");
    await save(settingsDialog);
    const ids = await p
      .locator(".bb-settings input")
      .evaluateAll((ns) => ns.map((n) => n.id));
    assert.equal(new Set(ids).size, ids.length);
    await screenshot("08-native-settings-dialog");
    await settingsDialog
      .getByRole("button", { name: "Close", exact: true })
      .click();
    facts.push(
      "native Settings section saves through same revision; unique accessible field IDs",
    );
    // Theme comes from the real host's System preference and OS media query.
    await p.emulateMedia({ colorScheme: "dark" });
    await screenshot("05-dark-form");
    facts.push("reopen preserves values; host dark theme render");
  } else {
    const expected = JSON.parse(
      await readFile(resolve(config.output, "expected.json")),
    );
    await until((r) => r.bridge?.state === "bound");
    const restored = await probe();
    assert.deepEqual(restored.form.value, expected);
    assert.equal(restored.calls, 0);
    assert.equal(restored.nativeInputs, 1);
    metrics.after_restart = {
      provider_calls: restored.calls,
      bb_inputs: restored.nativeInputs,
      turns: restored.turns,
    };
    await screenshot("06-restarted-readback");
    facts.push(
      "host restart preserves all fields; original native session restored; zero model replay",
    );
    const owned = children();
    assert.ok(owned.length >= 1);
    await p.locator('.bb-settings input[name="enabled"]').uncheck();
    await save(p);
    await until((r) => r.mcpTools === 0);
    await gone(owned);
    // Native bundle switch owns unload; its original stop/restart policy remains intact.
    await p.getByRole("switch").first().click();
    await until((r) => r.installed && r.form === null && !r.bridge);
    await p
      .getByRole("button", { name: "Uninstall BB Chat Bridge", exact: true })
      .click();
    const dialog = p.getByRole("dialog");
    await dialog
      .getByRole("button", { name: "Uninstall", exact: true })
      .click();
    await until((r) => !r.installed && r.form === null && !r.bridge);
    await open(p);
    await p.getByRole("button", { name: "Add plugin", exact: true }).waitFor();
    await p
      .getByRole("button", { name: "View BB Chat Bridge", exact: true })
      .waitFor({ state: "hidden" });
    await screenshot("07-uninstalled");
    const final = await probe();
    assert.equal(final.mcpTools, 0);
    assert.equal(final.bridge, undefined);
    assert.equal(children().length, 0);
    metrics.after_uninstall = {
      installed: final.installed,
      form: final.form,
      tools: final.mcpTools,
      owned_children: children().length,
    };
    assert.equal(
      (await context.request.get(origin + "/api/bb-bridge/status")).status(),
      404,
    );
    facts.push(
      "native disable/uninstall removes form, status route, tools and child processes",
    );
  }
  assert.deepEqual(errors, [], "no renderer exceptions");
  const result = {
    status: "PASS",
    phase,
    facts,
    metrics,
    renderer_errors: errors,
    model: "deterministic double",
    real_model: "NOT_RUN",
    host_and_client: "actual isolated fixed DSH and Dart/FastAPI",
  };
  await writeFile(
    resolve(config.output, phase + "-results.json"),
    JSON.stringify(result, null, 2) + "\n",
  );
  console.log(JSON.stringify(result));
} catch (error) {
  await screenshot("failure").catch(() => {});
  await writeFile(
    resolve(config.output, "failure-ui.txt"),
    await p.locator("body").innerText(),
  ).catch(() => {});
  throw error;
} finally {
  await browser.close();
}
