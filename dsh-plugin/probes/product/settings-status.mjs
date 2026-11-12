import assert from "node:assert/strict";
import http from "node:http";
import { glob, readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { Client } from "../../bundle/client.js";

export async function runStatus({
  p,
  config,
  context,
  origin,
  probe,
  until,
  save,
  screenshot,
  facts,
  metrics,
}) {
  const requests = [];
  // Real TCP closure in front of the actual Dart client; no fake HTTP responses.
  const proxy = http.createServer((req, res) => {
    requests.push(req.url);
    const upstream = http.request(
      config.origin + req.url,
      { method: req.method, headers: req.headers },
      (reply) => {
        res.writeHead(reply.statusCode, reply.headers);
        reply.pipe(res);
      },
    );
    upstream.on("error", () => res.destroy());
    req.pipe(upstream);
  });
  const listen = (port) =>
    new Promise((r) => proxy.listen(port, "127.0.0.1", r));
  const close = () =>
    new Promise((r) => {
      proxy.closeAllConnections();
      proxy.close(r);
    });
  await listen(0);
  const port = proxy.address().port;
  assert.ok(port > 1024);
  const url = "http://127.0.0.1:" + port;
  await close();
  const input = (name) => p.locator('.bb-settings input[name="' + name + '"]');
  const status = async () =>
    (await context.request.get(origin + "/api/bb-bridge/status")).json();
  const state = async (name, code) => {
    await until(async () => {
      const s = await status();
      return s.state === name && (code === undefined || s.error === code);
    });
    const s = await status();
    assert.deepEqual(Object.keys(s).sort(), [
      "error",
      "required_sessions",
      "state",
    ]);
    if (code)
      await p
        .locator(".bb-settings")
        .getByText("Diagnostic code: " + code, { exact: true })
        .waitFor();
    return s;
  };
  const toggle = async () => {
    await input("enabled").uncheck();
    await save(p);
    await input("enabled").check();
    await save(p);
  };
  const bindCount = () =>
    requests.filter((x) => x === "/v2/consumers/bind").length;
  const login = async (account) => {
    const r = await fetch(config.origin + "/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ account, password: "Abc123" }),
    });
    assert.equal(r.status, 200);
  };
  const journal = async () => {
    const entries = [];
    for await (const file of glob(config.state_root + "/journal/**/*.json"))
      entries.push([
        file,
        createHash("sha256")
          .update(await readFile(file))
          .digest("hex"),
      ]);
    return entries.sort();
  };
  try {
    await input("clientUrl").fill(url);
    await input("targetSession").fill("settings-fixture");
    await input("peerAccount").fill(config.peer);
    await input("pollMs").fill("250");
    await save(p);
    metrics.initial_refusal = await state(
      "connection_unavailable",
      "client_connection_refused",
    );
    await p
      .getByText("Start the BB client and check its loopback URL and port.", {
        exact: false,
      })
      .waitFor();
    await screenshot("status-01-initial-refused");
    await listen(port);
    await p.waitForTimeout(850);
    assert.equal((await status()).state, "connection_unavailable");
    assert.equal(
      bindCount(),
      0,
      "fence still stops automatic binding after TCP recovery",
    );
    await toggle();
    metrics.initial_restored = await state("bound");
    await screenshot("status-07-restored-bound");
    facts.push(
      "closed non-reserved high port: accurate paused state; UI disable/save enable/save restores bound",
    );

    await close();
    metrics.bound_refusal = await state(
      "connection_unavailable",
      "client_connection_refused",
    );
    await screenshot("status-02-check-refused");
    const count = bindCount();
    await listen(port);
    await p.waitForTimeout(850);
    assert.equal(bindCount(), count);
    assert.equal((await status()).state, "connection_unavailable");
    await toggle();
    metrics.check_restored = await state("bound");
    facts.push(
      "connected client.check ECONNREFUSED remains paused, no automatic rebind; same explicit recovery works",
    );

    await input("clientUrl").fill("http://127.0.0.1:1");
    await save(p);
    metrics.restricted_port = await state(
      "connection_unavailable",
      "client_port_restricted",
    );
    await screenshot("status-03-restricted-port");
    await input("clientUrl").fill(url);
    await save(p);
    await state("bound");
    facts.push(
      "fetch-restricted port has its own safe diagnostic, not an identity error; corrected URL restores bound",
    );

    await login(config.switched);
    metrics.stale_identity = await state("blocked", "stale_identity");
    await toggle();
    metrics.session_identity = await state(
      "blocked",
      "session_identity_mismatch",
    );
    await screenshot("status-04-identity-fence");
    await login(config.account);
    await toggle();
    await state("bound");
    const competitor = new Client(url, config.state_root);
    await competitor.bind("settings-fixture");
    competitor.close();
    metrics.stale_binding = await state("blocked", "stale_binding");
    await screenshot("status-05-binding-fence");
    const before = bindCount();
    await p.waitForTimeout(850);
    assert.equal(bindCount(), before);
    await toggle();
    await state("bound");
    facts.push(
      "actual account switch, session-owner mismatch and competing owner CAS retain identity/binding fences",
    );

    assert.equal(
      (
        await context.request.post(origin + "/api/bb-settings-test/unknown")
      ).status(),
      200,
    );
    const auth = await fetch(config.api + "/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ account: config.peer, password: "Abc123" }),
    });
    const token = (await auth.json()).token;
    const sent = await fetch(config.api + "/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + token,
      },
      body: JSON.stringify({
        target_account: config.account,
        client_nonce: "status-unknown",
        content: [{ type: "text", text: "synthetic unknown-result fence" }],
      }),
    });
    assert.equal(sent.status, 200);
    await until((r) =>
      r.bridge?.recovery.items.some((x) => x.state === "uncertain"),
    );
    const original = await journal();
    assert.ok(original.length > 0);
    const calls = (await probe()).calls;
    await input("targetSession").fill("settings-replacement");
    await save(p);
    metrics.recovery = await state("blocked", "recovery_session_required");
    assert.deepEqual(metrics.recovery.required_sessions, ["settings-fixture"]);
    await screenshot("status-06-recovery-fence");
    await p.waitForTimeout(850);
    assert.deepEqual(
      await journal(),
      original,
      "original uncertain records survive unchanged",
    );
    assert.equal((await probe()).calls, calls, "no blind model retry");
    const commits = requests.filter((x) =>
      /\/(send_message|send_attachment|confirm_presentation|ack_messages)$/.test(
        x,
      ),
    );
    assert.deepEqual(commits, [], "no sends or early settlement");
    metrics.requests = Object.fromEntries(
      [...new Set(requests)]
        .sort()
        .map((path) => [path, requests.filter((x) => x === path).length]),
    );
    metrics.uncertain = {
      retained: true,
      records: original.length,
      new_model_calls: 0,
      sends_or_settlements: 0,
    };
    facts.push(
      "real unknown turn + replacement session: required_sessions retained, uncertain journal byte hashes unchanged, zero new model calls/send/confirm/ACK",
    );
  } finally {
    if (proxy.listening) await close();
  }
}
