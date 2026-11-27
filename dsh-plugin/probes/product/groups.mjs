import assert from "node:assert/strict";

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
    "mark_notice_read", "execute_notice_action",
  ]) assert.ok(tools.has("mcp__bb__" + name), name);
  for (const name of ["events_read", "notification_changes", "confirm_presentation"])
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
  const invitation = (await invoke("list_notices", {filter: "pending"})).items.find(
    ({link}) => link?.id === remoteGroup.group_number,
  );
  assert.ok(invitation?.actions.length);
  const digest = () => modelRequests.flat()
    .filter(m => m.id?.startsWith("bb-notice-"))
    .map(m => JSON.parse(m.content[0].text));
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

  const membershipChange = await post("/chat/groups/remove_member", {
    conversation, account: client.account,
  }, token);
  assert.equal(membershipChange.conversation.id, conversation.id);
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
    isolated_accounts: 3,
    real_routes: ["FastAPI", "independent Dart", "installed DSH MCP"],
    notice_action_and_read_independent: true,
    group_history_boundary: true,
    group_media_order: true,
    revoked_history_access: true,
    rejoined_only_current_previews: true,
    provider: "deterministic double",
  };
}
