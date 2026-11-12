// Real FastAPI + unmodified Dart client + native MCP/DSH; only provider is synthetic.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
import {writeFile} from 'node:fs/promises';
import {boot} from '../probes/native/profile.mjs';
import {setupProductBridge} from './native-setup.mjs';
const [pkg,root,origin,account,peer,phase,sessionId]=process.argv.slice(2);
const req=createRequire(resolve(pkg,'package.json'));
const load=name=>import(pathToFileURL(req.resolve('@deepseek-ai/'+name)));
const {LlmAdapter}=await load('dsh-llm');
const trace=[];let calls=0,bridge;
const runtime=await boot(pkg,resolve(root,'sessions'),(kind,data)=>trace.push({kind,...data}));
const fiber=await runtime.ctx.plugin((await load('dsh-attachment-local')).default,{dshHome:resolve(root,'images')});
class Model extends LlmAdapter{
 async resolveModel(provider,id){return {provider,id,name:'DETERMINISTIC LIVE-CHAIN TEST PROVIDER',inputModalities:['text','image'],context:{contextWindow:32768}};}
 async *stream(request){
  calls++;trace.push({kind:'actual.request',request});
  let tool;
  if(sessionId==='live-continuation'){
   if(phase==='recover')assert.ok(request.messages.some(m=>m.content.some(b=>b.type==='text'&&b.text.includes('BB_RECOVERY_CONTEXT'))));
   if(calls===1)tool={name:'send_message',args:{target_account:peer,content:[{type:'text',text:'stable recovered output'}]}};
  }else if(sessionId==='live-mcp'){
   if(calls===1)tool={name:'read_messages',args:{account:peer,consumer_session:sessionId,after_position:0,limit:1}};
   if(calls===2)tool={name:'ack_messages',args:{account:peer,consumer_session:sessionId,through_position:1}};
  }
  yield {type:'block-start',index:0,blockType:tool?'tool-call':'text'};
  yield {type:'block-end',index:0,block:tool?{type:'tool-call',id:phase+'-'+calls,name:'mcp__bb__'+tool.name,arguments:JSON.stringify(tool.args)}:{type:'text',text:'deterministic inference complete; not a platform message'}};
  yield {type:'finish',reason:{kind:tool?'tool-calls':'stop'}};
 }
}
const unregister=runtime.ctx.llm.registerAdapter(['live-test'],new Model());
runtime.ctx.on('bb-recovery/checkpoint',async({agent,phase:edge})=>{
 if(phase===edge){await runtime.ctx.sessions.flush(agent.session);console.log('KILL_CHECKPOINT '+edge);await new Promise(()=>{});}
});
let handle;
try{
 const options={agentOptions:{provider:'live-test',model:'deterministic'},setup:setupProductBridge({mcpModule:await load('dsh-mcp-client'),pluginDirectory:resolve('dsh-plugin'),origin,account,peer_account:peer},b=>bridge=b)};
 handle=['recover','replay'].includes(phase)?await runtime.ctx.agents.resume({...options,resumeSessionId:sessionId}):await runtime.ctx.agents.create({...options,sessionId});
 const agent=handle.agent,key={account,session_id:sessionId,event_id:'initial'};
 if(sessionId==='live-events'){
  let count=0;
  for(let i=0;i<30&&!count;i++){const page=await bridge.pumpOnce();count+=page.items.length;if(!count)await new Promise(r=>setTimeout(r,100));}
  assert.ok(count>0,'actual Dart feed must publish backlog');
 }else await Promise.all(Array.from({length:12},()=>agent.bbDeliver(key,[{type:'text',text:'integration test task'}])));
 await agent.whenIdle();await runtime.ctx.sessions.flush(agent.session);
 assert.ok(!trace.some(e=>e.kind==='agent.error'),JSON.stringify(trace.filter(e=>e.kind==='agent.error')));
 if(phase==='replay')assert.equal(calls,0);
 if(phase==='recover')assert.equal(calls,2);
 const result={phase,sessionId,calls,state:sessionId==='live-events'?null:agent.bbDeliveryStatus(key),events:agent.session.snapshotEvents(),trace};
 if(result.state)assert.equal(result.state.state,'completed');
 await writeFile(resolve(root,sessionId+'-'+phase+'.json'),JSON.stringify(result,null,2));
 console.log(JSON.stringify({phase,sessionId,calls,result:'PASS'}));
}finally{
 if(handle)await handle.dispose();unregister();await fiber.dispose();await runtime.close();
}
