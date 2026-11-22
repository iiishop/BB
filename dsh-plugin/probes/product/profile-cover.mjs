import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

export async function probeProfileCovers({
  client, ctx, executeTool, tool, settings, until, switchSession,
}) {
  const suffix = (operation) => "mcp__bb__" + operation;
  const password = "Abc123"; // Only for the isolated live.py test service.
  const versionOf = (bytes) =>
    "sha256-" + createHash("sha256").update(bytes).digest("hex");

  await settings({
    clientUrl: client.origin,
    targetSession: "installed-product",
  });
  const bound = (account) => until(async () => {
    const state = await tool("bb_bridge_status");
    return state.state === "bound" && state.recovery.identity.account === account;
  });
  await bound(client.account);
  const second = client.peer;
  assert.notEqual(second, client.account);
  const inventory = ctx.tools.schemas().map((entry) => entry.name);
  assert.ok(inventory.includes(suffix("view_cover")));
  assert.ok(inventory.includes(suffix("update_cover")));

  async function view(account, optionalTarget) {
    const r = await executeTool(suffix("view_cover"), optionalTarget ? { account } : {});
    assert.equal(r.isError, false, JSON.stringify(r.content));
    assert.ok(!r.value?.isError);
    const meta = r.value.structuredContent;
    assert.equal(meta.account, account);
    assert.equal(meta.cover_url, "/covers/" + account);
    assert.equal("data" in meta, false);
    const images = r.value.content.filter((block) => block.type === "image");
    assert.equal(images.length, 1);
    assert.equal(images[0].mimeType, meta.mime_type);
    const bytes = Buffer.from(images[0].data, "base64");
    assert.equal(meta.cover_version, versionOf(bytes));
    return { meta, bytes };
  }

  const defaultA = await view(client.account, false);
  const defaultPeer = await view(client.peer, true);
  assert.equal(defaultA.meta.is_default, true);
  assert.equal(defaultPeer.meta.is_default, true);
  assert.deepEqual(defaultA.bytes, defaultPeer.bytes);
  if (client.coverAsset) {
    assert.deepEqual(defaultA.bytes, await readFile(client.coverAsset));
  }
  const deniedA = await executeTool(suffix("update_cover"), {
    account: second,
    base64: client.images[0],
  });
  assert.ok(deniedA.isError || deniedA.value?.isError);
  assert.deepEqual((await view(second, true)).bytes, defaultPeer.bytes);
  assert.deepEqual((await view(client.account, false)).bytes, defaultA.bytes);

  const a = await tool(suffix("update_cover"), { base64: client.images[0] });
  assert.equal(a.cover_url, "/covers/" + client.account);
  const aOwn = await view(client.account, false);
  assert.equal(aOwn.meta.is_default, false);
  assert.equal(aOwn.meta.cover_version, a.cover_version);
  assert.deepEqual(aOwn.bytes, Buffer.from(client.images[0], "base64"));
  const invalid = await executeTool(suffix("update_cover"), { base64: "bad!" });
  assert.ok(invalid.isError || invalid.value?.isError);
  assert.deepEqual((await view(client.account, false)).bytes, aOwn.bytes);

  await tool(suffix("login_account"), { account: second, password });
  await switchSession();
  await bound(second);

  assert.deepEqual((await view(client.account, true)).bytes, aOwn.bytes);
  assert.deepEqual((await view(second, false)).bytes, defaultA.bytes);
  const b = await tool(suffix("update_cover"), { base64: client.images[1] });
  const bOwn = await view(second, false);
  assert.equal(b.cover_url, "/covers/" + second);
  assert.equal(bOwn.meta.cover_version, b.cover_version);
  assert.deepEqual(bOwn.bytes, Buffer.from(client.images[1], "base64"));
  const denied = await executeTool(suffix("update_cover"), {
    account: client.account,
    base64: client.images[0],
  });
  assert.ok(denied.isError || denied.value?.isError);
  assert.deepEqual((await view(second, false)).bytes, bOwn.bytes);
  assert.deepEqual((await view(client.account, true)).bytes, aOwn.bytes);

  const login = await fetch(client.api + "/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ account: second, password }),
  });
  assert.equal(login.status, 200);
  const { token } = await login.json();
  const headers = { Authorization: "Bearer " + token };
  const forbidden = new FormData();
  forbidden.set("file", new Blob([bOwn.bytes], { type: bOwn.meta.mime_type }));
  forbidden.set("account", client.account);
  const rejected = await fetch(client.api + "/me/cover", {
    method: "POST", body: forbidden, headers,
  });
  assert.equal(rejected.status, 422);
  const server = await fetch(client.api + aOwn.meta.cover_url, { headers });
  assert.equal(server.status, 200);
  assert.equal(server.headers.get("etag"), JSON.stringify(aOwn.meta.cover_version));
  assert.deepEqual(Buffer.from(await server.arrayBuffer()), aOwn.bytes);

  return {
    stock_dsh: true,
    real_tools: ["view_cover", "update_cover"],
    isolated_writers: 2,
    own_and_other_reads: true,
    default_sha256: defaultA.meta.cover_version,
    default_bytes: defaultA.bytes.length,
    default_matches_client_asset: Boolean(client.coverAsset),
    upload_image_block_matches_http: true,
    invalid_upload_retains_prior: true,
    cross_account_tool_and_http_rejected: true,
    provider: "deterministic double",
  };
}
