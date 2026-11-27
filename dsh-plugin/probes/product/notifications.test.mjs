// Deterministic state-machine tests; stock-host evidence is a separate live probe.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Notifications } from '../../bundle/notifications.js';

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'bb-notices-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const f = { now: 0, settings: {enabled:true,revision:1}, events: [], sent: [], calls: [], requests: [], failedPeers: new Set(), fail: null };
  const agent = { status:'idle', session:{id:'s',header:{createdAt:1},snapshotEvents:()=>[]},
    inbox:{nextTurn:[],nextStep:[]}, runMaintenance:async fn=>fn(), followup:m=>{ f.sent.push(m); agent.inbox.nextTurn.push(m); } };
  const bridge = {root, agent, check:async()=>{}, flush:async()=>{}, checkpoint:async name=>{if(f.fail===name)throw Error(name);},
    client: { identity:{account:'10000001',consumer_id:'c'}, call:async(path,args)=>{
      f.calls.push(path);
      if(path==='notifications/get')return {...f.settings};
      assert.equal(path,'notifications/changes');
      f.requests.push(structuredClone(args));
      const head=args.through_cursor??f.events.length;
      // Match the real Dart range contract even while notifications are off.
      assert.ok(args.after_cursor>=0 && head>=args.after_cursor && head<=f.events.length);
      const retries=args.retry_cursors??[];
      assert.ok(retries.length<=100 && retries.every(c=>Number.isInteger(c)&&c>=1&&c<=args.after_cursor), 'retry cursor must be within scanned history');
      const next=Math.min(head,args.after_cursor+args.limit);
      const cursors=[...Array.from({length:next-args.after_cursor},(_,i)=>args.after_cursor+i+1),...new Set(retries)];
      const visible=f.settings.enabled?cursors.filter(c=>c>(f.settings.skip_source_through??0)):[];
      const deferred=visible.filter(c=>f.failedPeers.has(f.events[c-1].peer_account)).map(c=>({cursor:c,peer_account:f.events[c-1].peer_account,error_code:'upstream_unavailable'}));
      return { settings:{...f.settings},items:visible.filter(c=>!f.failedPeers.has(f.events[c-1].peer_account)).map(c=>f.events[c-1]), deferred, next_cursor:next, through_cursor:head,has_more:next<head };
    }} };
  f.add = (peer='10000002') => f.events.push({conversation:{type:'direct',id:peer},peer_account:peer,display_name:peer,new_count:1,incoming_unread:5,last_message:{position:f.events.length+1,preview:'untrusted'}});
  f.open=async()=>{f.n=new Notifications(bridge,{now:()=>f.now});await f.n.open();return f.n;};
  f.bridge=bridge;await f.open();return f;
}
test('fixed window aggregates peers, never queries body or confirms, and does not replay',async t=>{
 const f=await fixture(t);f.add();await f.n.tick();f.now=500;f.add('10000003');await f.n.tick();assert.equal(f.sent.length,0);
 f.now=1000;f.add();await f.n.tick();assert.equal(f.sent.length,1);
 const value=JSON.parse(f.sent[0].content[0].text);assert.equal(value.conversations.length,2);assert.equal(value.conversations[0].new_count,2);
 assert.equal(f.n.state.cursor,3);await f.open();await f.n.tick();assert.equal(f.sent.length,1);
 assert.ok(f.calls.every(x=>x.startsWith('notifications/')));
});
test('disabled window is skipped; enable revokes pending aggregation',async t=>{
 const f=await fixture(t);f.add();await f.n.tick();f.settings={enabled:false,revision:2};f.now=2000;await f.n.tick();assert.equal(f.sent.length,0);assert.equal(f.n.state.cursor,1);
 f.add();await f.n.tick();f.settings={enabled:true,revision:3};await f.n.tick();assert.equal(f.sent.length,0);
 f.add();await f.n.tick();f.now+=1000;await f.n.tick();assert.equal(f.sent.length,1);assert.equal(JSON.parse(f.sent[0].content[0].text).conversations[0].new_count,1);
});
test('page cap preserves backlog snapshot across cold open and sends one batch',async t=>{
 const f=await fixture(t);for(let i=0;i<1001;i++)f.add();await f.n.tick();assert.equal(f.n.state.batch.scanned,1000);assert.equal(f.sent.length,0);
 await f.open();f.now=2000;await f.n.tick();assert.equal(f.sent.length,1);assert.equal(JSON.parse(f.sent[0].content[0].text).conversations[0].new_count,1001);
});
for(const cut of ['notification-prepared','notification-dispatching','notification-pending','notification-committed'])test(`restart at ${cut} reconciles native evidence without blind replay`,async t=>{
 const f=await fixture(t);f.add();await f.n.tick();f.now=1000;f.fail=cut;await assert.rejects(f.n.tick(),new RegExp(cut));f.fail=null;await f.open();await f.n.tick();
 {assert.equal(f.sent.length,1);assert.equal(f.n.state.cursor,1);await f.n.tick();assert.equal(f.sent.length,1);}
});
test('final admission rejects owner/settings changes',async t=>{
 const f=await fixture(t);f.add();await f.n.tick();f.now=1000;
 f.bridge.checkpoint=async n=>{if(n==='notification-dispatching')f.settings={enabled:false,revision:2};};
 await f.n.tick();assert.equal(f.sent.length,0);await f.n.tick();assert.equal(f.n.state.cursor,1);
});

