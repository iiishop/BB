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
 if(cut==='notification-dispatching'){assert.equal(f.sent.length,0);assert.equal(f.n.state.batch.state,'uncertain');await f.n.tick();assert.equal(f.sent.length,0);}
 else {assert.equal(f.sent.length,1);assert.equal(f.n.state.cursor,1);await f.n.tick();assert.equal(f.sent.length,1);}
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
