// Deterministic state-machine tests; stock-host evidence is a separate live probe.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Notifications } from '../../bundle/notifications.js';

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'bb-notices-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const f = { now: 0, settings: {enabled:true,revision:1}, events: [], sent: [], calls: [], fail: null };
  const agent = { status:'idle', session:{id:'s',header:{createdAt:1},snapshotEvents:()=>[]},
    inbox:{nextTurn:[],nextStep:[]}, runMaintenance:async fn=>fn(), followup:m=>{ f.sent.push(m); agent.inbox.nextTurn.push(m); } };
  const bridge = {root, agent, check:async()=>{}, flush:async()=>{}, checkpoint:async name=>{if(f.fail===name)throw Error(name);},
    client: { identity:{account:'10000001',consumer_id:'c'}, call:async(path,args)=>{
      f.calls.push(path);
      if(path==='notifications/get')return {...f.settings};
      assert.equal(path,'notifications/changes');
      const head=args.through_cursor??f.events.length;
      const entries=f.events.slice(args.after_cursor,Math.min(head,args.after_cursor+args.limit));
      return { settings:{...f.settings},items:f.settings.enabled?entries:[], next_cursor:Math.min(head,args.after_cursor+args.limit), through_cursor:head,has_more:args.after_cursor+args.limit<head };
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
 const f=await fixture(t);let failing=true;
 const original=f.bridge.client.call;
 f.bridge.client.call=async(path,args)=>{
   const page=await original(path,args);
   if(path!=="notifications/changes")return page;
   const retries=args.retry_cursors??[];
   if(failing){
     page.items=page.items.filter(i=>i.peer_account!=="10000002");
     page.deferred=(args.after_cursor===0||retries.includes(1))?[{cursor:1,peer_account:"10000002",error_code:"upstream_unavailable"}]:[];
   } else if(retries.includes(1))page.items.push(f.events[0]);
   return page;
 };
 f.add();f.add("10000003");await f.n.tick();f.now=1000;await f.n.tick();
 assert.equal(f.sent.length,1);assert.equal(JSON.parse(f.sent[0].content[0].text).conversations[0].peer_account,"10000003");
 await f.open();assert.equal(f.n.state.deferred.length,1);failing=false;await f.n.tick();f.now+=1000;await f.n.tick();
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
