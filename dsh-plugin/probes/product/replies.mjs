import assert from "node:assert/strict";

export async function probeReplies({client, ctx, tool, executeTool, settings, until}) {
  const invoke = (name, args) => tool("mcp__bb__" + name, args);
  async function post(path, body, token) {
    const response = await fetch(client.api + path, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: "Bearer " + token } : {}),
      },
      body: JSON.stringify(body),
    });
    const value = await response.json();
    assert.equal(response.status, 200, path + " " + (value.error?.code ?? ""));
    return value;
  }
  async function login(account) {
    return (await post("/auth/login", {account, password: "Abc123"})).token;
  }
  async function denied(name, args, expected) {
    const result = await executeTool("mcp__bb__" + name, args);
    assert.ok(result.isError || result.value?.isError, name);
    const value = result.value?.structuredContent ??
      JSON.parse(result.content[0].text.replace(/^Error:\s*/, ""));
    assert.equal(value.error?.code, expected);
  }
  const text = (value) => [{ type: "text", text: value }];
  const send = (token, nonce, body) => post("/messages", {
    client_nonce: nonce, content: text(nonce), ...body,
  }, token);
  const replyArgs = (conversation, original, nonce) => ({
    conversation, reply_to_message_id: original.id,
    operation_id: nonce, content: text(nonce),
  });
  const query = { conversation_id: "dm:" + [client.account, client.peer].sort().join(":") };
  const direct = { type: "direct", id: query.conversation_id };
  const own = await login(client.account);
  const peer = await login(client.peer);
  const outsider = await login(client.outsider);
  await settings({clientUrl: client.origin, targetSession: "installed-product", pollMs: 250});
  await until(async () => (await tool("bb_bridge_status")).state === "bound");
  const registered = new Set(ctx.tools.schemas().map(({name}) => name));
  for (const name of ["send_reply", "list_unread_replies", "list_direct_replies"]) {
    assert.ok(registered.has("mcp__bb__" + name), name);
  }

  const original = await send(own, "native-original", {target_account: client.peer});
  const received = await send(peer, "native-received", {
    target_account: client.account, reply_to_message_id: original.id,
  });
  const outboundArgs = replyArgs(direct, received, "native-outbound");
  const outbound = await invoke("send_reply", outboundArgs);
  assert.equal(outbound.reply_to.message_id, received.id);
  assert.equal((await invoke("send_reply", outboundArgs)).id, outbound.id);
  assert.equal((await invoke("get_operation", {operation_id: outboundArgs.operation_id})).message.id,
    outbound.id);
  assert.deepEqual((await invoke("list_unread_replies", query)).items.map(
    ({reply, original: anchor}) => [reply.id, anchor.id]), [[received.id, original.id]]);
  const rows = await invoke("list_unread_mention_groups", {});
  assert.deepEqual(rows.items.map(row => [row.conversation_id, row.unread_mention_count, row.unread_reply_count]),
    [[direct.id, 0, 1]]);
  assert.deepEqual((await invoke("list_direct_replies", {original_message_id: original.id})).items.map(
    ({id}) => id), [received.id]);
  assert.equal((await invoke("list_unread_replies", query)).items.length, 1);
  assert.deepEqual(await post("/chat/alerts/mark_seen", {...query, message_ids: [received.id]}, own),
    {unread_mention_count: 0, unread_reply_count: 0});
  assert.deepEqual(await invoke("list_unread_replies", query), {items: [], next_cursor: null});

  const group = await post("/chat/groups/create", {
    name: "Native reply group", operation_id: "native-group", invitees: [client.account],
  }, peer);
  const notices = await invoke("list_notices", {filter: "pending"});
  const invitation = notices.items.find(({link}) => link?.id === group.group_number);
  assert.ok(invitation?.actions.some(({id, available}) => id === "accept" && available));
  await invoke("execute_notice_action", {notification_id: invitation.id, action_id: "accept"});
  const groupAnchor = await send(own, "native-group-anchor", {conversation: group.conversation});
  const mixed = await send(peer, "native-mixed-alert", {
    conversation: group.conversation,
    reply_to_message_id: groupAnchor.id,
    mentioned_accounts: [client.account],
  });
  const groupQuery = {conversation_id: group.conversation.id};
  const combined = (await invoke("list_unread_mention_groups", {})).items;
  assert.deepEqual(combined.map(({conversation_id, unread_mention_count, unread_reply_count}) =>
    [conversation_id, unread_mention_count, unread_reply_count]), [[group.conversation.id, 1, 1]]);
  assert.equal((await invoke("list_unread_replies", groupQuery)).items[0].reply.id, mixed.id);
  assert.deepEqual((await post("/chat/alerts/list", groupQuery, own)).items, [{
    message_id: mixed.id, position: mixed.position, mention: true, reply: true,
  }]);
  assert.deepEqual(await post("/chat/alerts/mark_seen", {...groupQuery, message_ids: [mixed.id]}, own),
    {unread_mention_count: 0, unread_reply_count: 0});
  assert.deepEqual(await invoke("list_unread_replies", groupQuery), {items: [], next_cursor: null});
  assert.equal((await invoke("list_direct_replies", {original_message_id: groupAnchor.id})).items[0].id,
    mixed.id);
  const privateMessage = await send(outsider, "native-private", {target_account: client.peer});
  await denied("list_direct_replies", {original_message_id: privateMessage.id}, "not_found");
  await denied("send_reply", replyArgs(group.conversation, received, "native-cross"), "not_found");
  const groupOriginal = await send(peer, "native-group-original", {conversation: group.conversation});
  const sent = await invoke("send_reply", replyArgs(group.conversation, groupOriginal, "native-group-reply"));
  assert.equal(sent.reply_to.message_id, groupOriginal.id);
  assert.deepEqual((await invoke("list_direct_replies", {original_message_id: groupOriginal.id})).items.map(
    ({id}) => id), [sent.id]);
  const incoming = await post("/chat/replies/unread", {conversation_id: group.conversation.id}, peer);
  assert.deepEqual(incoming.items.map(({reply}) => reply.id), [sent.id]);

  return {
    installed_dsh_reply_tools: "PASS",
    scopes: ["direct", "group"],
    isolated_accounts: 3,
    quote_lookup_deduplication_and_no_read_side_effect: true,
    mixed_alert_clear_by_exact_message_id: true,
    cross_conversation_send_and_private_lookup_denied: true,
    real_routes: ["FastAPI", "independent Dart", "installed DSH MCP"],
    provider: "deterministic double",
  };
}
