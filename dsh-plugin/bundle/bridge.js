import { randomUUID } from "node:crypto";
import { History } from "./history.js";
import { Operations } from "./operations.js";
import { digest, Journal } from "./store.js";

// Metadata only. Messages, display receipts and watermarks stay authoritative in BB.
export class Bridge {
  constructor(ctx, agent, client, root, checkpoint = async () => {}) {
    Object.assign(this, { ctx, agent, client, root, checkpoint });
    this.journal = new Journal(root, client.identity);
    this.operations = new Operations(client, root);
    this.history = new History(this);
    this.tail = Promise.resolve();
    this.observers = Promise.resolve();
    this.closed = false;
    this.waiters = new Set();
    this.errors = [];
  }
  serial(fn) {
    const p = this.tail.then(fn);
    this.tail = p.catch(() => {});
    return p;
  }
  async flush() {
    if ((await this.ctx.sessions.flush(this.agent.session)) !== true)
      throw new Error("Session flush failed");
  }
  async check() {
    if (this.closed) throw new Error("Bridge stopped");
    await this.client.check();
  }
  async mount() {
    await this.journal.open();
    await this.operations.open();
    const self = this;
    this.fiber = await this.ctx.plugin({
      name: "bb-chat-consumption",
      apply(ctx) {
        ctx.on("agent/pre-step", async (p, next) => {
          if (p.agent === self.agent) {
            self.turn = p.turn;
            await self.check();
          }
          return next();
        });
        ctx.on("llm/stream", async function* (options, next) {
          if (options.sessionId !== self.agent.session.id) {
            yield* next();
            return;
          }
          const candidates = self.journal
            .list()
            .map((row) => {
              if (row.callId && !row.nativeId) {
                const event = self.agent.session
                  .snapshotEvents()
                  .findLast(
                    (e) =>
                      e.type === "tool/result" &&
                      e.data.turn === row.claimTurn &&
                      e.data.message.toolCallId === row.callId,
                  );
                if (event) row.nativeId = event.data.message.id;
              }
              return row;
            })
            .filter(
              (row) =>
                (row.state === "prepared" ||
                  (row.state === "presented" && row.turn === self.turn)) &&
                options.messages.some((m) => m.id === row.nativeId),
            );
          if (!candidates.length) {
            yield* next();
            return;
          }
          for (const row of candidates) {
            const m = options.messages.find((m) => m.id === row.nativeId);
            if (
              m.content.filter((b) => b.type === "image" && !b.offloaded)
                .length < (row.projectionImageCount ?? row.imageCount)
            )
              throw new Error("BB image presentation gap");
            row.nativeId = m.id;
            row.turn = self.turn;
            row.requestDigest = digest(options.messages);
            row.state = "dispatching";
            await self.serial(() => self.journal.put(row));
          }
          await self.flush();
          // Dispatch intent is durable BEFORE the fencing read: a replacement that
          // wins CAS sees uncertainty, or the old request fails its fence before dispatch.
          await self.check();
          await self.checkpoint("dispatching");
          let finish;
          try {
            for await (const chunk of next()) {
              if (chunk.type === "finish") finish = chunk.reason.kind;
              yield chunk;
            }
            if (!["stop", "tool-calls"].includes(finish))
              throw new Error("Unsuccessful model turn");
            for (const candidate of candidates)
              await self.serial(async () => {
                const row = self.journal.get(candidate.key);
                row.state = "presented";
                await self.journal.put(row);
              });
          } catch (error) {
            for (const candidate of candidates)
              await self.serial(async () => {
                const row = self.journal.get(candidate.key);
                row.state = "uncertain";
                await self.journal.put(row);
              });
            throw error;
          }
        });
        ctx.on("session/event", (session, event) => {
          if (session !== self.agent.session || event.type !== "turn/end")
            return;
          self.observers = self.observers
            .then(async () => {
              for (const row of self.journal
                .list()
                .filter(
                  (x) => x.turn === event.data.turn && x.state !== "completed",
                )) {
                if (
                  row.state === "presented" &&
                  event.data.reason.kind === "completed"
                )
                  await self.settle(row);
                else
                  await self.serial(() =>
                    self.journal.put({ ...row, state: "uncertain" }),
                  );
              }
            })
            .catch((error) => {
              self.errors.push(error.code ?? "settlement_unavailable");
            });
        });
        ctx.on("tools/pre-execute", async (exec, next) => {
          if (
            exec.agent !== self.agent ||
            exec.name !== "mcp__bb__wait_messages"
          )
            return next();
          await self.serial(async () => {
            await self.check();
            if (
              self.waiters.size ||
              self.journal.list().some((r) => r.state !== "completed")
            )
              throw new Error("BB input already active; await its settlement");
            const cursor = await self.client.call("chat/consumption", {
              account: exec.arguments.account,
            });
            if (exec.arguments.seen_position < cursor.consumed_through)
              throw new Error("BB wait cursor precedes consumption");
            self.waiters.add(exec.callId);
          });
          return next();
        });
        ctx.on("tools/post-execute", async (exec, result, next) => {
          const query = [
            "mcp__bb__read_messages",
            "mcp__bb__get_message",
            "mcp__bb__get_context",
          ].includes(exec.name);
          if (
            exec.agent !== self.agent ||
            (!query && !self.waiters.has(exec.callId))
          )
            return next();
          if (
            query &&
            !self.agent.session
              .snapshotEvents()
              .some(
                (e) =>
                  e.type === "assistant/message" &&
                  e.data.message.content.some(
                    (b) => b.type === "tool-call" && b.id === exec.callId,
                  ),
              )
          )
            return next();
          try {
            if (!result.isError) {
              const page = result.value?.structuredContent;
              const items = page?.item ? [page.item] : page?.items;
              if (!Array.isArray(items))
                throw new Error("Missing BB query metadata");
              const context = [];
              for (const item of items)
                if (item.presentation) {
                  const claimed = await self.claim(item, {
                    callId: exec.callId,
                    projectionImageCount: items.reduce(
                      (n, i) =>
                        n + i.blocks.filter((b) => b.type === "image").length,
                      0,
                    ),
                  });
                  context.push(...(claimed?.bootstrapContent ?? []));
                }
              if (context.length) {
                const totalImages =
                  context.filter((x) => x.type === "image").length +
                  items.reduce(
                    (n, i) =>
                      n + i.blocks.filter((x) => x.type === "image").length,
                    0,
                  );
                await self.serial(async () => {
                  for (const row of self.journal
                    .list()
                    .filter(
                      (r) =>
                        r.callId === exec.callId &&
                        r.claimTurn === self.turn &&
                        r.state === "prepared",
                    ))
                    await self.journal.put({
                      ...row,
                      projectionImageCount: totalImages,
                    });
                });
                const decision = await next();
                if (decision.kind !== "accept") return decision;
                if ("value" in decision)
                  throw new Error(
                    "BB history projection conflicts with replacement tool value",
                  );
                return {
                  ...decision,
                  content: [
                    ...context,
                    ...(decision.content ?? result.content),
                  ],
                };
              }
            }
            return await next();
          } finally {
            self.waiters.delete(exec.callId);
          }
        });
        ctx.on("tools/result", (exec) => {
          self.waiters.delete(exec.callId);
        });
      },
    });
    return this;
  }
  installOperations() {
    this.operationDisposers ??= [];
    if (this.operationDisposers.length) return;
    for (const name of ["send_message", "send_attachment", "start_download"]) {
      const full = "mcp__bb__" + name,
        definition = this.ctx.tools.get(full);
      if (!definition) throw new Error("Missing MCP operation tool");
      const parameters = structuredClone(definition.parameters);
      parameters.required = parameters.required.filter(
        (k) => k !== "operation_id",
      );
      this.operationDisposers.push(
        this.agent.ctx.tools.register({
          ...definition,
          parameters,
          description:
            definition.description +
            " operation_id may be omitted: the bridge durably generates it before execution.",
          execute: async (args, exec) => {
            await this.flush();
            const plan = await this.serial(() =>
              this.operations.prepare({ ...exec, arguments: args }),
            );
            const value = await definition.execute(
              { ...args, operation_id: plan.operation_id },
              exec,
            );
            await this.checkpoint("operation-result", {
              tool: exec.name,
              result: value.structuredContent,
            });
            await this.serial(() =>
              this.operations.query(plan, value.structuredContent),
            );
            return {
              ...value,
              structuredContent: {
                ...value.structuredContent,
                operation_id: plan.operation_id,
              },
            };
          },
        }),
      );
    }
  }
  async content(item) {
    const images = item.blocks.filter((b) => b.type === "image");
    let refs = [];
    if (images.length) {
      const header = this.agent.session.requestHeader()?.config;
      const info = await this.ctx.llm.resolveModelInfo(
        header?.provider ?? this.agent.options.provider,
        header?.model ?? this.agent.options.model,
      );
      if (
        !info.inputModalities?.includes("image") ||
        !this.ctx.get("attachments")
      )
        throw new Error("BB image unavailable in current model");
      refs = await this.ctx.attachments.saveImages(
        images.map((b) => ({
          data: Buffer.from(b.data, "base64"),
          mediaType: b.mime_type,
        })),
      );
    }
    let i = 0;
    return [
      {
        type: "text",
        text: JSON.stringify({
          platform: "BB",
          account: this.client.identity.account,
          consumer_id: this.client.identity.consumer_id,
          session_id: this.agent.session.id,
          message: item.message,
        }),
      },
      ...item.blocks.map((b) =>
        b.type === "text" ? b : { type: "image", attachment: refs[i++] },
      ),
    ];
  }
  async claim(item, { callId, projectionImageCount } = {}) {
    return this.serial(async () => {
      await this.check();
      if (!callId && this.waiters.size) return;
      if (!item.presentation)
        throw new Error("BB message has no complete presentation receipt");
      const m = item.message,
        identity = this.client.identity;
      const peer =
        m.sender_account === identity.account
          ? m.target_account
          : m.sender_account;
      const key = digest([identity.account, identity.consumer_id, peer, m.id]);
      const prior = this.journal.get(key);
      if (prior) {
        // A model query wins over an as-yet-unprojected passive inbox item.
        // Dispatched inputs are never re-executed or reassigned.
        if (
          callId &&
          ["claimed", "prepared"].includes(prior.state) &&
          (!prior.nativeId ||
            !this.agent.session
              .snapshotEvents()
              .some(
                (e) =>
                  e.type === "user/message" && e.data.id === prior.nativeId,
              ))
        ) {
          if (prior.nativeId) this.agent.inbox.remove(prior.nativeId);
          await this.flush();
          const bootstrap = await this.history.prepare(prior);
          const updated = await this.journal.put({
            ...prior,
            ...(bootstrap.metadata ? { bootstrap: bootstrap.metadata } : {}),
            callId,
            claimTurn: this.turn,
            projectionImageCount,
            nativeId: undefined,
            state: "prepared",
          });
          return { ...updated, bootstrapContent: bootstrap.content };
        }
        return this.resumeDelivery(prior, item);
      }
      let row = {
        version: 1,
        key,
        account: identity.account,
        consumer: identity.consumer_id,
        peer,
        position: m.position,
        messageId: m.id,
        receiptId: item.presentation.receipt_id,
        messageDigest: digest(m),
        imageCount: item.blocks.filter((b) => b.type === "image").length,
        state: "claimed",
        session: this.agent.session.id,
        sessionCreatedAt: this.agent.session.header.createdAt,
        attempt: "bb-" + randomUUID(),
        ...(callId
          ? { callId, claimTurn: this.turn, projectionImageCount }
          : {}),
      };
      await this.flush();
      row = await this.journal.put(row);
      await this.checkpoint("claimed");
      if (callId) {
        const bootstrap = await this.history.prepare(row);
        row.state = "prepared";
        if (bootstrap.metadata) row.bootstrap = bootstrap.metadata;
        await this.journal.put(row);
        return { ...row, bootstrapContent: bootstrap.content };
      }
      return this.resumeDelivery(row, item);
    });
  }
  // Called under serial() by both online claims and replacement recovery.
  // A journal reservation is not proof of native delivery. Conversely, a native
  // projection/pending entry must not be executed again just because a plugin
  // callback or flush failed after followup.
  async resumeDelivery(row, item, { replacePending = false } = {}) {
    if (!["claimed", "prepared"].includes(row.state)) return row;
    await this.check();
    if (
      row.session !== this.agent.session.id ||
      (row.sessionCreatedAt !== undefined &&
        row.sessionCreatedAt !== this.agent.session.header.createdAt)
    )
      throw Object.assign(new Error("Original native session is required"), {
        code: "recovery_session_required",
        required_sessions: [row.session],
      });
    const projected = () =>
      this.agent.session
        .snapshotEvents()
        .some(
          (e) =>
            (row.nativeId &&
              e.type === "user/message" &&
              e.data.id === row.nativeId) ||
            (row.callId &&
              e.type === "tool/result" &&
              e.data.turn === row.claimTurn &&
              e.data.message.toolCallId === row.callId &&
              !e.data.message.isError),
        );
    if (projected()) return row;
    // A query result is still being prepared by the host; passive polling must
    // not race it. Once idle, a failed result can be retried as passive input.
    if (row.callId && this.agent.status !== "idle") return row;
    const pending = [
      ...this.agent.inbox.nextTurn,
      ...this.agent.inbox.nextStep,
    ].some((m) => m.id === row.nativeId);
    if (pending && !replacePending) {
      await this.flush();
      return row;
    }
    if (pending) {
      await this.agent.runMaintenance(async () => {
        if (!projected()) this.agent.inbox.remove(row.nativeId);
        await this.flush();
      });
      if (projected()) return row;
    }
    if (item.presentation)
      row = { ...row, receiptId: item.presentation.receipt_id };
    return this.deliver(row, item);
  }
  async deliver(row, item) {
    await this.check();
    const bootstrap = await this.history.prepare(row);
    const content = [...bootstrap.content, ...(await this.content(item))];
    row = {
      ...row,
      state: "prepared",
      ...(bootstrap.metadata ? { bootstrap: bootstrap.metadata } : {}),
      projectionImageCount: content.filter((x) => x.type === "image").length,
      session: this.agent.session.id,
      sessionCreatedAt: this.agent.session.header.createdAt,
      nativeId: "bb-" + randomUUID(),
      attempt: "bb-" + randomUUID(),
    };
    delete row.callId;
    delete row.turn;
    delete row.requestDigest;
    await this.journal.put(row);
    await this.checkpoint("prepared");
    const enqueue = async () => {
      await this.check();
      this.agent.followup({
        id: row.nativeId,
        role: "user",
        source: { kind: "user" },
        content,
      });
      await this.flush();
      await this.checkpoint("pending");
    };
    if (this.agent.status === "idle") await this.agent.runMaintenance(enqueue);
    else await enqueue();
    return row;
  }
  async settle(row) {
    return this.serial(async () => {
      await this.check();
      row = this.journal.get(row.key);
      if (row.state === "completed") return;
      const facts = this.agent.session.snapshotEvents();
      const projected = facts.some(
        (e) =>
          (e.type === "user/message" && e.data.id === row.nativeId) ||
          (e.type === "tool/result" &&
            e.data.message.id === row.nativeId &&
            !e.data.message.isError),
      );
      const end = facts.find(
        (e) => e.type === "turn/end" && e.data.turn === row.turn,
      );
      if (
        !projected ||
        end?.data.reason.kind !== "completed" ||
        row.state !== "presented"
      )
        throw new Error("BB turn evidence incomplete");
      await this.flush();
      await this.checkpoint("turn-success");
      if (row.kind !== "download") {
        await this.client.call("chat/confirm_presentation", {
          attempt_id: row.attempt,
          request_digest: row.requestDigest,
          receipt_ids: [row.receiptId],
        });
        await this.checkpoint("confirmed");
        await this.check();
        const cursor = await this.client.call("chat/consumption", {
          account: row.peer,
        });
        if (cursor.consumed_through < row.position) {
          try {
            await this.client.call("chat/ack_messages", {
              account: row.peer,
              through_position: row.position,
            });
          } catch (error) {
            // A successful query can present a later position first. Keep its
            // durable proof, but let startup/observers/polling fill the gap.
            // Only this ACK conflict is deferrable; identity, ownership and
            // migration failures must still stop the caller.
            if (error.status === 409 && error.code === "consumption_gap")
              return;
            throw error;
          }
        }
        await this.checkpoint("acked");
      }
      await this.check();
      await this.journal.put({ ...row, state: "completed" });
    });
  }
  async findItem(row) {
    const page = await this.client.call("chat/read_messages", {
      account: row.peer,
      after_position: row.position - 1,
      limit: 1,
    });
    const item = page.items.find((x) => x.message.id === row.messageId);
    if (
      !item ||
      digest(item.message) !== row.messageDigest ||
      !item.presentation
    )
      throw new Error("BB source message unavailable");
    return item;
  }
  async recover() {
    const mismatches = this.journal
      .list()
      .filter(
        (row) =>
          row.state !== "completed" &&
          (row.session !== this.agent.session.id ||
            (row.sessionCreatedAt !== undefined &&
              row.sessionCreatedAt !== this.agent.session.header.createdAt)),
      );
    if (mismatches.length)
      throw Object.assign(
        new Error(
          "Original native session is required; unsettled work was not discarded",
        ),
        {
          code: "recovery_session_required",
          required_sessions: [...new Set(mismatches.map((r) => r.session))],
        },
      );
    await this.operations.reconcile();
    const unfinishedPlans = [...this.operations.rows.values()].filter(
      (row) =>
        !["succeeded", "failed"].includes(row.state) &&
        (row.session !== this.agent.session.id ||
          (row.sessionCreatedAt !== undefined &&
            row.sessionCreatedAt !== this.agent.session.header.createdAt)),
    );
    if (unfinishedPlans.length)
      throw Object.assign(
        new Error(
          "Original native session is required for unresolved operations",
        ),
        {
          code: "recovery_session_required",
          required_sessions: [
            ...new Set(unfinishedPlans.map((row) => row.session)),
          ],
        },
      );
    for (let row of this.journal
      .list()
      .sort((a, b) => a.position - b.position)) {
      if (row.state === "completed") continue;
      if (row.state === "dispatching" || row.state === "uncertain") {
        // The durable native turn can resolve a lost plugin observer update.
        const facts = this.agent.session.snapshotEvents();
        const end =
          row.session === this.agent.session.id &&
          facts.find(
            (e) =>
              e.type === "turn/end" &&
              e.data.turn === row.turn &&
              e.data.reason.kind === "completed",
          );
        const assistant =
          end &&
          facts.some(
            (e) => e.type === "assistant/message" && e.data.turn === row.turn,
          );
        row = await this.journal.put({
          ...row,
          state: assistant ? "presented" : "uncertain",
        });
        if (row.state === "uncertain") continue;
      }
      if (row.state === "presented") {
        const end = this.agent.session
          .snapshotEvents()
          .some(
            (e) =>
              e.type === "turn/end" &&
              e.data.turn === row.turn &&
              e.data.reason.kind === "completed",
          );
        if (row.session === this.agent.session.id && end)
          await this.settle(row);
        else await this.journal.put({ ...row, state: "uncertain" });
        continue;
      }
      const item =
        row.kind === "download"
          ? { message: row.event, blocks: [] }
          : await this.findItem(row);
      await this.serial(() =>
        this.resumeDelivery(row, item, { replacePending: true }),
      );
    }
  }
  async claimDownload(event, cursor) {
    const identity = this.client.identity;
    if (
      event.origin_identity.account !== identity.account ||
      event.origin_identity.consumer_id !== identity.consumer_id
    )
      return;
    const plan = [...this.operations.rows.values()].find(
      (p) => p.operation_id === event.operation_id,
    );
    if (!plan || plan.session !== this.agent.session.id) return;
    const fact = await this.client.call("downloads/get", {
      task_id: event.task_id,
    });
    if (!["succeeded", "failed"].includes(fact.status)) return;
    // Repair old metadata-only plans too, but only using a verified client fact.
    await this.serial(() =>
      this.operations.query({ ...plan, kind: "download" }, fact),
    );
    const key = digest(["download", event.event_id]);
    await this.serial(async () => {
      await this.check();
      const prior = this.journal.get(key);
      if (prior)
        return this.resumeDelivery(prior, { message: prior.event, blocks: [] });
      const row = {
        key,
        kind: "download",
        event: {
          platform: "BB",
          type: event.type,
          task_id: event.task_id,
          operation_id: event.operation_id,
          status: fact.status,
          actual_path: fact.actual_path,
          error_code: fact.error_code,
        },
        account: identity.account,
        consumer: identity.consumer_id,
        peer: "",
        position: cursor,
        messageId: event.event_id,
        imageCount: 0,
        session: this.agent.session.id,
        state: "claimed",
      };
      await this.flush();
      await this.journal.put(row);
      await this.resumeDelivery(row, { message: row.event, blocks: [] });
    });
  }
  async tick(peer) {
    await this.check();
    // Queries may present a later position before an earlier one. Retain its
    // proof and settle after the gap closes, without re-running the input.
    for (const row of this.journal
      .list()
      .filter((r) => r.state === "presented")
      .sort((a, b) => a.position - b.position)) {
      const completed = this.agent.session
        .snapshotEvents()
        .some(
          (e) =>
            e.type === "turn/end" &&
            e.data.turn === row.turn &&
            e.data.reason.kind === "completed",
        );
      if (completed) await this.settle(row);
    }
    const peers = [];
    if (peer) peers.push(peer);
    else {
      let after_account = "";
      for (;;) {
        const page = await this.client.call("chat/list_conversations", {
          after_account,
          limit: 100,
        });
        for (const c of page.items) peers.push(c.peer_account);
        if (!page.next_cursor) break;
        after_account = page.next_cursor;
      }
    }
    for (const target of peers) {
      await this.client.call("events/subscribe", { peer_account: target });
      await this.poll(target);
    }
    let after_cursor = 0;
    for (;;) {
      const page = await this.client.call("events/read", {
        after_cursor,
        limit: 100,
      });
      for (const { event, cursor } of page.items)
        if (event.type.startsWith("download."))
          await this.claimDownload(event, cursor);
      if (!page.has_more) break;
      after_cursor = page.next_cursor;
    }
  }
  async poll(peer) {
    if (
      !peer ||
      this.closed ||
      this.waiters.size ||
      this.operations.uncertain()
    )
      return;
    await this.observers;
    if (
      this.journal
        .list()
        .some((r) => r.state === "uncertain" || r.state === "dispatching")
    )
      return;
    const { consumed_through } = await this.client.call("chat/consumption", {
      account: peer,
    });
    const page = await this.client.call("chat/read_messages", {
      account: peer,
      after_position: consumed_through,
      limit: 50,
    });
    for (const item of page.items) {
      if (this.waiters.size) break;
      await this.claim(item);
    }
  }
  async drain() {
    await this.agent.whenIdle();
    await this.observers;
    await this.tail;
  }
  status() {
    return {
      identity: this.client.identity,
      operations: this.operations.status(),
      items: this.journal
        .list()
        .map(({ messageId, position, peer, state, kind }) => ({
          messageId,
          position,
          peer,
          state,
          kind: kind ?? "message",
        })),
      errors: [...this.errors],
    };
  }
  async close() {
    if (this.closed) return;
    this.closed = true;
    if (
      this.waiters.size ||
      this.operations.uncertain() ||
      this.journal
        .list()
        .some(
          (r) =>
            r.turn === this.turn &&
            ["dispatching", "prepared", "presented"].includes(r.state),
        )
    )
      this.agent.cancel({ kind: "user" }, { keepInbox: true });
    try {
      await this.drain();
      if (this.ctx.agents.get(this.agent.session.id) === this.agent)
        await this.agent.runMaintenance(async () => {
          for (const row of this.journal.list())
            if (row.nativeId) this.agent.inbox.remove(row.nativeId);
          await this.flush();
        });
    } finally {
      for (const dispose of this.operationDisposers ?? []) dispose();
      await this.fiber.dispose();
    }
  }
}