test('deferred peer survives cold open and resolves once while other peers advance',async t=>{
 const f=await fixture(t);f.failedPeers.add('10000002');
 f.add();f.add("10000003");await f.n.tick();f.now=1000;await f.n.tick();
 assert.equal(f.sent.length,1);assert.equal(JSON.parse(f.sent[0].content[0].text).conversations[0].peer_account,"10000003");
 await f.open();assert.equal(f.n.state.deferred.length,1);f.failedPeers.clear();await f.n.tick();f.now+=1000;await f.n.tick();
 assert.equal(f.sent.length,2);assert.equal(JSON.parse(f.sent[1].content[0].text).conversations[0].peer_account,"10000002");
 assert.deepEqual(f.n.state.deferred,[]);await f.n.tick();assert.equal(f.sent.length,2);
});

for (const initial of [undefined, '10000002']) for (const cold of [false, true]) test(`scope change filters entire collecting batch: ${initial ?? 'discovery'}, cold=${cold}`, async t=>{
 const f=await fixture(t);f.add();f.add('10000003');await f.n.tick(initial);
 if(cold)await f.open();f.now=1000;await f.n.tick('10000003');
 if(initial) { f.add('10000003');await f.n.tick('10000003');f.now+=1000;await f.n.tick('10000003'); }
 assert.equal(f.sent.length,1);assert.deepEqual(JSON.parse(f.sent[0].content[0].text).conversations.map(c=>c.peer_account),['10000003']);
});
test('scope changes during final admission are rechecked for the existing batch', async t=>{
 const f=await fixture(t);let scope=null;f.n.scope=()=>scope;
 f.add();f.add('10000003');await f.n.tick();f.now=1000;
 f.bridge.checkpoint=async name=>{if(name==='notification-dispatching')scope='10000003';};
 await f.n.tick();assert.deepEqual(JSON.parse(f.sent[0].content[0].text).conversations.map(c=>c.peer_account),['10000003']);
});
test('legacy unknown remains protected, explicit disable abandons it and new changes can progress',async t=>{
 const f=await fixture(t);f.add();await f.n.tick();
 await f.n.save({...f.n.state,batch:{...f.n.state.batch,deliveryProtocol:undefined,state:'dispatching'}});
 f.now=1000;await f.open();await f.n.tick();assert.equal(f.sent.length,0);assert.equal(f.n.state.batch.state,'uncertain');
 f.settings={enabled:false,revision:2};await f.n.tick();assert.equal(f.n.state.abandoned.length,1);
 f.settings={enabled:true,revision:3};f.add('10000003');await f.n.tick();f.now=2000;await f.n.tick();
 assert.equal(f.sent.length,1);assert.equal(JSON.parse(f.sent[0].content[0].text).conversations[0].peer_account,'10000003');
 assert.equal(f.n.state.abandoned[0].state,'abandoned_by_settings');
});
test('protocol-2 unknown in live driver claim/projection gap is not replayed',async t=>{
 const f=await fixture(t);f.add();await f.n.tick();await f.n.save({...f.n.state,batch:{...f.n.state.batch,state:'dispatching'}});
 f.bridge.agent.status='running';f.now=1000;await f.n.tick();assert.equal(f.sent.length,0);
 f.bridge.agent.status='idle';await f.n.tick();assert.equal(f.sent.length,1);
});
test('provider barrier rejects failed persistence before exposing any summary',async t=>{
 const f=await fixture(t);f.add();await f.n.tick();f.now=1000;await f.n.tick();
 let providerCalls=0;const stream=async()=>{await f.n.beforeModel({messages:f.sent});providerCalls++;};
 f.bridge.flush=async()=>{throw Error('disk unavailable');};await assert.rejects(stream(),/disk unavailable/);assert.equal(providerCalls,0);
 f.bridge.flush=async()=>{};await stream();assert.equal(providerCalls,1);
});
test('prepared scope survives cold open and is filtered before admission',async t=>{
 const f=await fixture(t);f.add();f.add('10000003');await f.n.tick();f.now=1000;
 f.fail='notification-prepared';await assert.rejects(f.n.tick(),/notification-prepared/);
 f.fail=null;await f.open();await f.n.tick('10000003');
 assert.deepEqual(JSON.parse(f.sent[0].content[0].text).conversations.map(c=>c.peer_account),['10000003']);
});
test('restored unclaimed inbox uses current scope and keeps its original native ID',async t=>{
 const f=await fixture(t);f.add();f.add('10000003');await f.n.tick();f.now=1000;await f.n.tick();
 const original=f.sent[0].id;await f.open();f.n.scope=()=> '10000003';
 const inbox=f.bridge.agent.inbox;inbox.remove=id=>{inbox.nextTurn=inbox.nextTurn.filter(m=>m.id!==id);};
 await f.n.resumePending();assert.equal(inbox.nextTurn.length,1);assert.equal(inbox.nextTurn[0].id,original);
 assert.deepEqual(JSON.parse(inbox.nextTurn[0].content[0].text).conversations.map(c=>c.peer_account),['10000003']);
});
test('new session incarnation cannot use protocol-2 absence as replay evidence',async t=>{
 const f=await fixture(t);f.add();await f.n.tick();await f.n.save({...f.n.state,batch:{...f.n.state.batch,state:'dispatching'}});
 f.bridge.agent.session.header.createdAt=2;await f.open();f.now=1000;await f.n.tick();
 assert.equal(f.sent.length,0);assert.equal(f.n.state.batch.state,'uncertain');
});
test('followup throwing after insertion reconciles evidence without a second call',async t=>{
 const f=await fixture(t);f.add();await f.n.tick();f.now=1000;
 const followup=f.bridge.agent.followup;f.bridge.agent.followup=m=>{followup(m);throw Error('after insertion');};
 await assert.rejects(f.n.tick(),/after insertion/);await f.open();await f.n.tick();
 assert.equal(f.sent.length,1);assert.equal(f.n.state.batch,null);
});

