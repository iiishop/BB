// Stock host + official MCP + standalone Dart + FastAPI. Model only is synthetic.
import assert from 'node:assert/strict';
import {readFile,writeFile,appendFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {boot} from '../journal/host.mjs';
import {Client} from '../../bundle/client.js';
import {Bridge} from '../../bundle/bridge.js';
import {Notifications} from '../../bundle/notifications.js';
const [pkg,root,configPath,cut,phase] = process.argv.slice(2);
const c=JSON.parse(await readFile(configPath));
const client=new Client(c.origin,resolve(root,'state'));
const raw=client.raw.bind(client);
let failAdmission=false, armAdmission=false;
client.raw=async(path,body,owner)=>{
 if(failAdmission && path==='/v2/notifications/get'){failAdmission=false;throw Error('injected admission network_error');}
 const reply=await raw(path,body,owner);
 if(path.startsWith('/v2/notifications/'))await appendFile(resolve(root,'wire.jsonl'),JSON.stringify({path,body,reply})+'\n');
 return reply;
};
const requests=[], timeline=[], queries=[];
let changeSettingsAtAdmission=false;
let count=0;
async function* provider(options) {
 count++; requests.push(options.messages);
 const notice=options.messages.some(m=>m.content.some(b=>b.type==='text'&&b.text.includes('conversation_notification')));
 if(notice)assert.ok(timeline.some(e=>e.event==='notification-visible'),'provider requires durable notification barrier');
 timeline.push({event:'provider',at:Date.now(),notice});
 const q=queries.shift();
 if(q){yield {type:'block-start',index:0,blockType:'tool-call'};yield {type:'block-end',index:0,block:{type:'tool-call',id:'call-'+count,name:'mcp__bb__'+q.name,arguments:JSON.stringify(q.args)}};}
 yield {type:'finish',reason:{kind:q?'tool-calls':'stop'}};
}
const rt=await boot(pkg,root,provider,()=>{});
const agent=await rt.open('notifications-'+cut,phase==='recover');
await client.bind(agent.session.id);
const mcp=await rt.load('dsh-mcp-client');
const fiber=await rt.ctx.plugin(mcp,{serverName:'bb',transport:'stdio',command:'uv',args:['run','--project',resolve('dsh-plugin'),'--locked','bb-dsh-plugin'],env:{BB_CLIENT_BASE_URL:c.origin,BB_CONSUMER_STATE_FILE:client.stateFile},failOnStartupError:true});
const bridge=await new Bridge(rt.ctx,agent,client,resolve(root,'state'),async name=>{
 if(name==='notification-visible')timeline.push({event:name,at:Date.now()});
 if(armAdmission&&name==='notification-dispatching'){armAdmission=false;failAdmission=true;}
 if(changeSettingsAtAdmission&&name==='notification-dispatching'){
   changeSettingsAtAdmission=false;await client.call('notifications/set',{enabled:false});
 }
 if(phase==='crash'&&name===cut){console.log(JSON.stringify({checkpoint:name}));await new Promise(()=>setInterval(()=>{},1000));}
}).mount();bridge.installOperations();bridge.notifications.windowMs=0;
const post=async(path,body,token)=>{const r=await fetch(c.api+path,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body)});assert.ok(r.ok,String(r.status));return r.json();};
const send=async(peer,text)=>{const login=await post('/auth/login',{account:peer,password:'Abc123'});return post('/messages',{target_account:c.account,client_nonce:crypto.randomUUID(),content:[{type:'text',text}]},login.token);};
const unread=async peer=>(await client.call('chat/list_conversations')).items.find(i=>i.peer_account===peer)?.incoming_unread??0;
async function until(fn){const deadline=Date.now()+10000;while(Date.now()<deadline){if(await fn())return;await new Promise(r=>setTimeout(r,10));}throw Error('condition deadline');}
const prompt=(text)=>agent.followup({id:crypto.randomUUID(),role:'user',source:{kind:'user'},content:[{type:'text',text}]});
try {
 await bridge.recover();
 if(cut.startsWith('deferred-')) {
   let now=0;
   const reopen=async()=>{bridge.notifications=new Notifications(bridge,{now:()=>now});await bridge.notifications.open();};
   const fault=async peer=>{
     const reply=await fetch(c.control+'/metadata-failure',{method:'POST',body:JSON.stringify({peer})});
     assert.equal(reply.status,200);
   };
   const tick=async()=>{await bridge.tick();await bridge.drain();};
   const latest=()=>requests.at(-1).flatMap(m=>m.content).map(b=>{try{return JSON.parse(b.text);}catch{return {};}}).filter(v=>v.type==='conversation_notification').at(-1);
   const pair=async(a,b)=>{
     await fault(null);await send(c.peer,a);await send(c.other,b);
     // Feed readability uses the same API. Finish real synchronization before
     // arming the metadata fault so this case exercises deferred, not backfill.
     await client.call('events/subscribe',{discover:true});await fault(c.peer);
   };
   await reopen();await fault(null);
   const hasOld=cut!=='deferred-legacy-zero';
   if(hasOld){
     await pair('old A failure','old healthy B');
     await tick();now+=1000;await tick();assert.equal(count,1);
   }
   const committed=bridge.notifications.state.cursor;
   const old=(bridge.notifications.state.deferred??[]).map(d=>d.cursor);
   assert.equal(old.length,hasOld?1:0);
   await pair('pending A failure','pending healthy B');await tick();
   const pending=structuredClone(bridge.notifications.state);
   assert.equal(pending.cursor,committed);
   assert.ok(pending.deferred.some(d=>d.cursor>committed));
   assert.ok(pending.deferred.every(d=>d.cursor<=pending.batch.scanned));
   if(cut.startsWith('deferred-legacy')){
     // Recreate the already-persisted bad journal, bypassing the new writer.
     await writeFile(bridge.notifications.path,JSON.stringify({...pending,batch:null}));
     // Prove the unmodified production HTTP endpoint rejects that exact range.
     await assert.rejects(client.call('notifications/changes',{
       after_cursor:committed,retry_cursors:pending.deferred.map(d=>d.cursor),limit:100,
     }),e=>e.status===422&&e.code==='validation_error');
     await reopen();assert.deepEqual(bridge.notifications.state.deferred.map(d=>d.cursor),old);
     const disk=JSON.parse(await readFile(bridge.notifications.path));
     assert.deepEqual(disk.deferred.map(d=>d.cursor),old);
     await tick();now+=1000;await tick();assert.equal(count,hasOld?2:1);
     assert.equal(latest().conversations[0].peer_account,c.other);
     await reopen();await fault(null);await tick();now+=1000;await tick();
     assert.equal(count,hasOld?3:2);assert.equal(latest().conversations[0].peer_account,c.peer);
     assert.equal(latest().conversations[0].new_count,hasOld?2:1,'old and rediscovered failures both delivered');
     const before=count;await tick();assert.equal(count,before);
   } else {
     if(cut==='deferred-admission'){
       now+=1000;changeSettingsAtAdmission=true;await tick();
       assert.deepEqual(bridge.notifications.state.deferred.map(d=>d.cursor),old,'atomic rollback retains only scanned historical failures');
     } else await client.call('notifications/set',{enabled:false});
     await reopen();await tick();assert.equal(count,1);
     // Source cutoff skips disabled-period messages even if not yet synced.
     await send(c.peer,'disabled A');await send(c.other,'disabled B');
     await client.call('notifications/set',{enabled:true});await reopen();await tick();now+=1000;await tick();assert.equal(count,1);
     await pair('enabled A','enabled B');await tick();now+=1000;await tick();
     assert.equal(count,2);assert.equal(latest().conversations[0].peer_account,c.other);assert.equal(latest().conversations[0].new_count,1);
     await reopen();await fault(null);await tick();now+=1000;await tick();
     assert.equal(count,3);assert.equal(latest().conversations[0].peer_account,c.peer);assert.equal(latest().conversations[0].new_count,1);
     await tick();assert.equal(count,3);
   }
   await fault(null);
   console.log(JSON.stringify({status:'PASS',cut,real_client_range_validation:true,invalid_range_rejected:cut.startsWith('deferred-legacy'),cold_journal:true,retained_old_retry:hasOld,model_calls:count,model:'deterministic double',fault:'public DI metadata 503 only; actual Dart HTTP and FastAPI'}));
 } else if(cut==='offline') {
   if(phase==='seed') {
     await bridge.tick(c.peer);await bridge.flush();
     await writeFile(resolve(root,'before-settings.json'),JSON.stringify(await client.call('notifications/get')));
     console.log(JSON.stringify({status:'PASS',phase,settings_enabled:true}));
   } else {
     assert.deepEqual(await client.call('notifications/get'),JSON.parse(await readFile(resolve(root,'before-settings.json'))));
     await bridge.tick(c.peer);await bridge.drain();
     assert.equal(count,1);assert.equal(await unread(c.peer),3);
     const data=requests[0].flatMap(m=>m.content).map(b=>{try{return JSON.parse(b.text);}catch{return {};}}).find(v=>v.type==='conversation_notification');
     assert.equal(data.conversations[0].new_count,3);
     await bridge.tick(c.peer);await bridge.drain();assert.equal(count,1);
     console.log(JSON.stringify({status:'PASS',phase,offline_aggregate:3,notifications:1,unread:3,settings_preserved:true,model:'deterministic double'}));
   }
 } else if(cut==='scope') {
   let scope=null;bridge.notifications.scope=()=>scope;bridge.notifications.windowMs=1000;
   await send(c.peer,'scope-A');await send(c.other,'scope-B');await bridge.tick();assert.equal(count,0);
   scope=c.other;await new Promise(r=>setTimeout(r,1100));await bridge.tick();await bridge.drain();
   assert.equal(count,1);
   const summary=requests[0].flatMap(m=>m.content).map(b=>{try{return JSON.parse(b.text);}catch{return {};}}).find(v=>v.type==='conversation_notification');
   assert.deepEqual(summary.conversations.map(x=>x.peer_account),[c.other]);
   await bridge.tick();await bridge.drain();assert.equal(count,1);
   console.log(JSON.stringify({status:'PASS',scope:'discovery to explicit B during aggregation',notifications:1,model:'deterministic double'}));
 } else if(cut==='admission') {
   armAdmission=true;await send(c.peer,'admission-A');
   await assert.rejects(bridge.tick(c.peer),/injected admission network_error/);assert.equal(count,0);
   bridge.notifications=new Notifications(bridge,{windowMs:0});await bridge.notifications.open();
   await bridge.tick(c.peer);await bridge.drain();assert.equal(count,1);
   await send(c.peer,'admission-new');await bridge.tick(c.peer);await bridge.drain();assert.equal(count,2);
   await bridge.tick(c.peer);await bridge.drain();assert.equal(count,2);
   console.log(JSON.stringify({status:'PASS',pre_call_failure:true,cold_open:true,recovered_and_new_notifications:2,model:'deterministic double'}));
 } else if(cut!=='wait') {
   if(phase==='crash'){await send(c.peer,'crash summary');await bridge.tick();await bridge.drain();}
   else {
     await bridge.tick();await bridge.drain();
     // native IDs are the durable acceptance evidence independent of projection shape.
     const noticeIds=agent.session.snapshotEvents().filter(e=>e.type==='user/message'&&e.data.id?.startsWith('bb-notice-'));
     const pending=bridge.notifications.status().pending;
     assert.equal(pending,null);assert.equal(noticeIds.length,1, 'every crash boundary recovers one native input');
     const before=count;await bridge.tick();await bridge.drain();assert.equal(count,before);
     assert.equal(await unread(c.peer),1);
     await send(c.peer,'new notification after recovery');await bridge.tick();await bridge.drain();
     assert.equal(count,before+1,'recovery must also permit future notifications');
     assert.equal(await unread(c.peer),2);
     console.log(JSON.stringify({status:'PASS',cut,native_notices:noticeIds.length,pending,new_notification_after_recovery:true,unread:2,model:'deterministic double'}));
   }
 } else {
   queries.push({name:'wait_messages',args:{account:c.peer,seen_position:0,timeout:30}});
   prompt('Explicitly wait for peer A.');
   await until(()=>bridge.waiting(c.peer));timeline.push({event:'wait-started',at:Date.now()});
   await send(c.other,'B1');await send(c.other,'B2');
   await bridge.tick();timeline.push({event:'B-enqueued',at:Date.now()});
   assert.ok(bridge.waiting(c.peer),'B notification must not replace the real wait');
   assert.equal(count,1,'stock host queues B while actual MCP wait is pending');
   assert.equal(agent.inbox.nextTurn.filter(m=>m.id.startsWith('bb-notice-')).length,1);
   assert.equal(await unread(c.other),2,'notification is not successful read');
   await send(c.peer,'release actual wait A');timeline.push({event:'A-release',at:Date.now()});
   await bridge.drain();timeline.push({event:'wait-and-notice-processed',at:Date.now()});
   assert.ok(count>=3);assert.ok(requests.at(-1).some(m=>m.content.some(b=>b.text?.includes('conversation_notification'))));
   assert.equal(await unread(c.other),2);assert.equal(await unread(c.peer),0,'successful wait result is displayed');
   const before=count;await bridge.tick();await bridge.drain();assert.equal(count,before,'displayed wait A not re-notified');
   queries.push({name:'read_messages',args:{account:c.other,after_position:0,limit:50,unread_only:true}});
   prompt('Explicitly read B.');await bridge.drain();assert.equal(await unread(c.other),0);
   assert.equal(await unread(c.peer),0);
   for(const [target,text] of [[c.peer,'explicit-A'],[c.other,'explicit-B']]) {
     queries.push({name:'send_message',args:{target_account:target,content:[{type:'text',text}]}});
     prompt('Explicitly send to the specified account with no unread prerequisite.');await bridge.drain();
     const history=await client.call('chat/read_messages',{account:target,after_position:0,limit:50});
     const outgoing=history.items.filter(i=>i.message.sender_account===c.account);
     assert.equal(outgoing.length,1);assert.equal(outgoing[0].message.target_account,target);assert.equal(outgoing[0].message.content[0].text,text);
   }
   await client.call('notifications/set',{enabled:false});await send(c.other,'off interval');
   await client.call('notifications/set',{enabled:true});await bridge.tick();await bridge.drain();assert.equal(await unread(c.other),1,'skipped notification does not clear unread');
   const after=count;await send(c.other,'on interval');await bridge.tick();await bridge.drain();assert.equal(count,after+1);
   const summaries=requests.at(-1).flatMap(m=>m.content).filter(b=>b.type==='text').map(b=>{try{return JSON.parse(b.text);}catch{return {};}}).filter(v=>v.type==='conversation_notification');
   assert.equal(summaries.at(-1).conversations[0].new_count,1);assert.equal(await unread(c.other),2);
   assert.equal((await client.call('chat/read_messages',{account:c.other,after_position:0,limit:50})).items.length,5,'only the one explicit B send appears');
   console.log(JSON.stringify({status:'PASS',timeline,wait_behavior:'queued nextTurn; no interruption; delivered after wait completes',notifications_do_not_read:true,explicit_read_confirmed:true,manual_enable_skips_unsynced:true,final_text_sends:0,explicit_target_sends:2,proactive_without_unread:true,model_calls:count,model:'deterministic double'}));
 }
}finally{await bridge.close();await fiber.dispose();await rt.close();client.close();}
