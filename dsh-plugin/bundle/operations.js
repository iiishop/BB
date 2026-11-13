import { mkdir, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import { digest, readJson, writeJson } from "./store.js";
// Dispatch metadata, never a second message/result database. Client operations
// remain authoritative. A replacement queries every persisted operation, never sends.
export class Operations {
  constructor(client, root) {
    this.client = client;
    this.root = resolve(
      root,
      "operations",
      digest([client.identity.account, client.identity.consumer_id]),
    );
    this.rows = new Map();
  }
  async open() {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    for (const f of (await readdir(this.root))
      .filter((f) => /^\d+-[a-f0-9]{64}\.json$/.test(f))
      .sort((a, b) => Number(a.split("-")[0]) - Number(b.split("-")[0]))) {
      const row = await readJson(resolve(this.root, f));
      if (row.version !== 1 || typeof row.operation_id !== "string")
        throw new Error("Invalid operation journal");
      this.rows.set(row.key, row);
    }
  }
  async put(row) {
    const value = {
      ...row,
      version: 1,
      revision: this.client.identity.binding_revision,
    };
    await writeJson(
      resolve(this.root, `${value.revision}-${value.key}.json`),
      value,
    );
    this.rows.set(value.key, value);
    return value;
  }
  async query(row, result) {
    try {
      let fact;
      if (row.kind === "download") {
        let taskId = row.task_id ?? result?.task_id;
        if (!taskId) {
          // A lost start response is reconciled from client-owned events, never
          // by issuing start again or inventing a new operation ID.
          let after_cursor = 0;
          for (;;) {
            const page = await this.client.call("events/read", {
              after_cursor,
              limit: 100,
            });
            const event = page.items
              .map((entry) => entry.event)
              .find(
                (e) =>
                  e.type.startsWith("download.") &&
                  e.operation_id === row.operation_id &&
                  e.origin_identity.account === this.client.identity.account &&
                  e.origin_identity.consumer_id ===
                    this.client.identity.consumer_id,
              );
            if (event) {
              taskId = event.task_id;
              break;
            }
            if (!page.has_more) break;
            after_cursor = page.next_cursor;
          }
        }
        if (!taskId) {
          await this.put({ ...row, state: "uncertain" });
          return null;
        }
        fact = await this.client.call("downloads/get", { task_id: taskId });
        if (
          fact.operation_id !== row.operation_id ||
          fact.origin_identity.account !== this.client.identity.account ||
          fact.origin_identity.consumer_id !== this.client.identity.consumer_id
        )
          throw new Error("Download operation identity mismatch");
        row = { ...row, task_id: fact.task_id };
      } else {
        fact = await this.client.call("operations/get", {
          operation_id: row.operation_id,
        });
      }
      await this.put({ ...row, state: fact.status });
      return fact;
    } catch (error) {
      if (error.status !== 404) throw error;
      await this.put({ ...row, state: "uncertain" });
      return null;
    }
  }
  async prepare(exec) {
    const origin = exec.agent.session
      .snapshotEvents()
      .findLast(
        (e) =>
          e.type === "assistant/message" &&
          e.data.message.content.some(
            (b) => b.type === "tool-call" && b.id === exec.callId,
          ),
      );
    const ordinal = origin?.data.message.content.findIndex(
      (b) => b.type === "tool-call" && b.id === exec.callId,
    );
    const key = digest([
        exec.agent.session.id,
        origin?.data.message.id ?? "manual",
        ordinal ?? exec.callId,
      ]),
      payloadDigest = digest([exec.name, exec.arguments]);
    const existing = this.rows.get(key);
    if (existing) {
      if (existing.payloadDigest !== payloadDigest)
        throw new Error("Operation plan changed");
      await this.query(existing);
      throw new Error(
        "Recovered operation: query its original operation_id; do not redispatch",
      );
    }
    if (
      [...this.rows.values()].some(
        (r) => r.operation_id === exec.arguments.operation_id,
      )
    )
      throw new Error("Operation ID already planned: query it");
    const operation_id = exec.arguments.operation_id ?? "bb-" + key;
    const row = await this.put({
      key,
      operation_id,
      session: exec.agent.session.id,
      sessionCreatedAt: exec.agent.session.header.createdAt,
      kind: exec.name === "mcp__bb__start_download" ? "download" : "send",
      payloadDigest,
      state: "dispatching",
    });
    // Persist dispatch intent before validating the currently owned revision.
    await this.client.check();
    return row;
  }
  async reconcile() {
    for (const row of this.rows.values()) await this.query(row);
  }
  status() {
    return [...this.rows.values()].map(({ operation_id, state }) => ({
      operation_id,
      state,
    }));
  }
  uncertain() {
    return [...this.rows.values()].some((r) =>
      ["dispatching", "pending", "running", "uncertain"].includes(r.state),
    );
  }
}
