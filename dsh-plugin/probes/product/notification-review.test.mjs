import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {Notifications} from '../../bundle/notifications.js';

async function fixture(t) {
 const root=await mkdtemp(new URL('./review-state-',import.meta.url).pathname);
 t.after(()=>rm(root,{recursive:true,force:true}));
 const f={now:0,events:[],sent:[],settings:{enabled:true,revision:1,skip_source_through:0},failAdmission:false};
 const agent={status:'idle',session:{id:'qa-review',header:{createdAt:1},snapshotEvents:()=>[]},
 inbox:{nextTurn:[],nextStep:[]},runMaintenance:async fn=>fn(),followup:m=>{f.sent.push(m);agent.inbox.nextTurn.push(m);}};
 const b={root,agent,check:async()=>{},flush:async()=>{},checkpoint:async n=>{
   if(n==='notification-dispatching'&&f.failAdmission)f.throwNextGet=true;
 },client:{identity:{account:'10000001',consumer_id:'consumer-review'},call:async(path,args)=>{
   if(path==='notifications/get'){
     if(f.throwNextGet){f.throwNextGet=false;f.failAdmission=false;throw Object.assign(new Error('one-shot network error before followup'),{code:'network_error'});}
     return {...f.settings};
   }
   assert.equal(path,'notifications/changes');
   const head=args.through_cursor??f.events.length;
   return {settings:{...f.settings},items:f.settings.enabled?f.events.slice(args.after_cursor,head):[],
     next_cursor:head,through_cursor:head,has_more:false,deferred:[]};
 }}};
 f.add=peer=>f.events.push({conversation:{type:'direct',id:`dm:10000001:${peer}`},peer_account:peer,
   display_name:peer,new_count:1,incoming_unread:1,last_message:{message_id:`message-${f.events.length+1}`,sender_account:peer,
   position:1,created_at:'2026-11-14T17:00:00Z',text:'synthetic preview',truncated:false}});
 f.open=async()=>{f.n=new Notifications(b,{now:()=>f.now});await f.n.open();};
 await f.open();return f;
}

test('R1 admission transport failure before followup recovers after reconnect and cold open',async t=>{
 const f=await fixture(t);f.add('10000002');await f.n.tick();f.now=1000;f.failAdmission=true;
 await assert.rejects(f.n.tick(),/one-shot network error/);assert.equal(f.sent.length,0,'no native side effect happened');
 await f.open();await f.n.tick();f.add('10000003');f.now=2000;await f.n.tick();
 f.settings={...f.settings,enabled:false,revision:2};await f.n.tick();
 f.settings={...f.settings,enabled:true,revision:3,skip_source_through:2};await f.n.tick();
 f.add('10000004');await f.open();f.now=4000;await f.n.tick();f.now=5000;await f.n.tick();
 console.log(JSON.stringify({case:'R1',sent:f.sent.length,status:f.n.status(),settings:f.settings}));
 assert.ok(f.sent.length>0,'new enabled-period messages must notify after recovered transport; permanently uncertain is not recovery');
});

test('R2 changing explicit peer must exclude a prior collecting peer from delivery',async t=>{
 const f=await fixture(t);f.add('10000002');await f.n.tick('10000002');
 f.add('10000003');f.now=1000;await f.n.tick('10000003');
 assert.equal(f.sent.length,1);
 const peers=JSON.parse(f.sent[0].content[0].text).conversations.map(c=>c.peer_account);
 console.log(JSON.stringify({case:'R2',configuredPeer:'10000003',deliveredPeers:peers}));
 assert.deepEqual(peers,['10000003'],'latest explicit peer filter must also apply to already-collected items');
});

test('control unchanged explicit peer delivers once and never reads body',async t=>{
 const f=await fixture(t);f.add('10000002');await f.n.tick('10000002');f.now=1000;await f.n.tick('10000002');
 await f.open();await f.n.tick('10000002');assert.equal(f.sent.length,1);
});
