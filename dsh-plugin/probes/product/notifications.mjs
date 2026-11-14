// Stock host + official MCP + standalone Dart + FastAPI. Model only is synthetic.
import assert from 'node:assert/strict';
import {readFile,writeFile,appendFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {boot} from '../journal/host.mjs';
import {Client} from '../../bundle/client.js';
import {Bridge} from '../../bundle/bridge.js';
const [pkg,root,configPath,cut,phase] = process.argv.slice(2);
const c=JSON.parse(await readFile(configPath));
const client=new Client(c.origin,resolve(root,'state'));
const raw=client.raw.bind(client);
client.raw=async(path,body,owner)=>{
 const reply=await raw(path,body,owner);
 if(path.startsWith('/v2/notifications/'))await appendFile(resolve(root,'wire.jsonl'),JSON.stringify({path,body,reply})+'\n');
 return reply;
};
const requests=[], timeline=[], queries=[];
let count=0;
async function* provider(options) {
 count++; requests.push(options.messages);
 const notice=options.messages.some(m=>m.content.some(b=>b.type==='text'&&b.text.includes('conversation_notification')));
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
 if(phase==='crash'&&name===cut){console.log(JSON.stringify({checkpoint:name}));await new Promise(()=>setInterval(()=>{},1000));}
}).mount();bridge.installOperations();bridge.notifications.windowMs=0;
const post=async(path,body,token)=>{const r=await fetch(c.api+path,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body)});assert.ok(r.ok,String(r.status));return r.json();};
const send=async(peer,text)=>{const login=await post('/auth/login',{account:peer,password:'Abc123'});return post('/messages',{target_account:c.account,client_nonce:crypto.randomUUID(),content:[{type:'text',text}]},login.token);};
const unread=async peer=>(await client.call('chat/list_conversations')).items.find(i=>i.peer_account===peer)?.incoming_unread??0;
async function until(fn){const deadline=Date.now()+10000;while(Date.now()<deadline){if(await fn())return;await new Promise(r=>setTimeout(r,10));}throw Error('condition deadline');}
const prompt=(text)=>agent.followup({id:crypto.randomUUID(),role:'user',source:{kind:'user'},content:[{type:'text',text}]});
try {
 await bridge.recover();
 if(cut==='offline') {
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
 } else if(cut!=='wait') {
   if(phase==='crash'){await send(c.peer,'crash summary');await bridge.tick();}
   else {
     await bridge.tick();await bridge.drain();
     // native IDs are the durable acceptance evidence independent of projection shape.
     const noticeIds=agent.session.snapshotEvents().filter(e=>e.type==='user/message'&&e.data.id?.startsWith('bb-notice-'));
     const pending=bridge.notifications.status().pending;
     if(cut==='notification-dispatching'){assert.equal(pending.state,'uncertain');assert.equal(noticeIds.length,0);}
     else {assert.equal(pending,null);assert.equal(noticeIds.length,1);}
     const before=count;await bridge.tick();await bridge.drain();assert.equal(count,before);
     assert.equal(await unread(c.peer),1);
     console.log(JSON.stringify({status:'PASS',cut,native_notices:noticeIds.length,pending,unread:1,model:'deterministic double'}));
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