for(const cut of ['collecting','admission']) for(const cold of [false,true])
test(`deferred rollback at ${cut}, cold=${cold}: preserves old retries and respects off/on cutoff`,async t=>{
 const f=await fixture(t);f.failedPeers.add('10000002');
 f.add();f.add('10000003');await f.n.tick();f.now=1000;await f.n.tick();
 assert.equal(f.sent.length,1,'healthy B advances despite A');
 assert.equal(f.n.state.cursor,2);assert.deepEqual(f.n.state.deferred.map(d=>d.cursor),[1]);
 f.add();f.add('10000003');await f.n.tick();
 assert.equal(f.n.state.cursor,2);assert.equal(f.n.state.batch.scanned,4);
 assert.deepEqual(f.n.state.deferred.map(d=>d.cursor).sort(),[1,3]);
 if(cold)await f.open(); // A valid batch's deferred may exceed committed cursor.
 assert.deepEqual(f.n.state.deferred.map(d=>d.cursor).sort(),[1,3]);
 if(cut==='collecting')f.settings={enabled:false,revision:2};
 else {
   f.now=2000;
   f.bridge.checkpoint=async n=>{if(n==='notification-dispatching')f.settings={enabled:false,revision:2};};
   await f.n.tick();f.bridge.checkpoint=async()=>{};
 }
 if(cold)await f.open();
 await f.n.tick();
 const rescan=f.requests.findLast(r=>r.after_cursor===2);
 assert.deepEqual(rescan.retry_cursors,[1],'keep truly old retry; cursor 3 is rediscovered by forward scan');
 assert.equal(f.sent.length,1,'revoked B batch not delivered');
 f.add();f.add('10000003'); // Arrive while disabled, not yet synchronized.
 f.settings={enabled:true,revision:3,skip_source_through:6};
 await f.open();await f.n.tick();f.now+=1000;await f.n.tick();assert.equal(f.sent.length,1);
 f.add();f.add('10000003');await f.n.tick();f.now+=1000;await f.n.tick();
 assert.equal(f.sent.length,2);assert.equal(JSON.parse(f.sent[1].content[0].text).conversations[0].new_count,1);
 await f.open();f.failedPeers.clear();await f.n.tick();f.now+=1000;await f.n.tick();
 assert.equal(f.sent.length,3);const recovered=JSON.parse(f.sent[2].content[0].text).conversations;
 assert.equal(recovered[0].peer_account,'10000002');assert.equal(recovered[0].new_count,1);
 await f.n.tick();assert.equal(f.sent.length,3,'no replay of disabled-period or already delivered events');
});

