import { digest } from "./store.js";

export const HISTORY_BUDGET = Object.freeze({
  messages: 8,
  text_bytes: 12288,
  images: 2,
  image_bytes: 2097152,
});
const bytes = (value) =>
  Buffer.byteLength(
    typeof value === "string" ? value : JSON.stringify(value),
    "utf8",
  );

// A bootstrap record contains identities/ranges/budgets, not a second message store.
// Historical content exists only in the host-owned native message projection.
export class History {
  constructor(bridge) {
    this.bridge = bridge;
  }
  async prepare(row) {
    const b = this.bridge,
      session = b.agent.session;
    if (row.kind === "download") return { content: [] };
    const sameSession = (meta) =>
      meta?.session_id === session.id &&
      meta.session_created_at === session.header.createdAt &&
      meta.peer_account === row.peer;
    const previous = b.journal
      .list()
      .find((r) => r.key !== row.key && sameSession(r.bootstrap));
    if (previous) return { content: [] };
    const existing = sameSession(row.bootstrap) ? row.bootstrap : undefined;
    const consumed =
      existing?.consumed_through ??
      (await b.client.call("chat/consumption", { account: row.peer }))
        .consumed_through;
    const page = await b.client.call("chat/get_context", {
      message_id: row.messageId,
      before_limit: HISTORY_BUDGET.messages,
      after_limit: 0,
    });
    if (
      page.peer_account !== row.peer ||
      page.anchor_message_id !== row.messageId
    )
      throw new Error("Context anchor mismatch");
    const candidates = page.items.filter(
      (i) => i.message.position < row.position,
    );
    const selected = [],
      omitted = [],
      missingMedia = new Set(page.missing_media_ids ?? []);
    let textBytes = 0,
      imageBytes = 0,
      imageCount = 0;
    // Prefer the nearest complete messages, then restore chronological order.
    for (const item of [...candidates].reverse()) {
      const m = item.message;
      if (m.position > consumed) {
        omitted.push({
          message_id: m.id,
          position: m.position,
          reason: "unconsumed_not_history",
        });
        continue;
      }
      const metadata = {
        id: m.id,
        position: m.position,
        sender_account: m.sender_account,
        target_account: m.target_account,
        created_at: m.created_at,
        kind: m.kind,
      };
      const cost =
        bytes(metadata) +
        item.blocks
          .filter((x) => x.type === "text")
          .reduce((n, x) => n + bytes(x.text), 0);
      if (textBytes + cost > HISTORY_BUDGET.text_bytes) {
        omitted.push({
          message_id: m.id,
          position: m.position,
          reason: "text_budget",
        });
        continue;
      }
      textBytes += cost;
      const blocks = [],
        mediaIds = (m.content ?? [])
          .filter((x) => x.type === "image")
          .map((x) => x.media_id);
      let imageIndex = 0;
      for (const [block_index, block] of item.blocks.entries()) {
        if (block.type !== "image") {
          blocks.push(block);
          continue;
        }
        const media_id =
          mediaIds[imageIndex++] ?? m.attachment?.cover_media_id ?? null;
        const size = Buffer.from(block.data, "base64").length;
        if (
          imageCount >= HISTORY_BUDGET.images ||
          imageBytes + size > HISTORY_BUDGET.image_bytes
        ) {
          omitted.push({
            message_id: m.id,
            position: m.position,
            media_id,
            block_index,
            reason: "image_budget",
          });
          continue;
        }
        imageCount++;
        imageBytes += size;
        blocks.push(block);
      }
      // History media can be unavailable without pretending it was displayed.
      // Incremental message media still uses the bridge's strict receipt gate.
      let content;
      try {
        content = await b.content({ message: metadata, blocks });
      } catch (error) {
        if (!blocks.some((x) => x.type === "image")) throw error;
        omitted.push({
          message_id: m.id,
          position: m.position,
          reason: "historical_image_unavailable",
        });
        content = await b.content({
          message: metadata,
          blocks: blocks.filter((x) => x.type !== "image"),
        });
      }
      selected.push({ message_id: m.id, position: m.position, content });
    }
    selected.reverse();
    omitted.sort((a, c) => a.position - c.position);
    const metadata = {
      version: 1,
      session_id: session.id,
      session_created_at: session.header.createdAt,
      peer_account: row.peer,
      anchor_message_id: row.messageId,
      consumed_through: consumed,
      budget: HISTORY_BUDGET,
      // Reservations may exceed the final projection after omission/fallback.
      reserved_usage: {
        text_bytes: textBytes,
        images: imageCount,
        image_bytes: imageBytes,
      },
      included: selected.map(({ message_id, position }) => ({
        message_id,
        position,
      })),
      omitted: omitted.slice(0, 8),
      omitted_count: omitted.length,
      omitted_details_truncated: omitted.length > 8,
      range: page.range,
      before_has_more: page.before_has_more,
      missing_positions: page.missing_positions,
      missing_truncated: page.missing_truncated,
      missing_media_ids: [...missingMedia].slice(0, 16),
      missing_media_details_truncated: missingMedia.size > 16,
      reply_relations: page.reply_relations,
      continuation: {
        context: {
          tool: "get_context",
          message_id: row.messageId,
          before_limit: 49,
          after_limit: 0,
        },
        older: {
          tool: "read_messages",
          account: row.peer,
          before_position: page.range.start_position,
          limit: 50,
        },
        exact: {
          tool: "get_message",
          message_ids: [...new Set(omitted.map((x) => x.message_id))],
        },
      },
    };
    // This marker and the increment share one durable native message/attempt.
    const render = () => [
      {
        type: "text",
        text: JSON.stringify({
          platform: "BB",
          kind: "history_context",
          context_only: true,
          not_new_tasks: true,
          ...metadata,
        }),
      },
      ...selected.flatMap((x) => x.content),
      {
        type: "text",
        text: "BB history_context ends; the following message is the current incremental input.",
      },
    ];
    let content = render();
    while (
      content.reduce((n, x) => n + (x.type === "text" ? bytes(x.text) : 0), 0) >
      HISTORY_BUDGET.text_bytes
    ) {
      const removed = selected.shift();
      if (!removed) throw new Error("Context metadata exceeds its hard budget");
      omitted.push({
        message_id: removed.message_id,
        position: removed.position,
        reason: "total_text_budget",
      });
      metadata.included = selected.map(({ message_id, position }) => ({
        message_id,
        position,
      }));
      metadata.omitted = omitted.slice(0, 8);
      metadata.omitted_count = omitted.length;
      metadata.omitted_details_truncated = omitted.length > 8;
      metadata.continuation.exact.message_ids = [
        ...new Set(omitted.map((x) => x.message_id)),
      ];
      content = render();
    }

    return {
      metadata: { ...metadata, projection_digest: digest(content) },
      content,
    };
  }
}
