// Pinned native hooks: the DSH driver remains the only scheduler.
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { createUserMessage } from '@deepseek-ai/dsh-llm';
import { appendPluginRecord, pluginRecordOf } from '@deepseek-ai/dsh-session';
const RECORD='plugin:bb/delivery-v1', PREFIX='bb-event-', VERSION='bb-recovery-3';
const serial=Symbol('bb-admission-serialization');
const hash=value=>createHash('sha256').update(JSON.stringify(value)).digest('hex');
const record=(agent,data)=>appendPluginRecord(agent.session,RECORD,{version:VERSION,...data});
export const checkpoint=(agent,phase)=>agent.ctx.parallel('bb-recovery/checkpoint',{agent,phase});
async function flush(agent){
 assert.ok(agent.ctx.get('sessionPersistence'),'BB requires persistent sessions');
 assert.equal(await agent.ctx.sessions.flush(agent.session),true);
}
function exclusive(agent,action){const next=(agent[serial]??Promise.resolve()).then(action);agent[serial]=next.catch(()=>{});return next;}
function identity(agent,key){
 assert.deepEqual(Object.keys(key).sort(),['account','event_id','session_id']);
 assert.match(key.account,/^[1-9][0-9]{7}$/);assert.equal(key.session_id,agent.session.id,'session binding mismatch');
 assert.ok(typeof key.event_id==='string'&&key.event_id.length>0&&key.event_id.length<=200);
 return PREFIX+hash([key.account,key.session_id,key.event_id]);
}
function records(agent){return agent.session.snapshotEvents().flatMap(event=>{
 const entry=pluginRecordOf(event);if(!entry?.type.startsWith('plugin:bb/'))return [];
 assert.equal(entry.type,RECORD,'unsupported BB record');
 assert.ok(['bb-recovery-1','bb-recovery-2',VERSION].includes(entry.data.version),'unsupported BB recovery version');
 return [{...entry.data,seq:event.seq}];
});}
function plans(agent){
 const result=new Map();
 for(const data of records(agent)){
  if(data.op==='plan')result.set(data.operation_id,{...data});
  if(data.op==='operation-result'){assert.ok(result.has(data.operation_id));result.get(data.operation_id).result=data.result;}
 }
 return [...result.values()];
}
export function states(agent){
 const items=new Map(), events=agent.session.snapshotEvents();
 for(const data of records(agent)){
  if(data.op==='accepted'){
   const id=identity(agent,data.key);assert.equal(id,data.message.id);assert.equal(data.logical_turn_id,id);
   assert.ok(!items.has(id),'duplicate acceptance');
   items.set(id,{...data,accepted_seq:data.seq,claims:[],dispatches:[],deferred:[],finished:[],settled:[],done:[]});
  }else if(['claimed','dispatch','deferred','finished','settled','done'].includes(data.op)){
   const item=items.get(data.id);assert.ok(item,'BB record without acceptance');
   item[{claimed:'claims',dispatch:'dispatches',deferred:'deferred',finished:'finished',settled:'settled',done:'done'}[data.op]].push(data);
  }
 }
 for(const event of events){
  const messages=event.type==='agent/inbox/spliced'?event.data.inserted:event.type==='user/message'?[event.data]:[];
  for(const message of messages)if(message.id.startsWith(PREFIX))assert.ok(items.has(message.id),'BB_STATE_LOST');
 }
 const completedTurns=new Set(events.filter(e=>e.type==='turn/end'&&e.data.reason?.kind==='completed').map(e=>e.data.turn));
 const pending=new Set([...agent.inbox.nextTurn,...agent.inbox.nextStep].map(m=>m.id));
 const operations=plans(agent);
 for(const item of items.values()){
  const last=item.dispatches.at(-1);
  item.operations=operations.filter(p=>p.members.includes(item.message.id));
  item.completed=item.done.length>0 || (!!last&&last.version==='bb-recovery-2'&&((completedTurns.has(last.turn)&&item.finished.some(f=>f.attempt_id===last.attempt_id))||item.settled.some(s=>completedTurns.has(s.turn))));
  // Legacy dispatch records lack request membership and side-effect barriers. Never adopt them as proof.
  item.legacy_uncertain=!!last&&last.version==='bb-recovery-1';
  item.pending=pending.has(item.message.id);
  item.state=item.legacy_uncertain?'legacy_uncertain':item.completed?'completed':item.pending?'accepted_pending':item.deferred.at(-1)?.seq>(last?.seq??0)?'deferred':last?'reasoning_recoverable':'accepted_recoverable';
 }
 return items;
}
export function status(agent,key){
 const i=states(agent).get(identity(agent,key));
 return i?{state:i.state,logical_turn_id:i.logical_turn_id,accepted_seq:i.accepted_seq,claims:i.claims,dispatches:i.dispatches,
 operations:i.operations.map(p=>({operation_id:p.operation_id,status:operationStatus(p.result)})),consumed_through:null}:{state:'absent',consumed_through:null};
}
export function deliver(agent,key,content,options={}){
 key=structuredClone(key);content=structuredClone(content);options=structuredClone(options);
 return exclusive(agent,async()=>{
  const id=identity(agent,key),items=states(agent);
  const binding=records(agent).find(r=>r.op==='binding');if(binding)assert.equal(binding.account,key.account,'account binding mismatch');
  for(const item of items.values())assert.equal(item.key.account,key.account,'account binding mismatch');
  const message={id,role:'user',source:{kind:'user'},content},prior=items.get(id);
  if(prior)assert.deepEqual(prior.message,message,'same event key with different content');
  if(!prior){
   const seen=alreadyPresented(agent,options.presentations??[]);
   record(agent,{op:'accepted',key,logical_turn_id:id,message});bindPresentations(agent,message,options.presentations??[]);
   if(seen)record(agent,{op:'done',id,logical_turn_id:id,attempt_id:seen,reason:'already_presented_by_read_or_wait'});
   else agent.send(message,agent.status==='running'&&typeof options.peer_account==='string'&&[...(agent.bbWaitingPeers?.values()??[])].includes(options.peer_account)?'next-step':'next-turn',false);
   await flush(agent);await checkpoint(agent,'accepted-before-receipt');
  }
  await recoverUnlocked(agent);return {...status(agent,key),disposition:prior?'existing':'new'};
 });
}
async function recoverUnlocked(agent){
 await confirmPending(agent);
 const items=states(agent),blocked=[...items.values()].filter(i=>i.legacy_uncertain).map(i=>i.logical_turn_id);
 if(blocked.length)return {blocked};
 if(agent.status==='running')return {blocked:[]};
 let work=false;
 for(const item of items.values()){
  if(item.completed)continue;work=true;
  if(item.pending)continue;
  record(agent,{op:'recovered',id:item.message.id,logical_turn_id:item.logical_turn_id,previous_claims:item.claims});
  agent.send(item.message,'next-turn',false);
 }
 if(work){await flush(agent);await checkpoint(agent,'recovered-before-wake');if(agent.inbox.hasPending)agent.wakeDriver();}
 return {blocked:[]};
}
export const recover=agent=>exclusive(agent,()=>recoverUnlocked(agent));
export async function claimed(agent,messages,position){
 const items=states(agent);let owned=false;
 for(const message of messages){const item=items.get(message.id);if(!item)continue;assert.ok(!item.legacy_uncertain);
 record(agent,{op:'claimed',id:message.id,logical_turn_id:item.logical_turn_id,...position});owned=true;}
 if(owned){await flush(agent);await checkpoint(agent,'claimed-before-model');}
}
export function shouldAppend(agent,message){
 if(!states(agent).has(message.id))return true;
 const prior=agent.session.snapshotEvents().find(e=>e.type==='user/message'&&e.data.id===message.id);
 if(prior)assert.deepEqual(prior.data,message,'BB projected content changed');return !prior;
}
export async function beforeModel(agent,turn,step,request){
 if(!states(agent).size&&!records(agent).some(r=>['binding','presentation-map'].includes(r.op)))return;
 await confirmPending(agent);
 const actual=new Set(request.messages.map(m=>m.id));const attempt_id=randomUUID();
 for(const item of states(agent).values()){
  if(item.completed||!item.claims.some(c=>c.turn===turn))continue;
  if(!actual.has(item.message.id)){record(agent,{op:'deferred',id:item.message.id,turn,step,reason:'not_in_projected_request'});continue;}
  record(agent,{op:'dispatch',id:item.message.id,logical_turn_id:item.logical_turn_id,attempt_id,turn,step,input_sha256:hash(request.messages),member_ids:[...actual]});
 }
 const proofs=eligiblePresentations(agent,request);
 record(agent,{op:'request-evidence',attempt_id,turn,step,request_digest:hash(request.messages),proofs});
 await flush(agent);await checkpoint(agent,'dispatch-intent-before-call');
}
export async function modelResult(agent,turn,step,message,finishKind){
 const members=[...states(agent).values()].filter(i=>i.dispatches.at(-1)?.turn===turn&&i.dispatches.at(-1)?.step===step);
 const evidence=records(agent).filter(r=>r.op==='request-evidence'&&r.turn===turn&&r.step===step).at(-1);
 if(!members.length&&!evidence)return;
 if(finishKind==='max-tokens')return;
 if(evidence)record(agent,{op:'response-success',attempt_id:evidence.attempt_id,message});
 const calls=message.content.filter(b=>b.type==='tool-call');
 for(const block of calls){
  // ID is assigned to a durable model plan, never inferred from a later model call.
  const digest=intentDigest({...block,name:toolName(agent,block)});
  const prior=plans(agent).find(p=>p.turn!==turn&&writes.has(toolName(agent,block))&&toolName(agent,p.block)===toolName(agent,block)&&p.intent_digest===digest&&p.members.some(id=>members.some(i=>i.message.id===id)));
  if(prior){record(agent,{op:'plan-alias',operation_id:prior.operation_id,turn,step,block_id:block.id});continue;}
  record(agent,{op:'plan',operation_id:'bb_'+randomUUID().replaceAll('-',''),turn,step,members:members.map(i=>i.message.id),block,intent_digest:digest,arguments_sha256:hash(block.arguments)});
 }
 for(const i of members){record(agent,{op:'finished',id:i.message.id,attempt_id:i.dispatches.at(-1).attempt_id,turn,step});if(!calls.length)record(agent,{op:'done',id:i.message.id,logical_turn_id:i.logical_turn_id,attempt_id:evidence?.attempt_id});}
 await flush(agent);await checkpoint(agent,'model-plan-before-tools');
 await confirmPending(agent);
}
const writes=new Set(['send_message','send_attachment','start_download','ack_messages']);
const reads=new Set(['list_users','read_messages','wait_messages','get_download','get_operation','view_avatar','view_nickname','view_signature']);
function findPlan(agent,block,turn,step){const alias=records(agent).find(r=>r.op==='plan-alias'&&r.turn===turn&&r.step===step&&r.block_id===block.id);return plans(agent).find(p=>(block.bbOperationId??alias?.operation_id)?p.operation_id===(block.bbOperationId??alias.operation_id):p.block.id===block.id&&p.turn===turn&&p.step===step);}
function toolName(agent,block){const prefix=agent.bbToolPrefix??"mcp__bb__";return block.name.startsWith(prefix)?block.name.slice(prefix.length):block.name;}
export async function beforeTool(agent,block,turn,step){
 const name=toolName(agent,block);
 const plan=findPlan(agent,block,turn,step);
 if(!plan)return null; // ordinary non-event native calls are unchanged
 if(plan.result)return plan.result;
 let result;
 if(writes.has(name)){
  assert.equal(typeof agent.bbOperationClient,'function','BB local operation bridge required');
  const args=JSON.parse(block.arguments||'{}');args.operation_id=plan.operation_id;
  if(name==='start_download')args.consumer_session=agent.session.id;
  await flush(agent);await checkpoint(agent,'operation-before-submit');
  // Bridge must query first; 404 alone allows an idempotent submit. Transport errors throw.
  if(name==='ack_messages'){assert.equal(args.consumer_session,agent.session.id,'ACK session mismatch');await confirmPending(agent);result=await agent.bbAcknowledge({account:args.account,consumer_session:args.consumer_session,through_position:args.through_position});}
  else result=await agent.bbOperationClient(name,args);
  await checkpoint(agent,'operation-after-submit-before-receipt');
 }else if(reads.has(name)){if(toolName(agent,block)==='wait_messages'){const args=JSON.parse(block.arguments||'{}');assert.equal(args.consumer_session,agent.session.id);(agent.bbWaitingPeers??=new Map()).set(`${turn}:${step}:${block.id}`,args.account);}return null;}
 else result={isError:true,content:[{type:'text',text:'BB_UNSUPPORTED_EFFECT: event tools require a declared local idempotent boundary'}]};
 record(agent,{op:'operation-result',operation_id:plan.operation_id,result});await flush(agent);return result;
}
export async function afterTool(agent,block,result,turn,step){
 if(toolName(agent,block)==='wait_messages')agent.bbWaitingPeers?.delete(`${turn}:${step}:${block.id}`);
 const event=agent.session.snapshotEvents().filter(e=>e.type==='tool/result'&&e.data.message.toolCallId===block.id).at(-1);
 const proofs=result.value?.structuredContent?.bb_presentations??[];
 if(event&&!result.isError&&proofs.length){bindPresentations(agent,event.data.message,proofs,result.value?.content);await flush(agent);}
 const plan=findPlan(agent,block,turn,step);
 if(!plan||plan.result)return;
 record(agent,{op:'operation-result',operation_id:plan.operation_id,result});await flush(agent);
}
export async function recoverPlans(agent,turn,selected){
 const ids=selected??[...states(agent).values()].filter(i=>i.claims.some(c=>c.turn===turn)).map(i=>i.message.id);
 for(const plan of plans(agent).filter(p=>!p.result&&p.members.some(id=>ids.includes(id)))){
  // Reconcile the saved business plan directly. Re-appending native tool/call
  // would invent a tool lifecycle in the new physical turn and corrupt V4 logs.
  const result=await beforeTool(agent,{...plan.block,bbOperationId:plan.operation_id},turn,0);
  if(result===null){
   record(agent,{op:'operation-result',operation_id:plan.operation_id,result:{isError:true,content:[{type:'text',text:'BB_READ_INTERRUPTED: no business operation committed; explicitly read again'}]}});
   await flush(agent);
  }
 }
}
export function recoveredPlan(agent,turn){
 const ids=[...states(agent).values()].filter(i=>i.claims.some(c=>c.turn===turn)).map(i=>i.message.id);
 return plans(agent).some(p=>p.turn!==turn&&p.members.some(id=>ids.includes(id)));
}
export async function afterTurn(agent){agent.bbWaitingPeers?.clear();if(states(agent).size){await flush(agent);await checkpoint(agent,'turn-finished');}}


