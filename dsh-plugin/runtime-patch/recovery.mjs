// Pinned native hooks: the DSH driver remains the only scheduler.
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { appendPluginRecord, pluginRecordOf } from '@deepseek-ai/dsh-session';
const RECORD='plugin:bb/delivery-v1', PREFIX='bb-event-', VERSION='bb-recovery-2';
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
 assert.ok(['bb-recovery-1',VERSION].includes(entry.data.version),'unsupported BB recovery version');
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
   items.set(id,{...data,accepted_seq:data.seq,claims:[],dispatches:[],deferred:[],finished:[],settled:[]});
  }else if(['claimed','dispatch','deferred','finished','settled'].includes(data.op)){
   const item=items.get(data.id);assert.ok(item,'BB record without acceptance');
   item[{claimed:'claims',dispatch:'dispatches',deferred:'deferred',finished:'finished',settled:'settled'}[data.op]].push(data);
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
  item.completed=!!last&&last.version===VERSION&&((completedTurns.has(last.turn)&&item.finished.some(f=>f.attempt_id===last.attempt_id))||item.settled.some(s=>completedTurns.has(s.turn)));
  // Legacy dispatch records lack request membership and side-effect barriers. Never adopt them as proof.
  item.legacy_uncertain=!!last&&last.version!==VERSION;
  item.pending=pending.has(item.message.id);
  item.state=item.legacy_uncertain?'legacy_uncertain':item.completed?'completed':item.pending?'accepted_pending':item.deferred.at(-1)?.seq>(last?.seq??0)?'deferred':last?'reasoning_recoverable':'accepted_recoverable';
 }
 return items;
}
export function status(agent,key){
 const i=states(agent).get(identity(agent,key));
 return i?{state:i.state,logical_turn_id:i.logical_turn_id,accepted_seq:i.accepted_seq,claims:i.claims,dispatches:i.dispatches,
 operations:i.operations.map(p=>({operation_id:p.operation_id,status:p.result?(p.result.isError?'failed':'succeeded'):'uncertain'})),consumed_through:null}:{state:'absent',consumed_through:null};
}
export function deliver(agent,key,content){
 key=structuredClone(key);content=structuredClone(content);
 return exclusive(agent,async()=>{
  const id=identity(agent,key),items=states(agent);
  for(const item of items.values())assert.equal(item.key.account,key.account,'account binding mismatch');
  const message={id,role:'user',source:{kind:'user'},content},prior=items.get(id);
  if(prior)assert.deepEqual(prior.message,message,'same event key with different content');
  if(!prior){record(agent,{op:'accepted',key,logical_turn_id:id,message});agent.send(message,'next-turn',false);await flush(agent);await checkpoint(agent,'accepted-before-receipt');}
  await recoverUnlocked(agent);return {...status(agent,key),disposition:prior?'existing':'new'};
 });
}
async function recoverUnlocked(agent){
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
 const actual=new Set(request.messages.map(m=>m.id));const attempt_id=randomUUID();
 for(const item of states(agent).values()){
  if(item.completed||!item.claims.some(c=>c.turn===turn))continue;
  if(!actual.has(item.message.id)){record(agent,{op:'deferred',id:item.message.id,turn,step,reason:'not_in_projected_request'});continue;}
  record(agent,{op:'dispatch',id:item.message.id,logical_turn_id:item.logical_turn_id,attempt_id,turn,step,input_sha256:hash(request.messages),member_ids:[...actual]});
 }
 if(states(agent).size){await flush(agent);await checkpoint(agent,'dispatch-intent-before-call');}
}
export async function modelResult(agent,turn,step,message){
 const members=[...states(agent).values()].filter(i=>i.dispatches.at(-1)?.turn===turn&&i.dispatches.at(-1)?.step===step);
 if(!members.length)return;
 const calls=message.content.filter(b=>b.type==='tool-call');
 for(const block of calls){
  // ID is assigned to a durable model plan, never inferred from a later model call.
  record(agent,{op:'plan',operation_id:'bb_'+randomUUID().replaceAll('-',''),turn,step,members:members.map(i=>i.message.id),block,arguments_sha256:hash(block.arguments)});
 }
 for(const i of members)record(agent,{op:'finished',id:i.message.id,attempt_id:i.dispatches.at(-1).attempt_id,turn,step});
 await flush(agent);await checkpoint(agent,'model-plan-before-tools');
}
const writes=new Set(['send_message','send_attachment','start_download']);
const reads=new Set(['list_users','read_messages','wait_messages','get_download','get_operation','view_avatar','view_nickname','view_signature']);
function findPlan(agent,block,turn,step){return plans(agent).find(p=>block.bbOperationId?p.operation_id===block.bbOperationId:p.block.id===block.id&&p.turn===turn&&p.step===step);}
export async function beforeTool(agent,block,turn,step){
 const plan=findPlan(agent,block,turn,step);
 if(!plan)return null; // ordinary non-event native calls are unchanged
 if(plan.result)return plan.result;
 let result;
 if(writes.has(block.name)){
  assert.equal(typeof agent.bbOperationClient,'function','BB local operation bridge required');
  const args=JSON.parse(block.arguments||'{}');args.operation_id=plan.operation_id;
  if(block.name==='start_download')args.consumer_session=agent.session.id;
  await flush(agent);await checkpoint(agent,'operation-before-submit');
  // Bridge must query first; 404 alone allows an idempotent submit. Transport errors throw.
  result=await agent.bbOperationClient(block.name,args);
  await checkpoint(agent,'operation-after-submit-before-receipt');
 }else if(reads.has(block.name))return null;
 else result={isError:true,content:[{type:'text',text:'BB_UNSUPPORTED_EFFECT: event tools require a declared local idempotent boundary'}]};
 record(agent,{op:'operation-result',operation_id:plan.operation_id,result});await flush(agent);return result;
}
export async function afterTool(agent,block,result,turn,step){
 const plan=findPlan(agent,block,turn,step);
 if(!plan||plan.result)return;
 record(agent,{op:'operation-result',operation_id:plan.operation_id,result});await flush(agent);
}
export async function recoverPlans(agent,turn){
 const ids=[...states(agent).values()].filter(i=>i.claims.some(c=>c.turn===turn)).map(i=>i.message.id);
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
export async function finishRecovered(agent,turn,step,request){
 // Recovery executes the persisted plan, not a new provider request.
 for(const item of states(agent).values()){
  if(!item.completed&&item.claims.some(c=>c.turn===turn)&&item.operations.length&&item.operations.every(p=>p.result))
   record(agent,{op:'settled',id:item.message.id,logical_turn_id:item.logical_turn_id,turn,step});
 }
 await flush(agent);
}
export async function afterTurn(agent){if(states(agent).size){await flush(agent);await checkpoint(agent,'turn-finished');}}
