// Real native runtime/storage with an explicitly synthetic, durable local-client double.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,writeFile,open,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {boot} from '../probes/native/profile.mjs';
import {setupLocalBridge} from './local-bridge.mjs';
const [pkg,root,phase,sessionId]=process.argv.slice(2);
const req=createRequire(resolve(pkg,'package.json'));
const {LlmAdapter}=await import(pathToFileURL(req.resolve('@deepseek-ai/dsh-llm')));
await mkdir(root,{recursive:true});
const emit=(kind,data)=>process.send?.({kind,...data});
const dataPath=resolve(root,sessionId+'-client-double.json');
let saved={operations:{},business_commits:0};try{saved=JSON.parse(await readFile(dataPath,'utf8'));}catch(e){assert.equal(e.code,'ENOENT');}
const server=createServer(async(request,response)=>{
 let raw='';for await(const chunk of request)raw+=chunk;const body=JSON.parse(raw);
 let status=200,result;
 if(request.url==='/operations/get'){
  if(saved.operations[body.operation_id])result=saved.operations[body.operation_id].result;
  else {status=404;result={error:{code:'not_found'}};}
 }else if(request.url==='/chat/send_message'){
  if(saved.operations[body.operation_id]){assert.deepEqual(saved.operations[body.operation_id].args,body);result=saved.operations[body.operation_id].result.message;}
  else{
   saved.business_commits++;result={id:'synthetic-message-'+saved.business_commits,position:saved.business_commits};
   saved.operations[body.operation_id]={operation_id:body.operation_id,args:body,result:{operation_id:body.operation_id,kind:'message',status:'succeeded',message:result}};
   const file=await open(dataPath,'w');await file.writeFile(JSON.stringify(saved));await file.sync();await file.close();
  }
 }else{status=404;result={};}
 response.writeHead(status,{'content-type':'application/json'});response.end(JSON.stringify(result));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const trace=[];let calls=0;
const runtime=await boot(pkg,resolve(root,'sessions'),(kind,data)=>trace.push({kind,...data}));
class Model extends LlmAdapter{
 async resolveModel(provider,id){return {provider,id,name:'DETERMINISTIC DOUBLE',inputModalities:['text'],context:{contextWindow:8192}};}
 async *stream(options){
  if(phase==='recover')assert.ok(options.messages.some(m=>m.content.some(b=>b.type==='text'&&b.text.includes('BB_RECOVERY_CONTEXT'))),'must continue with actual recovery facts');
  calls++;if(phase==='provider-before-output'){emit('checkpoint',{phase,provider_entered:true});await new Promise(()=>{});}const tool=calls===1||(phase==='recover-new'&&calls===2);
  yield {type:'block-start',index:0,blockType:tool?'tool-call':'text'};
  yield {type:'block-end',index:0,block:tool?{type:'tool-call',id:sessionId+'-'+phase+'-'+calls,name:'mcp__bb__send_message',arguments:JSON.stringify({target_account:'10000002',content:[{type:'text',text:phase==='recover-new'&&calls===2?'new intentional followup':'synthetic reply'}]})}:{type:'text',text:'finished'}};
  yield {type:'finish',reason:{kind:tool?'tool-calls':'stop'}};
 }
}
const unregister=runtime.ctx.llm.registerAdapter(['operation-double'],new Model());
runtime.ctx.on('bb-recovery/checkpoint',async({agent,phase:edge})=>{
 if(edge===phase){await runtime.ctx.sessions.flush(agent.session);emit('checkpoint',{phase});await new Promise(()=>{});}
});
const options={agentOptions:{provider:'operation-double',model:'deterministic'},setup:setupLocalBridge('http://127.0.0.1:'+server.address().port)};
const resume=phase.startsWith('recover')||phase==='replay'||phase==='continuation-before-model';
const handle=resume?await runtime.ctx.agents.resume({...options,resumeSessionId:sessionId}):await runtime.ctx.agents.create({...options,sessionId});
const agent=handle.agent,key={account:'10000001',session_id:sessionId,event_id:'business-event'};
await Promise.all(Array.from({length:12},()=>agent.bbDeliver(key,[{type:'text',text:'send a reply'}])));
await agent.whenIdle();await runtime.ctx.sessions.flush(agent.session);
assert.ok(['control','recover','recover-inference','recover-new','replay'].includes(phase),'crash point not hit');
const state=agent.bbDeliveryStatus(key);
const continuations=agent.session.snapshotEvents().filter(e=>e.type==='plugin:bb/delivery-v1'&&e.data.op==='continuation');
if(continuations.length){assert.equal(new Set(continuations.map(e=>e.data.continuation_id)).size,1);assert.ok(continuations.every(e=>e.data.logical_turn_id===state.logical_turn_id));}
assert.equal(state.state,'completed');assert.equal(state.consumed_through,null);
const expected=sessionId==='new-intent'?2:1;assert.equal(saved.business_commits,expected);assert.equal(new Set(state.operations.map(p=>p.operation_id)).size,expected);
assert.ok(state.operations.every(p=>p.status==='succeeded'));
assert.ok(!trace.some(e=>e.kind==='agent.error'),JSON.stringify(trace.filter(e=>e.kind==='agent.error')));
if(resume)assert.equal(calls,phase==='replay'?0:phase==='recover-new'?3:2,'reasoning resumes only when no saved business plan exists');
await writeFile(resolve(root,sessionId+'-'+phase+'.json'),JSON.stringify({state,provider_calls:calls,client_double:saved,events:agent.session.snapshotEvents(),trace},null,2));
emit('result',{phase,state,business_commits:saved.business_commits,provider_calls:calls});
await handle.dispose();unregister();await runtime.close();await new Promise(resolve=>server.close(resolve));process.disconnect?.();
