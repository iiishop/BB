import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";

export async function probeGroups({client, ctx, tool, executeTool, settings, until, modelRequests}) {
  async function post(path, data, token, expected = 200) {
    const response = await fetch(client.api + path, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? {Authorization: "Bearer " + token} : {}),
      },
      body: JSON.stringify(data),
    });
    const payload = await response.json();
    assert.equal(response.status, expected, path + " " + (payload.error?.code ?? ""));
    return payload;
  }
  const invoke = (name, input) => tool("mcp__bb__" + name, input);
  async function denied(name, input, codes) {
    const result = await executeTool("mcp__bb__" + name, input);
    assert.ok(result.isError || result.value?.isError, name);
    const code = result.value?.structuredContent?.error?.code ??
      JSON.parse(result.content[0].text.replace(/^Error:\s*/, "")).error?.code;
    assert.ok(codes.includes(code), name + " " + code);
  }
  await settings({
    clientUrl: client.origin, targetSession: "installed-product", pollMs: 250,
  });
  await until(async () => (await tool("bb_bridge_status")).state === "bound");
  const tools = new Set(ctx.tools.schemas().map(({name}) => name));
  for (const name of [
    "create_group", "find_group", "update_group", "list_directory",
    "list_group_members", "invite_to_group", "apply_to_group", "leave_group",
    "remove_group_member", "dissolve_group", "list_notices",
    "mark_notice_read", "execute_notice_action", "list_unread_mention_groups",
    "list_unread_mentions", "send_group_mention",
  ]) assert.ok(tools.has("mcp__bb__" + name), name);
  for (const name of ["events_read", "notification_changes", "confirm_presentation", "mark_mentions_seen"])
    assert.ok(!tools.has("mcp__bb__" + name), name);

  const ownIntent = {operation_id: "group-create-own", name: "Local-created group"};
  const own = await invoke("create_group", ownIntent);
  assert.equal(own.role, "owner");
  assert.equal((await invoke("create_group", ownIntent)).conversation.id, own.conversation.id);
  assert.equal((await invoke("find_group", {group_number: own.group_number})).name, own.name);
  assert.ok((await invoke("list_directory")).items.some(({account}) => account === client.peer));
  const ownMembers = await invoke("list_group_members", {conversation: own.conversation});
  assert.deepEqual(ownMembers.items.map(({account}) => account), [client.account]);

  const {token} = await post("/auth/login", {account: client.peer, password: "Abc123"});
  const digest = () => modelRequests.flat()
    .filter(m => m.id?.startsWith("bb-notice-"))
    .map(m => JSON.parse(m.content[0].text));
  const rejectedGroup = await post("/chat/groups/create", {
    name: "Resolved during collection", operation_id: "group-counts-rejected", invitees: [client.account],
  }, token);
  const rejectedInvite = (await invoke("list_notices", {filter: "pending"})).items.find(
    ({link}) => link?.id === rejectedGroup.group_number,
  );
  assert.ok(rejectedInvite);
  const journalDir = resolve(process.env.DSH_HOME, "../profile/.bb-bridge/notifications");
  await until(async () => {
    for (const file of await readdir(journalDir)) {
      if (!file.endsWith(".json")) continue;
      const {batch} = JSON.parse(await readFile(resolve(journalDir, file), "utf8"));
      if (batch?.state === "collecting" &&
          batch.businessNotices?.last_notice.notification_id === rejectedInvite.id) return true;
    }
    return false;
  });
  await invoke("mark_notice_read", {notification_id: rejectedInvite.id});
  await invoke("execute_notice_action", {notification_id: rejectedInvite.id, action_id: "reject"});
  const current = await invoke("list_notices");
  assert.deepEqual([current.unread_count, current.pending_count], [0, 0]);
  const rejectedSummary = () => digest().find(item =>
    item.business_notices?.last_notice.notification_id === rejectedInvite.id);
  assert.ok(!rejectedSummary(), "actions completed before delivery");
  await until(async () => !!rejectedSummary());
  const {new_count, unread_count, pending_count} = rejectedSummary().business_notices;
  assert.deepEqual([new_count, unread_count, pending_count],
    [1, 0, 0], "model counts must match resolved invitation");

  const remoteGroup = await post("/chat/groups/create", {
    name: "Owner-created group", operation_id: "group-create-other", invitees: [client.account],
  }, token);
  const conversation = remoteGroup.conversation;
  const sendPeer = (id, text) => post("/messages", {
    conversation, client_nonce: id, content: [{type: "text", text}],
  }, token);
  const old = await sendPeer("group-history-before-join", "before membership");
  await denied("list_group_members", {conversation}, ["forbidden", "not_found"]);
  await denied("read_messages", {conversation}, ["forbidden", "not_found"]);
  const mentionQuery = {conversation_id: conversation.id};
  await denied("list_unread_mentions", mentionQuery, ["not_found"]);
  const invitation = (await invoke("list_notices", {filter: "pending"})).items.find(
    ({link}) => link?.id === remoteGroup.group_number,
  );
  assert.ok(invitation?.actions.length);
  await until(async () => digest().some(item =>
    item.business_notices?.last_notice.notification_id === invitation.id));
  const marked = await invoke("mark_notice_read", {notification_id: invitation.id});
  assert.equal(marked.read, true);
  assert.equal(marked.state, "pending");
  assert.ok((await invoke("list_notices", {filter: "pending"})).items.some(
    ({id}) => id === invitation.id));
  const accept = invitation.actions.find(({id, available}) => id === "accept" && available);
  assert.ok(accept, "active invitation accept action");
  const resolved = await invoke("execute_notice_action", {
    notification_id: invitation.id, action_id: accept.id,
  });
  assert.equal(resolved.state, "processed");
  assert.ok(!(await invoke("list_notices", {filter: "pending"})).items.some(
    ({id}) => id === invitation.id));

  const rows = await invoke("list_conversations");
  const group = rows.items.find(row => row.conversation.id === conversation.id);
  assert.equal(group.group_number, remoteGroup.group_number);
  assert.equal((await invoke("find_group", {group_number: group.group_number})).conversation.id,
    conversation.id);
  assert.equal(group.incoming_unread, 0);
  assert.ok(group.history_through >= old.position);
  const history = await invoke("read_messages", {conversation, after_position: 0});
  assert.ok(history.items.some(({message}) => message.id === old.id));
  assert.equal((await invoke("read_messages", {conversation, unread_only: true})).items.length, 0);
  const fresh = await sendPeer("group-history-after-join", "after membership");
  await until(async () => digest().some(item => item.conversations.some(row =>
    row.conversation.id === conversation.id &&
    row.last_message.message_id === fresh.id &&
    row.membership_revision === group.membership_revision)));
  const ownMessage = await invoke("send_message", {
    conversation, content: [
      {type: "text", text: "before image"},
      {type: "image", source: {base64: client.images[0], mime_type: "image/png", filename: "red.png"}},
      {type: "text", text: "after image"},
    ],
  });
  assert.equal(ownMessage.conversation.id, conversation.id);
  const got = await invoke("get_message", {message_id: ownMessage.id});
  assert.deepEqual(got.item.blocks.map(({type}) => type), ["text", "image", "text"]);
  const around = await invoke("get_context", {message_id: ownMessage.id});
  assert.equal(around.conversation.id, conversation.id);
  assert.ok(around.items.some(({message}) => message.id === fresh.id));

  const {token: recipientToken} = await post("/auth/login", {
    account: client.account, password: "Abc123",
  });
  const sendMention = id => post("/messages", {
    conversation, client_nonce: id,
    mentioned_accounts: [client.account],
    content: [{type: "text", text: "@ recipient " + id}],
  }, token);
  const olderMention = await sendMention("mention-older");
  const middleMention = await sendMention("mention-middle");
  const newestMention = await sendMention("mention-newest");
  await sendPeer("mention-plain-text", "@ recipient");
  const replyOnly = await post("/messages", {
    target_account: client.account, client_nonce: "synthetic-direct-reply",
    content: [{type: "text", text: "Reply-only fixture"}],
  }, token);
  const directId = "dm:" + [client.account, client.peer].sort().join(":");
  // DEA-519 supplies the reply send route. Seed its two shared writer calls
  // here, then exercise the actual installed tool and visible-ID acknowledgement.
  const {python, database} = client.replyFixture;
  execFileSync(python, ["-c", [
    "from pathlib import Path",
    "from sys import argv",
    "from bb_server.chat_alerts import record_reply",
    "from bb_server.storage import connection",
    "database, group, middle, direct, reply, sender, recipient = argv[1:]",
    "with connection(Path(database), write=True) as db:",
    "    record_reply(db, group, int(middle), sender, recipient)",
    "    record_reply(db, direct, int(reply), sender, recipient)",
  ].join("\n"), database, conversation.id, String(middleMention.position),
  directId, String(replyOnly.position), client.peer, client.account]);
  const mentionGroups = args => invoke("list_unread_mention_groups", args);
  const mentionPage = args => invoke("list_unread_mentions", {...mentionQuery, ...args});
  const groupSummary = (mentions, replies) => ({
    conversation_id: conversation.id, display_name: remoteGroup.name,
    unread_mention_count: mentions, unread_reply_count: replies,
  });
  const directSummary = {
    conversation_id: directId, display_name: newestMention.sender_username,
    unread_mention_count: 0, unread_reply_count: 1,
  };
  const summary = () => [directSummary, groupSummary(3, 1)];
  assert.deepEqual(await mentionGroups(), {items: summary(), next_cursor: null});
  const firstSummaryPage = await mentionGroups({limit: 1});
  assert.deepEqual(firstSummaryPage, {items: [directSummary], next_cursor: directId});
  assert.deepEqual(await mentionGroups({after_conversation_id: firstSummaryPage.next_cursor}),
    {items: [groupSummary(3, 1)], next_cursor: null});
  const page = await mentionPage({limit: 1});
  assert.deepEqual(page.items, [{
    message_id: newestMention.id, position: newestMention.position,
    sender_account: client.peer, sender_username: newestMention.sender_username,
    created_at: newestMention.created_at, content: newestMention.content,
  }]);
  assert.deepEqual((await mentionPage({before_position: page.next_cursor})).items.map(
    ({message_id}) => message_id), [middleMention.id, olderMention.id]);
  const combined = await post("/chat/alerts/list", mentionQuery, recipientToken);
  assert.deepEqual(combined.items.map(({message_id, mention, reply}) =>
    [message_id, mention, reply]), [
    [newestMention.id, true, false], [middleMention.id, true, true],
    [olderMention.id, true, false],
  ]);
  await invoke("get_context", {message_id: middleMention.id});
  assert.deepEqual((await mentionGroups()).items, summary());
  const seen = (id, ...messageIds) => post("/chat/alerts/mark_seen", {
    conversation_id: id, message_ids: messageIds,
  }, recipientToken);
  assert.deepEqual(await seen(conversation.id, middleMention.id),
    {unread_mention_count: 2, unread_reply_count: 0});
  assert.deepEqual((await mentionGroups()).items, [directSummary, groupSummary(2, 0)]);
  assert.deepEqual((await mentionPage({})).items.map(
    ({message_id}) => message_id), [newestMention.id, olderMention.id]);
  assert.deepEqual(await seen(conversation.id, newestMention.id),
    {unread_mention_count: 1, unread_reply_count: 0});
  assert.deepEqual((await mentionPage({})).items.map(({message_id}) => message_id),
    [olderMention.id]);
  assert.deepEqual(await seen(conversation.id, olderMention.id),
    {unread_mention_count: 0, unread_reply_count: 0});
  assert.deepEqual(await mentionPage({}), {items: [], next_cursor: null});
  assert.deepEqual((await mentionGroups()).items, [directSummary]);
  assert.deepEqual(await seen(directId, replyOnly.id),
    {unread_mention_count: 0, unread_reply_count: 0});
  assert.deepEqual(await mentionGroups(), {items: [], next_cursor: null});

  await denied("send_group_mention", {
    conversation, mentioned_accounts: [client.outsider],
    content: [{type: "text", text: "Account outside group"}],
  }, ["validation_error"]);
  const sent = await invoke("send_group_mention", {
    conversation, mentioned_accounts: [client.peer],
    content: [
      {type: "text", text: "@ selected account"},
      {type: "image", source: {
        base64: client.images[0], mime_type: "image/png", filename: "mention.png",
      }},
      {type: "text", text: "after image"},
    ],
  });
  assert.equal(sent.sender_account, client.account);
  const receivedMention = (await post("/chat/mentions/list", mentionQuery, token)).items[0];
  assert.equal(receivedMention.message_id, sent.id);
  assert.deepEqual(receivedMention.content, sent.content);
  assert.deepEqual(receivedMention.content.map(({type}) => type), ["text", "image", "text"]);
  assert.equal((await invoke("get_operation", {operation_id: sent.operation_id})).message.id,
    sent.id);
  assert.deepEqual(await mentionPage({}), {items: [], next_cursor: null});
  await sendMention("mention-before-leave");

  const membershipChange = await post("/chat/groups/remove_member", {
    conversation, account: client.account,
  }, token);
  assert.equal(membershipChange.conversation.id, conversation.id);
  await denied("list_unread_mentions", mentionQuery, ["not_found"]);
  assert.deepEqual(await mentionGroups(), {items: [], next_cursor: null});
  await denied("read_messages", {conversation, after_position: 0}, ["forbidden", "not_found"]);
  await denied("get_message", {message_id: ownMessage.id}, ["forbidden", "not_found"]);
  assert.ok(!(await invoke("list_conversations")).items.some(
    row => row.conversation.id === conversation.id));
  await invoke("apply_to_group", {conversation});
  const ownerPending = await post("/chat/notices/list", {filter: "pending"}, token);
  const application = ownerPending.items.find(({link}) => link?.id === group.group_number);
  assert.ok(application?.actions.length);
  const approve = application.actions.find(({id, available}) => id === "approve" && available);
  assert.ok(approve);
  const modelStart = modelRequests.length;
  await post("/chat/notices/execute_action", {notification_id: application.id, action_id: approve.id}, token);
  const rejoined = (await invoke("list_conversations")).items.find(
    row => row.conversation.id === conversation.id);
  assert.ok(rejoined.membership_revision > group.membership_revision);
  assert.equal(rejoined.incoming_unread, 0);
  assert.ok(rejoined.history_through >= ownMessage.position);
  assert.deepEqual(await mentionPage({}), {items: [], next_cursor: null});
  const next = await sendPeer("group-history-after-rejoin", "after rejoin");
  function projectedGroups() {
    return modelRequests.slice(modelStart).flat()
      .filter(message => message.id?.startsWith("bb-notice-"))
      .flatMap(message => JSON.parse(message.content[0].text).conversations)
      .filter(row => row.conversation.id === conversation.id);
  }
  await until(async () => projectedGroups().some(
    row => row.last_message.message_id === next.id));
  assert.ok(projectedGroups().every(row =>
    row.membership_revision === rejoined.membership_revision));
  await invoke("dissolve_group", {conversation: own.conversation});
  assert.equal((await invoke("find_group", {group_number: own.group_number})).status, "dissolved");
  return {
    groups: "PASS",
    unread_mention_tools: "PASS",
    send_group_mention: "PASS",
    mixed_alerts_via_shared_reply_writer_fixture: "PASS",
    isolated_accounts: 3,
    real_routes: ["FastAPI", "independent Dart", "installed DSH MCP"],
    notice_action_and_read_independent: true,
    notice_counts_refreshed_before_delivery: [new_count, unread_count, pending_count],
    group_history_boundary: true,
    group_media_order: true,
    revoked_history_access: true,
    rejoined_only_current_previews: true,
    provider: "deterministic double",
  };
}
