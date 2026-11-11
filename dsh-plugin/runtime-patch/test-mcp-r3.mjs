// Actual Python MCP stdio -> pinned native MCP projection -> actual model request.
// Only the model and local client business implementation are deterministic doubles.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
import {mkdtemp,writeFile} from 'node:fs/promises';
import {boot} from '../probes/native/profile.mjs';
import {clientDouble} from './client-double.mjs';
import {setupRuntimeBridge} from './runtime-bridge.mjs';
import {setupProductBridge,productMcpConfig} from './native-setup.mjs';
const pkg=resolve(process.argv[2]), root=await mkdtemp(resolve('dsh-plugin/.evidence/r3-mcp-'));
assert.equal(productMcpConfig({origin:'http://127.0.0.1:12345',pluginDirectory:resolve('dsh-plugin')}).toolCallTimeoutMs,130000);
const req=createRequire(resolve(pkg,'package.json'));
const load=name=>import(pathToFileURL(req.resolve('@deepseek-ai/'+name)));
const {Client}=await import(pathToFileURL(req.resolve('@modelcontextprotocol/client')));
const {StdioClientTransport}=await import(pathToFileURL(req.resolve('@modelcontextprotocol/client/stdio')));
const {LlmAdapter}=await load('dsh-llm'), {createMcpToolDefinition}=await load('dsh-mcp-client');
for(const mode of ['mcp','image-refusal','busy-wait','busy-download','product-profile','partial-projection','account-mismatch']){
 const local=await clientDouble(resolve(root,mode+'-client.json'),mode,{initialMessages:mode==='busy-wait'?0:3,targetAccount:mode==='account-mismatch'?'10000003':'10000001'});
 const trace=[],runtime=await boot(pkg,resolve(root,mode+'-sessions'),(kind,data)=>trace.push({kind,...data}));
 const attachment=await load('dsh-attachment-local');
 const fiber=await runtime.ctx.plugin(attachment.default,{dshHome:resolve(root,mode+'-images')});
 const client=new Client({name:'bb-r3-test',version:'1.0.0'});
 const transport=new StdioClientTransport({command:'uv',args:['run','--project',resolve('dsh-plugin'),'--locked','bb-dsh-plugin'],env:{PATH:process.env.PATH,LANG:'C.UTF-8',UV_OFFLINE:'1',BB_CLIENT_BASE_URL:local.origin},stderr:'pipe'});
 let handle,unregister,bridge,calls=0,active=0,maxActive=0,releaseModel,enteredModel;
 const modelEntered=new Promise(resolve=>enteredModel=resolve),modelHold=new Promise(resolve=>releaseModel=resolve);
 const disposers=[];
 try{
  if(mode!=='product-profile'){
  await client.connect(transport);
  const listed=await client.listTools();assert.equal(listed.tools.length,17);assert.ok(!listed.tools.some(t=>t.name==='confirm_presentation'||t.name.startsWith('events_')));
  for(const tool of listed.tools){
   const definition=createMcpToolDefinition(runtime.ctx,{name:'mcp__bb__'+tool.name,rawName:tool.name,description:tool.description,inputSchema:tool.inputSchema,call:(args)=>client.callTool({name:tool.name,arguments:args},{timeout:130000})});
   if(mode==='partial-projection'&&tool.name==='read_messages'){
    const project=definition.projectContent;
    definition.projectContent=(exec,result)=>{
     const projected=project(exec,result);
     const receipts=result.value?.structuredContent?.bb_presentations??[];
     if(!projected||!receipts.some(p=>p.receipt_id==='receipt-1')||!receipts.some(p=>p.receipt_id==='receipt-2'))return projected;
     const output=[];
     for(const b of projected){
      const cut=b.type==='text'?b.text.indexOf('BB_PRESENTATION_START:{"receipt_id":"receipt-2"'):-1;
      if(cut>=0){if(cut)output.push({type:'text',text:b.text.slice(0,cut)});break;}output.push(b);
     }
     return output;
    };
   }
   disposers.push(runtime.ctx.tools.register(definition));
  }
  }
  class Model extends LlmAdapter{
   async resolveModel(provider,id){return {provider,id,name:'DETERMINISTIC DOUBLE',inputModalities:mode==='image-refusal'?['text']:['text','image'],context:{contextWindow:8192}};}
   async *stream(request){
    calls++;active++;maxActive=Math.max(maxActive,active);trace.push({kind:'actual.request',request});
    try{
     if(mode==='busy-download'&&calls===1){enteredModel();await modelHold;}
     let tool;
     if(mode!=='busy-download'&&(calls===1||(mode==='partial-projection'&&calls===4)))tool={name:mode==='busy-wait'?'wait_messages':'read_messages',args:mode==='busy-wait'?{account:'10000002',consumer_session:mode,seen_position:0,timeout:120}:{account:'10000002',consumer_session:mode,after_position:mode==='partial-projection'&&calls===4?1:0,limit:mode==='partial-projection'&&calls===1?2:1}};
     if((['mcp','image-refusal','product-profile','partial-projection','account-mismatch'].includes(mode)&&calls===2)||(mode==='partial-projection'&&calls===5))tool={name:'ack_messages',args:{account:'10000002',consumer_session:mode,through_position:mode==='partial-projection'?2:1}};
     yield {type:'block-start',index:0,blockType:tool?'tool-call':'text'};
     yield {type:'block-end',index:0,block:tool?{type:'tool-call',id:mode+'-'+calls,name:'mcp__bb__'+tool.name,arguments:JSON.stringify(tool.args)}:{type:'text',text:'synthetic final response'}};
     yield {type:'finish',reason:{kind:tool?'tool-calls':'stop'}};
    }finally{active--;}
   }
  }
  unregister=runtime.ctx.llm.registerAdapter(['r3-mcp'],new Model());
  handle=await runtime.ctx.agents.create({sessionId:mode,agentOptions:{provider:'r3-mcp',model:'synthetic'},setup:mode==='product-profile'?setupProductBridge({mcpModule:await load('dsh-mcp-client'),pluginDirectory:resolve('dsh-plugin'),origin:local.origin,account:'10000001',peer_account:'10000002'},b=>bridge=b):setupRuntimeBridge({origin:local.origin,account:'10000001',peer_account:'10000002'},b=>bridge=b)});
  const agent=handle.agent;
  await agent.bbDeliver({account:'10000001',session_id:mode,event_id:'initial'},[{type:'text',text:'synthetic test task'}]);
  if(mode==='busy-wait'){
   await local.waitStarted;await local.publish(local.messageEvent(1),false);await bridge.pumpOnce();local.releaseWait();
  }
  if(mode==='busy-download'){
   await modelEntered;
   for(const success of [true,false])await local.publish({version:1,event_id:'download-'+success,account:'10000001',consumer_session:mode,type:success?'download.succeeded':'download.failed',operation_id:'op-'+success,task_id:'task-'+success,...success?{actual_path:'/synthetic/saved.pdf'}:{error_code:'download_failed'}});
   await bridge.pumpOnce();assert.equal(calls,1,'busy events cannot start a parallel turn');releaseModel();
  }
  await agent.whenIdle();await runtime.ctx.sessions.flush(agent.session);
  assert.ok(!trace.some(e=>e.kind==='agent.error'),JSON.stringify(trace.filter(e=>e.kind==='agent.error')));
  if(mode==='mcp'||mode==='product-profile'){assert.equal(local.state.confirmed['receipt-1'],true);assert.equal(local.state.acks,1);assert.equal(calls,3);await local.publish(local.messageEvent(1));await bridge.pumpOnce();await agent.whenIdle();assert.equal(calls,3,'late notification of already presented input must not trigger duplicate processing');await local.publish(local.messageEvent(1));await bridge.pumpOnce();await agent.whenIdle();assert.equal(calls,3,'duplicate source event must not restart a turn');}
  if(mode==='partial-projection'){
   assert.equal(local.state.confirmed['receipt-1'],true);assert.ok(!local.state.confirmed['receipt-2']);assert.equal(local.state.acks,0);
   await agent.bbDeliver({account:'10000001',session_id:mode,event_id:'complete-B'},[{type:'text',text:'Read the remaining message and explicitly ACK through 2'}]);await agent.whenIdle();
   assert.equal(local.state.confirmed['receipt-2'],true);assert.equal(local.state.acks,2);assert.equal(calls,6);
   await local.publish(local.messageEvent(3));await bridge.pumpOnce();await agent.whenIdle();assert.equal(local.state.acks,2);assert.equal(calls,7);
  }
  if(mode==='account-mismatch'){assert.ok(!local.state.confirmed['receipt-1']);assert.equal(local.state.acks,0);assert.ok(!JSON.stringify(trace.filter(e=>e.kind==='actual.request')).includes('10000003'),'foreign account result must not reach model input');}
  if(mode==='image-refusal'){assert.ok(!local.state.confirmed['receipt-1']);assert.equal(local.state.acks,0);assert.equal(calls,3);}
  if(mode==='busy-wait'){assert.equal(agent.session.snapshotEvents().filter(e=>e.type==='turn/start').length,1,'matching wait stays in current native turn');assert.equal(local.state.confirmed['receipt-1'],true);}
  if(mode==='busy-download'){
   assert.equal(calls,3);assert.equal(maxActive,1);assert.equal(agent.bbEventCursor(),2);
   await local.publish({...local.messageEvent(1),consumer_session:'wrong-session'});
   await assert.rejects(bridge.pumpOnce(),/session mismatch/);assert.equal(agent.bbEventCursor(),2);
  }
  await assert.rejects(agent.bbConfigure('10000003','10000002'),/account binding mismatch/);
  await assert.rejects(agent.bbConfirmPresentation({consumer_session:'other-session',attempt_id:'bad',request_digest:'bad',receipt_ids:['receipt-1']}),error=>error.status===404);
  const cancelled=new AbortController();cancelled.abort();assert.equal(await bridge.run(cancelled.signal),'cancelled');
  const durable=await runtime.ctx.sessionPersistence.open(mode,'read');await durable.read();await durable.close();
  await writeFile(resolve(root,mode+'.json'),JSON.stringify({calls,maxActive,client:local.state,trace,events:agent.session.snapshotEvents()},null,2));
  console.log(JSON.stringify({mode,calls,maxActive,confirmed:Object.keys(local.state.confirmed),acks:local.state.acks,result:'PASS'}));
 }finally{
  releaseModel();local.releaseWait();if(handle)await handle.dispose();for(const dispose of disposers)dispose();unregister?.();await client.close();await transport.close();await fiber.dispose();await runtime.close();await local.close();
 }
}
console.log(JSON.stringify({evidence:root,result:'PASS',mcp:'real Python stdio and native MCP projection',model_and_client:'DETERMINISTIC DOUBLES'}));