for(const committed of [0,2]) for(const enabled of [true,false]) test(`existing bad journal repairs forward deferred but retains scanned history: cursor=${committed}, enabled=${enabled}`,async t=>{
 const f=await fixture(t);f.failedPeers.add('10000002');
 for(let i=0;i<committed;i++)f.add(i===0?'10000002':'10000003');
 f.add();f.add('10000003');
 f.settings={enabled,revision:enabled?1:2};
 const cursor=committed+1;
 const d=c=>({cursor:c,peer_account:'10000002',error_code:'upstream_unavailable'});
 // Bypass the new writer to recreate the owner's already persisted bad state.
 await writeFile(f.n.path,JSON.stringify({...f.n.state,cursor:committed,batch:null,deferred:committed?[d(1),d(cursor)]:[d(cursor)]}));
 await f.open();assert.equal(f.n.state.cursor,committed);
 assert.deepEqual(f.n.state.deferred.map(d=>d.cursor),committed?[1]:[]);
 assert.deepEqual(JSON.parse(await readFile(f.n.path)).deferred,f.n.state.deferred,'repair is durable before first HTTP call');
 if(!enabled){
   await f.n.tick();assert.equal(f.sent.length,0);assert.equal(f.n.state.cursor,f.events.length);
   f.settings={enabled:true,revision:3,skip_source_through:f.events.length};
   f.add();f.add('10000003');await f.open();await f.n.tick();f.now=1000;await f.n.tick();
   assert.equal(f.sent.length,1);assert.equal(JSON.parse(f.sent[0].content[0].text).conversations[0].new_count,1);
   f.failedPeers.clear();await f.n.tick();f.now+=1000;await f.n.tick();assert.equal(f.sent.length,2);
   assert.equal(JSON.parse(f.sent[1].content[0].text).conversations[0].new_count,1,'disabled old failures are skipped, not replayed');
   await f.n.tick();assert.equal(f.sent.length,2);return;
 }
 await f.n.tick();f.now=1000;await f.n.tick();assert.equal(f.sent.length,1);
 assert.deepEqual(f.n.state.deferred.map(d=>d.cursor).sort(),committed?[1,cursor]:[cursor]);
 await f.open();f.failedPeers.clear();await f.n.tick();f.now+=1000;await f.n.tick();
 assert.equal(f.sent.length,2);
 assert.equal(JSON.parse(f.sent[1].content[0].text).conversations[0].new_count,committed?2:1,'both old failure and forward event survive repair');
 await f.n.tick();assert.equal(f.sent.length,2);
});

