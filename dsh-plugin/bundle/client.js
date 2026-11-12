import { randomBytes, randomUUID } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { digest, readJson, writeJson, createJson, same } from "./store.js";
export class ClientFailure extends Error {
  constructor(code, status = 409) {
    super(code);
    this.code = code;
    this.status = status;
  }
}
export class Client {
  constructor(origin, root) {
    const u = new URL(origin);
    if (
      u.protocol !== "http:" ||
      u.hostname !== "127.0.0.1" ||
      u.username ||
      u.password ||
      u.pathname !== "/" ||
      u.search ||
      u.hash
    )
      throw new Error("Client URL must be a loopback HTTP origin");
    this.origin = u.origin;
    this.root = resolve(root);
    this.abort = new AbortController();
  }
  async raw(path, body, owner) {
    const r = await fetch(this.origin + path, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(owner ? { "X-BB-Consumer-Key": owner } : {}),
      },
      body: JSON.stringify(body),
      redirect: "error",
      signal: AbortSignal.any([this.abort.signal, AbortSignal.timeout(135000)]),
    });
    let value;
    try {
      value = await r.json();
    } catch {
      throw new ClientFailure("invalid_response", 502);
    }
    if (!r.ok)
      throw new ClientFailure(
        value.error?.code ?? "upstream_unavailable",
        r.status,
      );
    return value;
  }
  async bind(sessionId) {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    const negotiation = await this.raw("/v2/protocol/negotiate", {
      supported_versions: [2],
    });
    if (negotiation.selected_version !== 2)
      throw new ClientFailure("unsupported_version", 426);
    const { auth } = await this.raw("/v2/status", {});
    if (!auth) throw new ClientFailure("unauthenticated", 401);
    // A native conversation is never relabelled as another BB account.
    const sessionOwner = await createJson(
      resolve(this.root, `session-${digest(sessionId)}.json`),
      { account: auth.account },
    );
    if (sessionOwner.account !== auth.account)
      throw new ClientFailure("session_identity_mismatch");
    const path = resolve(this.root, `owner-${digest(auth.account)}.json`);
    let owner = await readJson(path);
    if (!owner) {
      owner = await createJson(path, {
        key: randomBytes(32).toString("base64url"),
      });
    }
    const current = await this.raw(
      "/v2/consumers/create",
      { expected_auth: auth, session_id: sessionId },
      owner.key,
    );
    // Always explicit CAS for an instance's ownership, even when reopening the same session.
    const binding = await this.raw(
      "/v2/consumers/bind",
      {
        expected_auth: auth,
        consumer_id: current.identity.consumer_id,
        expected_binding_revision: current.identity.binding_revision,
        session_id: sessionId,
      },
      owner.key,
    );
    this.identity = binding.identity;
    this.owner = owner.key;
    this.stateFile = resolve(this.root, `binding-${randomUUID()}.json`);
    await writeJson(this.stateFile, {
      owner_key: this.owner,
      identity: this.identity,
    });
    return this.identity;
  }
  async check() {
    if (!this.identity || this.abort.signal.aborted)
      throw new ClientFailure("stale_identity");
    const { auth } = await this.raw("/v2/status", {});
    if (
      !auth ||
      auth.account !== this.identity.account ||
      auth.auth_generation !== this.identity.auth_generation
    )
      throw new ClientFailure("stale_identity");
    const b = await this.raw(
      "/v2/consumers/get",
      { expected_auth: auth, consumer_id: this.identity.consumer_id },
      this.owner,
    );
    if (!same(b.identity, this.identity))
      throw new ClientFailure("stale_binding");
  }
  async call(path, body = {}) {
    const reply = await this.raw(
      "/v2/" + path,
      { ...body, expected_identity: this.identity },
      this.owner,
    );
    if (!same(reply.identity, this.identity))
      throw new ClientFailure("stale_identity");
    return reply.result;
  }
  close() {
    this.abort.abort();
  }
}
