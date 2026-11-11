import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
import {mkdir,writeFile} from 'node:fs/promises';
import {boot} from '../probes/native/profile.mjs';
import {setupRuntimeBridge} from './runtime-bridge.mjs';
import {clientDouble} from './client-double.mjs';
const [pkg,root,phase,sessionId]=process.argv.slice(2);
await mkdir(root,{recursive:true});
const req=createRequire(resolve(pkg,'package.json'));
const load=name=>import(pathToFileURL(req.resolve('@deepseek-ai/'+name)));
const {LlmAdapter}=await load('dsh-llm');
const local=await clientDouble(resolve(root,sessionId+'-client.json'),sessionId);
const trace=[];let calls=0,bridge;
const runtime=await boot(pkg,resolve(root,'sessions'),(kind,data)=>trace.push({kind,...data}));
const attachment=await load('dsh-attachment-local');
const fiber=await runtime.ctx.plugin(attachment.default,{dshHome:resolve(root,'isolated-images')});
class Model extends LlmAdapter{
 async resolveModel(provider,id){return {provider,id,name:'DETERMINISTIC IMAGE-CAPABLE DOUBLE',inputModalities:['text','image'],context:{contextWindow:8192}};}
 async *stream(request){calls++;trace.push({kind:'actual.request',request});yield {type:'block-start',index:0,blockType:'text'};yield {type:'block-end',index:0,block:{type:'text',text:'successful synthetic response'}};yield {type:'finish',reason:{kind:'stop'}};}
}
const unregister=runtime.ctx.llm.registerAdapter(['r3-presentation'],new Model());
runtime.ctx.on('bb-recovery/checkpoint',async({agent,phase:edge})=>{if(phase===edge){await runtime.ctx.sessions.flush(agent.session);process.send?.({kind:'checkpoint',phase});await new Promise(()=>{});}});
let filtered=phase==='filtered';
runtime.ctx.on('agent/pre-step',async(payload,next)=>{const decision=await next();return filtered&&decision.kind==='enter'?{...decision,messages:decision.messages.slice(0,1)}:decision;});
const options={agentOptions:{provider:'r3-presentation',model:'synthetic'},setup:setupRuntimeBridge({origin:local.origin,account:'10000001',peer_account:'10000002'},value=>bridge=value)};
const resumed=['recover','recover-admission','replay'].includes(phase);
const handle=resumed?await runtime.ctx.agents.resume({...options,resumeSessionId:sessionId}):await runtime.ctx.agents.create({...options,sessionId});
const agent=handle.agent;
if(!resumed){
 await local.publish(local.messageEvent(1));
 if(filtered)await local.publish(local.messageEvent(2));
 await agent.runMaintenance(async()=>{
  await bridge.pumpOnce();
  if(filtered){const first=agent.inbox.nextTurn[0];agent.inbox.splice('next-turn',0,1,[]);agent.inbox.append('next-step',first);}
 });
}
await agent.whenIdle();await runtime.ctx.sessions.flush(agent.session);
assert.ok(['control','filtered','recover','recover-admission','replay'].includes(phase),'checkpoint not reached');
assert.equal(local.state.confirmed['receipt-1'],true,'actual projected image/text proof should confirm');
assert.equal(local.state.acks,0,'confirmation must never ACK');
if(filtered){
 assert.ok(!local.state.confirmed['receipt-2']);
 const failed=await agent.bbAcknowledge({account:'10000002',consumer_session:sessionId,through_position:2});assert.equal(failed.isError,true);
 filtered=false;await agent.bbRecoverDeliveries();await agent.whenIdle();
 assert.equal(local.state.confirmed['receipt-2'],true);
 const ok=await agent.bbAcknowledge({account:'10000002',consumer_session:sessionId,through_position:2});assert.equal(ok.isError,false);assert.equal(local.state.acks,2);
 await local.publish(local.messageEvent(3));await bridge.pumpOnce();await agent.whenIdle();assert.equal(local.state.acks,2,'later message remains unconsumed');
}
if(resumed)assert.equal(calls,phase==='recover-admission'?1:0,'confirmation retry cannot rerun inference; accepted-only input must recover');
const before=calls;await bridge.pumpOnce();await agent.whenIdle();assert.equal(calls,before,'cursor replay must not restart completed event');
assert.ok(!trace.some(e=>e.kind==='agent.error'),JSON.stringify(trace.filter(e=>e.kind==='agent.error')));
await writeFile(resolve(root,sessionId+'-'+phase+'.json'),JSON.stringify({calls,state:local.state,trace,events:agent.session.snapshotEvents()},null,2));
process.send?.({kind:'result',phase,calls,acks:local.state.acks,cursor:agent.bbEventCursor()});
await handle.dispose();unregister();await fiber.dispose();await runtime.close();await local.close();process.disconnect?.();