test('group and business notices use one recovered batch with membership and action state independent', async t => {
  const f = await fixture(t);
  const group = {type: 'group', id: 'group:' + 'a'.repeat(32)};
  const groupSummary = (revision, position) => ({
    conversation: group, display_name: 'Synthetic group',
    membership_revision: revision, new_count: 1, incoming_unread: 1,
    last_message: {position, text: 'sender content'},
  });
  let membership = 1;
  let page = {
    items: [groupSummary(1, 2)],
    business_notices: {
      new_count: 1, unread_count: 3, pending_count: 2,
      last_notice: {notification_id: 'invite-1', type: 'group_invitation', text: 'invited', truncated: false},
    },
    cursor: 1,
  };
  f.bridge.client.call = async (path, args) => {
    if (path === 'notifications/get') return {...f.settings};
    if (path === 'chat/list_conversations') {
      return {items: membership === null ? [] : [{conversation: group, membership_revision: membership}],
        next_cursor: null};
    }
    assert.equal(path, 'notifications/changes', 'delivery never executes or marks a notice');
    const fresh = args.after_cursor < page.cursor;
    return {
      settings: {...f.settings}, items: fresh ? page.items : [],
      ...(fresh ? {business_notices: page.business_notices} : {}),
      next_cursor: page.cursor, through_cursor: page.cursor, has_more: false, deferred: [],
    };
  };
  await f.n.tick();
  await f.open();
  membership = 3;
  page = {
    items: [groupSummary(3, 5)],
    business_notices: {
      new_count: 1, unread_count: 2, pending_count: 2,
      last_notice: {notification_id: 'invite-2', type: 'group_invitation', text: 'new', truncated: false},
    },
    cursor: 2,
  };
  f.now = 1000;
  await f.n.tick();
  assert.equal(f.sent.length, 1);
  const summary = JSON.parse(f.sent[0].content[0].text);
  assert.notEqual(summary.notification_id, 'invite-2');
  assert.deepEqual(summary.conversations, [groupSummary(3, 5)]);
  assert.deepEqual(summary.business_notices, {...page.business_notices, new_count: 2});
  membership = null;
  const projected = {messages: [...f.sent]};
  await f.n.beforeModel(projected);
  const safe = JSON.parse(projected.messages[0].content[0].text);
  assert.deepEqual(safe.conversations, []);
  assert.equal(safe.business_notices.pending_count, 2);
  await f.open();
  await f.n.tick();
  assert.equal(f.sent.length, 1);
});

test('one batch bounds group previews and keeps the omitted counts', async t => {
  const f = await fixture(t);
  const groups = Array.from({length: 21}, (_, index) => ({
    conversation: {type: 'group', id: 'group:' + index.toString(16).padStart(32, '0')},
    display_name: 'Synthetic group',
    membership_revision: 1, new_count: 2, incoming_unread: 5,
    last_message: {position: 1, text: 'bounded', created_at: new Date(index * 1000).toISOString()},
  }));
  f.bridge.client.call = async (path, args) => {
    if (path === 'notifications/get') return {...f.settings};
    if (path === 'chat/list_conversations') return {items: groups, next_cursor: null};
    assert.equal(path, 'notifications/changes');
    return {
      settings: {...f.settings}, items: args.after_cursor === 0 ? groups : [],
      next_cursor: 21, through_cursor: 21, has_more: false, deferred: [],
    };
  };
  await f.n.tick();
  f.now = 1000;
  await f.n.tick();
  assert.equal(f.sent.length, 1);
  const summary = JSON.parse(f.sent[0].content[0].text);
  assert.equal(summary.conversations.length, 20);
  assert.equal(summary.conversations[0].conversation.id, groups.at(-1).conversation.id);
  assert.deepEqual(summary.omitted_groups, {count: 1, new_count: 2, incoming_unread: 5});
});
