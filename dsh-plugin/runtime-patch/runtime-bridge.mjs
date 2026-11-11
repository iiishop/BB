// Session-bound adapter. Cursor and acceptance live in native JSONL, never another outbox.
import assert from 'node:assert/strict';
import {bindLocalControl} from './local-bridge.mjs';
const text=value=>({type:'text',text:typeof value==='string'?value:JSON.stringify(value)});

export async function projectVisible(agent,item,peer_account){
 const content=[],proofs=[],proof=item.presentation?{receipt_id:item.presentation.receipt_id,content_digest:item.presentation.content_digest}:null;
 if(proof)content.push(text('BB_PRESENTATION_START:'+JSON.stringify(proof)));
 content.push(text(item.message));
 for(const block of item.blocks){
  if(block.type==='text'){content.push(text(block.text));continue;}
  assert.equal(block.type,'image');
  try{
   const config=agent.session.requestHeader()?.config??agent.options;
   const info=await agent.ctx.llm.resolveModelInfo(config.provider,config.model,new AbortController().signal);
   assert.ok(info.inputModalities?.includes('image'),'model has no image capability');
   const store=agent.ctx.get('attachments');assert.ok(store,'no image store');
   const data=Buffer.from(block.data,'base64');assert.equal(data.toString('base64'),block.data);
   const [attachment]=await store.saveImages([{data,mediaType:block.mime_type}]);
   content.push({type:'image',attachment});
  }catch{content.push(text('[image unavailable: not admitted to durable model context]'));}
 }
 if(proof){
  content.push(text('BB_PRESENTATION_END:'+JSON.stringify(proof.receipt_id)));
  proofs.push({...proof,message_id:item.message.id,sender_account:item.message.sender_account,target_account:item.message.target_account,position:item.message.position,peer_account,consumer_session:agent.session.id,image_count:item.blocks.filter(b=>b.type==='image').length});
 }
 return {content,presentations:proofs};
}

export class RuntimeBridge {
 constructor(agent,{origin,account,peer_account,server_name="bb"}){
  assert.match(server_name,/^[A-Za-z0-9_]{1,30}$/);agent.bbToolPrefix=`mcp__${server_name}__`;
  this.agent=agent;this.account=account;this.peer=peer_account;this.post=bindLocalControl(agent,origin);this.tail=Promise.resolve();
 }
 async initialize(){
  await this.agent.bbConfigure(this.account,this.peer);
  const value=await this.post('/events/subscribe',{consumer_session:this.agent.session.id,peer_account:this.peer});
  assert.equal(value.consumer_session,this.agent.session.id);assert.equal(value.peer_account,this.peer);
  return this;
 }
 pumpOnce({wait=false,timeout=60,signal}={}){
  const work=this.tail.then(()=>this.readPage(wait,timeout,signal));this.tail=work.catch(()=>{});return work;
 }
 async readPage(wait,timeout,signal){
  await this.agent.bbRecoverDeliveries();
  const after=this.agent.bbEventCursor();
  const page=await this.post(wait?'/events/wait':'/events/read',{consumer_session:this.agent.session.id,after_cursor:after,limit:50,...wait?{timeout}: {}},{signal});
  assert.ok(Array.isArray(page.items)&&typeof page.has_more==='boolean'&&Number.isSafeInteger(page.next_cursor));
  let previous=after;
  for(const {cursor,event} of page.items){
   assert.ok(Number.isSafeInteger(cursor)&&cursor>previous);previous=cursor;
   assert.equal(event.version,1);assert.equal(event.account,this.account,'event account mismatch');assert.equal(event.consumer_session,this.agent.session.id,'event session mismatch');
   const key={account:this.account,session_id:this.agent.session.id,event_id:event.event_id};
   if(this.agent.bbDeliveryStatus(key).state==='absent'){
    let projected;
    if(event.type==='message.available'){
     assert.equal(event.peer_account,this.peer);assert.ok(Number.isSafeInteger(event.position)&&event.position>0);
     const response=await this.post('/chat/read_messages',{account:this.peer,consumer_session:this.agent.session.id,after_position:event.position-1,limit:1});
     const item=response.items?.[0];assert.equal(item?.message.position,event.position,'event not readable');
     assert.deepEqual([item.message.sender_account,item.message.target_account].sort(),[this.account,this.peer].sort());
     projected=await projectVisible(this.agent,item,this.peer);
    }else{
     assert.ok(['download.succeeded','download.failed'].includes(event.type));
     assert.ok(typeof event.task_id==='string'&&typeof event.operation_id==='string');
     if(event.type==='download.succeeded')assert.ok(typeof event.actual_path==='string');else assert.ok(typeof event.error_code==='string');
     projected={content:[text({runtime_event:event})],presentations:[]};
    }
    await this.agent.bbDeliver(key,projected.content,{presentations:projected.presentations,peer_account:event.peer_account});
   }
   // A killed worker can replay this cursor; durable accepted identity wins before refetching content.
   await this.agent.bbAdvanceCursor(this.account,cursor);
  }
  assert.equal(page.next_cursor,page.items.length?previous:after,'cursor cannot skip unread events');
  return page;
 }
 async run(signal){
  // Host owns this awaited lifetime. No detached poller or alternate Agent scheduler.
  while(!signal.aborted){
   let page;try{page=await this.pumpOnce({wait:true,signal});}catch(error){if(signal.aborted)return 'cancelled';throw error;}
   if(['logout','disconnected','cancelled'].includes(page.reason))return page.reason;
  }
  return 'cancelled';
 }
}
export function setupRuntimeBridge(options,onReady=()=>{}){
 return (_ctx,agent)=>{const bridge=new RuntimeBridge(agent,options);agent.bbInitializeBridge=()=>bridge.initialize();onReady(bridge);};
}