function intentDigest(block){
 let args;try{args=JSON.parse(block.arguments||'{}');}catch{return hash(block.arguments);}
 if(args&&typeof args==='object')delete args.operation_id;
 const sort=v=>Array.isArray(v)?v.map(sort):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,sort(v[k])])):v;
 return hash([block.name,sort(args)]);
}
export async function prepareContinuation(agent,turn,step,messages){
 const visible=new Set(messages.map(m=>m.id));
 for(const item of states(agent).values()){
  if(item.completed||!item.claims.some(c=>c.turn===turn)||!(visible.has(item.message.id)||item.dispatches.at(-1)?.turn===turn))continue;
  const previous=item.operations.filter(p=>p.turn!==turn);if(!previous.length)continue;
  await recoverPlans(agent,turn,[item.message.id]);
  const operations=plans(agent).filter(p=>p.members.includes(item.message.id)).map(p=>({operation_id:p.operation_id,tool:p.block.name,arguments:p.block.arguments,result:p.result??null}));
  const continuation_id='bb-cont-'+hash(item.logical_turn_id);
  const payload={continuation_id,logical_turn_id:item.logical_turn_id,event_id:item.key.event_id,input_message_id:item.message.id,operations};
  const revision=hash(payload);
  if(records(agent).some(r=>r.op==='continuation'&&r.continuation_id===continuation_id&&r.revision===revision))continue;
  const context=createUserMessage({source:{kind:'runtime-context'},content:[{type:'text',text:'BB_RECOVERY_CONTEXT (runtime facts, not a new user or platform message). Continue the same logical task. Reuse existing operation results; never resend completed output. Pending download acceptance is not completion. New intentional actions require new persisted plans.\n'+JSON.stringify(payload)}]});
  record(agent,{op:'continuation',...payload,revision,phase:'ready',context_message_id:context.id,turn,step});
  agent.session.append('user/message',context,{surfaceOp:'append'});
  await flush(agent);await checkpoint(agent,'continuation-before-model');
 }
}
function encode(content,generic=false){return content.map(b=>b.type==='text'?[...b.text].map(c=>'T'+c.codePointAt(0).toString(16)+';').join(''):b.type==='image'?'I'+(generic?'IMAGE':hash(b))+';':'X'+hash(b)+';').join('');}
function segment(content,proof,generic=false){
 const value=encode(content,generic), start=encode([{type:'text',text:'BB_PRESENTATION_START:'+JSON.stringify({receipt_id:proof.receipt_id,content_digest:proof.content_digest})}]), end=encode([{type:'text',text:'BB_PRESENTATION_END:'+JSON.stringify(proof.receipt_id)}]);
 const a=value.indexOf(start),b=value.indexOf(end,a+start.length);
 if(a<0||b<0||value.indexOf(start,a+1)>=0||value.indexOf(end,b+1)>=0)return null;
 const selected=value.slice(a,b+end.length);
 if((selected.match(generic?/IIMAGE;/g:/I[a-f0-9]{64};/g)??[]).length!==proof.image_count)return null;
 return hash(selected);
}
function projectWire(blocks){
 const output=[],texts=[];const flush=()=>{if(texts.length)output.push({type:'text',text:texts.splice(0).join('\n')});};
 for(const b of blocks){if(b.type==='text')texts.push(b.text);else{flush();output.push({type:b.type});}}flush();return output;
}
function bindPresentations(agent,message,proofs,wire){
 for(const proof of proofs){
  assert.equal(proof.consumer_session,agent.session.id,'presentation session mismatch');
  assert.ok(typeof proof.receipt_id==='string'&&typeof proof.content_digest==='string');
  const account=records(agent).find(r=>r.op==='binding')?.account??[...states(agent).values()][0]?.key.account;
  if(account)assert.deepEqual([proof.sender_account,proof.target_account].sort(),[account,proof.peer_account].sort(),'presentation account mismatch');
  assert.ok(Number.isSafeInteger(proof.position)&&proof.position>0);
  const digest=segment(message.content,proof);if(!digest)continue;
  if(wire&&segment(projectWire(wire),proof,true)!==segment(message.content,proof,true))continue;
  const prior=records(agent).find(r=>r.op==='presentation-map'&&r.receipt_id===proof.receipt_id);
  if(prior){assert.equal(prior.content_digest,proof.content_digest,'receipt content conflict');for(const field of ['message_id','position','peer_account','consumer_session','image_count'])assert.equal(prior[field],proof[field],'receipt binding conflict');}
  record(agent,{op:'presentation-map',...proof,source_message_id:message.id,segment_digest:digest});
 }
}
function eligiblePresentations(agent,request){
 const result=new Map();
 for(const proof of records(agent).filter(r=>r.op==='presentation-map')){
  const source=request.messages.find(m=>m.id===proof.source_message_id);
  if(source&&segment(source.content,proof)===proof.segment_digest)result.set(proof.receipt_id,proof);
 }
 return [...result.values()];
}
export async function confirmPending(agent){
 const all=records(agent),successful=new Set(all.filter(r=>r.op==='response-success').map(r=>r.attempt_id));
 const confirmed=new Set(all.filter(r=>r.op==='presentation-confirmed').map(r=>r.attempt_id));
 for(const request of all.filter(r=>r.op==='request-evidence'&&successful.has(r.attempt_id)&&!confirmed.has(r.attempt_id)&&r.proofs.length)){
  assert.equal(typeof agent.bbConfirmPresentation,'function','BB presentation bridge required');
  const payload={consumer_session:agent.session.id,attempt_id:request.attempt_id,request_digest:request.request_digest,receipt_ids:[...new Set(request.proofs.map(p=>p.receipt_id))]};
  await checkpoint(agent,'presentation-before-confirm');
  const response=await agent.bbConfirmPresentation(payload);
  assert.deepEqual([...response.confirmed_receipt_ids].sort(),[...payload.receipt_ids].sort(),'partial presentation confirmation');
  await checkpoint(agent,'presentation-after-confirm-before-receipt');
  record(agent,{op:'presentation-confirmed',...payload});await flush(agent);
 }
}
export async function configure(agent,account,peer_account){
 assert.match(account,/^[1-9][0-9]{7}$/);assert.match(peer_account,/^[1-9][0-9]{7}$/);
 const prior=records(agent).find(r=>r.op==='binding');
 if(prior){assert.equal(prior.account,account,'account binding mismatch');assert.equal(prior.peer_account,peer_account,'peer binding mismatch');}
 else {for(const item of states(agent).values())assert.equal(item.key.account,account);record(agent,{op:'binding',account,peer_account});await flush(agent);}
 return cursor(agent);
}
export function cursor(agent){return records(agent).filter(r=>r.op==='event-cursor').at(-1)?.cursor??0;}
export async function advanceCursor(agent,account,value){
 const binding=records(agent).find(r=>r.op==='binding');assert.equal(binding?.account,account);
 assert.ok(Number.isSafeInteger(value)&&value>=cursor(agent));record(agent,{op:'event-cursor',account,cursor:value});await flush(agent);
}

