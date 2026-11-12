// Sentinel's original script is retained verbatim in sentinel/. This is its R2 expectation layer.
import assert from 'node:assert/strict';
import {boot} from '../probes/native/profile.mjs';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {mkdir, writeFile, mkdtemp} from 'node:fs/promises';
const pkg=resolve(process.argv[2]);
const req=createRequire(resolve(pkg,'package.json'));
const {LlmAdapter}=await import(pathToFileURL(req.resolve('@deepseek-ai/dsh-llm')));
await mkdir('dsh-plugin/.evidence',{recursive:true});
const runRoot=await mkdtemp(resolve('dsh-plugin/.evidence/r2-boundaries-'));
for(const mode of ['batch','filtered-batch','co-claimed','co-claimed-filtered','tool-failure']){
 const trace=[];let calls=0;
 const runtime=await boot(pkg,resolve(runRoot,mode),(kind,data)=>trace.push({kind,...data}));
 class Model extends LlmAdapter{
  async resolveModel(provider,id){return {provider,id,name:'DETERMINISTIC DOUBLE',inputModalities:['text'],context:{contextWindow:8192}};}
  async *stream(options){
   calls++;trace.push({kind:'qa.request',ids:options.messages.map(m=>m.id)});
   const tool=mode==='tool-failure'&&calls===1;
   yield {type:'block-start',index:0,blockType:tool?'tool-call':'text'};
   yield {type:'block-end',index:0,block:tool?{type:'tool-call',id:'qa-missing-tool-1',name:'qa_nonexistent_tool',arguments:'{}'}:{type:'text',text:'QA response'}};
   yield {type:'finish',reason:{kind:tool?'tool-calls':'stop'}};
  }
 }
 const unregister=runtime.ctx.llm.registerAdapter(['qa-boundary'],new Model());
 let filtered=mode.endsWith('filtered')||mode==='filtered-batch';
 runtime.ctx.on('agent/pre-step',async(payload,next)=>{const decision=await next();return filtered&&decision.kind==='enter'?{...decision,messages:decision.messages.slice(0,1)}:decision;});
 const handle=await runtime.ctx.agents.create({sessionId:mode,agentOptions:{provider:'qa-boundary',model:'deterministic'}});
 const agent=handle.agent;
 const keys=[1,2].map(n=>({account:'10000001',session_id:mode,event_id:`qa-${n}`}));
 const selected=mode==='tool-failure'?keys.slice(0,1):keys;
 await agent.runMaintenance(async()=>{
  if(mode==='filtered-batch')agent.send({id:'qa-other',role:'user',source:{kind:'user'},content:[{type:'text',text:'other'}]},'next-step',false);
  for(const key of selected)await agent.bbDeliver(key,[{type:'text',text:key.event_id}]);
  if(mode.startsWith('co-claimed')){const m=agent.inbox.nextTurn[0];agent.inbox.splice('next-turn',0,1,[]);agent.inbox.append('next-step',m);}
 });
 await agent.whenIdle();await runtime.ctx.sessions.flush(agent.session);
 const before=selected.map(k=>agent.bbDeliveryStatus(k));
 if(filtered){
  const deferred=before.filter(s=>s.state==='deferred');assert.equal(deferred.length,1);
  assert.equal(deferred[0].consumed_through,null);
  assert.ok(trace.filter(e=>e.kind==='qa.request').every(r=>!r.ids.includes(deferred[0].logical_turn_id)));
 }else assert.ok(before.every(s=>s.state==='completed'));
 if(mode==='tool-failure'){
  assert.equal(before[0].operations[0].status,'failed');assert.equal(before[0].consumed_through,null);
  assert.ok(agent.session.snapshotEvents().some(e=>e.type==='tool/result'&&e.data.message.isError));
 }
 filtered=false;
 for(const k of selected)await agent.bbDeliver(k,[{type:'text',text:k.event_id}]);
 await agent.whenIdle();
 const after=selected.map(k=>agent.bbDeliveryStatus(k));assert.ok(after.every(s=>s.state==='completed'));
 const previous=calls;
 for(const k of selected)await agent.bbDeliver(k,[{type:'text',text:k.event_id}]);
 await agent.whenIdle();assert.equal(calls,previous);
 assert.ok(!trace.some(e=>e.kind==='agent.error'),JSON.stringify(trace.filter(e=>e.kind==='agent.error')));
 await writeFile(resolve(runRoot,mode+'.json'),JSON.stringify({before,after,calls,trace,events:agent.session.snapshotEvents()},null,2));
 console.log(JSON.stringify({mode,calls,before:before.map(s=>s.state),after:after.map(s=>s.state)}));
 await handle.dispose();unregister();await runtime.close();
}
console.log(JSON.stringify({evidence:runRoot}));
