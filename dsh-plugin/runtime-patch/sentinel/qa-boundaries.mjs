import assert from 'node:assert/strict';
import {boot} from './BB/dsh-plugin/probes/native/profile.mjs';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {mkdir, writeFile, mkdtemp} from 'node:fs/promises';
const pkg=resolve('BB/dsh-plugin/.runtime/sentinel-rc5');
const req=createRequire(resolve(pkg,'package.json'));
const {LlmAdapter}=await import(pathToFileURL(req.resolve('@deepseek-ai/dsh-llm')));
await mkdir('qa-evidence',{recursive:true});
const runRoot=await mkdtemp(resolve('qa-evidence/run-'));
for (const mode of ['batch','filtered-batch','co-claimed','co-claimed-filtered','tool-failure']) {
 const trace=[];
 const runtime=await boot(pkg,resolve(runRoot,mode),(kind,data)=>trace.push({kind,...data}));
 let calls=0;
 class Model extends LlmAdapter {
  async resolveModel(provider,id){return {provider,id,name:'QA deterministic',inputModalities:['text'],context:{contextWindow:8192}};}
  async *stream(options){
   calls++; trace.push({kind:'qa.request',ids:options.messages.map(m=>m.id)});
   if(mode==='tool-failure' && calls===1){
    yield {type:'block-start',index:0,blockType:'tool-call'};
    yield {type:'block-end',index:0,block:{type:'tool-call',id:'qa-missing-tool-1',name:'qa_nonexistent_tool',arguments:'{}'}};
    yield {type:'finish',reason:{kind:'tool-calls'}};
   }else{
    yield {type:'block-start',index:0,blockType:'text'};
    yield {type:'text-delta',index:0,text:'QA deterministic response'};
    yield {type:'block-end',index:0,block:{type:'text',text:'QA deterministic response'}};
    yield {type:'finish',reason:{kind:'stop'}};
   }
  }
 }
 const unregister=runtime.ctx.llm.registerAdapter(['qa-boundary'],new Model());
 if(mode.endsWith('filtered')||mode==='filtered-batch')runtime.ctx.on('agent/pre-step',async (payload,next)=>{
   const decision=await next();
   return decision.kind==='enter'?{...decision,messages:decision.messages.slice(0,1)}:decision;
 });
 const handle=await runtime.ctx.agents.create({sessionId:mode,agentOptions:{provider:'qa-boundary',model:'deterministic'}});
 const agent=handle.agent;
 const keys=[1,2].map(n=>({account:'10000001',session_id:mode,event_id:`qa-${n}`}));
 const selected=mode==='tool-failure'?keys.slice(0,1):keys;
 await agent.runMaintenance(async()=>{
  if(mode==='filtered-batch')agent.send({id:'qa-other',role:'user',source:{kind:'user'},content:[{type:'text',text:'other input'}]},'next-step',false);
  for(const key of selected)await agent.bbDeliver(key,[{type:'text',text:key.event_id}]);
  // QA-only native queue operation: move one accepted input to next-step.
  // This exercises native mixed-batch claim; bbDeliver itself only uses next-turn.
  if(mode.startsWith('co-claimed')){
   const message=agent.inbox.nextTurn[0];
   agent.inbox.splice('next-turn',0,1,[]);
   agent.inbox.append('next-step',message);
  }
 });
 await agent.whenIdle();
 await runtime.ctx.sessions.flush(agent.session);
 const states=selected.map(k=>agent.bbDeliveryStatus(k));
 const events=agent.session.snapshotEvents();
 const result={mode,calls,states,requests:trace.filter(e=>e.kind==='qa.request'),events};
 await writeFile(`qa-evidence/${mode}.json`,JSON.stringify(result,null,2));
 assert.ok(states.every(s=>s.state==='completed'));
 if(mode==='batch'){
  assert.equal(calls,2);
  assert.equal(new Set(states.flatMap(s=>s.claims.map(c=>c.turn))).size,2);
  assert.ok(states.every(s=>result.requests.some(r=>r.ids.includes(s.logical_turn_id))));
 }
 if(mode==='filtered-batch'){
  assert.equal(calls,2);
  assert.ok(!events.some(e=>e.type==='user/message'&&e.data.id===states[0].logical_turn_id));
  assert.ok(result.requests.every(r=>!r.ids.includes(states[0].logical_turn_id)));
 }
 if(mode==='tool-failure'){
  assert.equal(calls,2);
  assert.ok(events.some(e=>e.type==='tool/result'&&e.data.message.isError));
 }
 if(mode.startsWith('co-claimed')){
  assert.equal(calls,1);
  assert.equal(new Set(states.flatMap(s=>s.claims.map(c=>c.turn))).size,1);
  if(mode==='co-claimed')assert.ok(states.every(s=>result.requests[0].ids.includes(s.logical_turn_id)));
  else assert.ok(!result.requests[0].ids.includes(states[1].logical_turn_id));
 }
 const previousCalls=calls;
 for(const key of selected)await agent.bbDeliver(key,[{type:'text',text:key.event_id}]);
 await agent.whenIdle();
 assert.equal(calls,previousCalls);
 assert.deepEqual(agent.session.snapshotEvents(),events);
 console.log(JSON.stringify({mode,calls,states:states.map(s=>s.state),counterexample:!['batch','co-claimed'].includes(mode)}));
 await handle.dispose();unregister();await runtime.close();
}