export async function ready(agent){await agent.bbInitializeBridge?.();}

function alreadyPresented(agent,proofs){
 if(!proofs.length)return null;
 const all=records(agent),success=new Set(all.filter(r=>r.op==='response-success').map(r=>r.attempt_id));
 return all.find(r=>r.op==='request-evidence'&&success.has(r.attempt_id)&&proofs.every(p=>r.proofs.some(q=>q.message_id===p.message_id&&q.position===p.position&&q.peer_account===p.peer_account&&q.content_digest===p.content_digest)))?.attempt_id??null;
}

function operationStatus(result){
 if(!result)return 'uncertain';if(result.isError)return 'failed';
 try{const status=JSON.parse(result.content[0].text).status;if(['pending','succeeded','failed'].includes(status))return status;}catch{}
 return 'succeeded';
}

export function guardResult(agent,result){
 const account=records(agent).find(r=>r.op==='binding')?.account??[...states(agent).values()][0]?.key.account;
 for(const proof of result.value?.structuredContent?.bb_presentations??[]){
  if(proof.consumer_session!==agent.session.id||(account&&JSON.stringify([proof.sender_account,proof.target_account].sort())!==JSON.stringify([account,proof.peer_account].sort())))
   return {isError:true,content:[{type:'text',text:'BB_PRESENTATION_BINDING_MISMATCH: rejected before native result publication'}]};
 }
 return result;
}
