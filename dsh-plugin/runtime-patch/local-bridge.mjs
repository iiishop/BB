// The only product network boundary is the same-machine CLIENT. No server token.
export function localOperationClient(origin) {
 const url=new URL(origin);
 if(url.protocol!=='http:'||url.hostname!=='127.0.0.1'||url.username||url.password||url.pathname!=='/'||url.search||url.hash)throw Error('Expected local client origin');
 async function post(path,body){
  const response=await fetch(new URL(path,url),{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body),redirect:'error',signal:AbortSignal.timeout(15000)});
  const value=await response.json();return {status:response.status,value};
 }
 return async(name,args)=>{
  const operation_id=args.operation_id;
  const query=await post('/operations/get',{operation_id});
  let body;
  if(query.status===200){
   if(query.value.operation_id!==operation_id)throw Error('Operation identity mismatch');
   if(!['pending','failed','succeeded'].includes(query.value.status))throw Error('Invalid operation state');
   // A known durable download task can still be pending after acceptance.
   if(query.value.status==='pending'&&!(query.value.kind==='download'&&typeof query.value.task_id==='string'))throw Error('BB_OPERATION_UNCERTAIN');
   body={operation_id,status:query.value.status};
   if(query.value.kind==='message'&&typeof query.value.message?.id==='string')body.message_id=query.value.message.id;
   else if(query.value.kind==='download'&&typeof query.value.task_id==='string')body.task_id=query.value.task_id;
   else if(query.value.status!=='failed')throw Error('Invalid operation result');
   if(body.status==='failed')body.error_code='client_operation_failed';
  }else if(query.status===404){
   const route={send_message:'/chat/send_message',send_attachment:'/chat/send_attachment',start_download:'/downloads/start'}[name];
   if(!route)throw Error('Unsupported operation');
   const submitted=await post(route,args);
   if(submitted.status>=500)throw Error('BB_OPERATION_UNCERTAIN');
   if(submitted.status!==200&&submitted.status!==202){
    return {isError:true,content:[{type:'text',text:JSON.stringify({operation_id,status:'failed',error_code:'client_rejected',http_status:submitted.status})}]};
   }
   body={operation_id,status:submitted.status===202?'pending':'succeeded'};
   if(name==='start_download'){
    if(submitted.value.operation_id!==operation_id||typeof submitted.value.task_id!=='string')throw Error('Invalid task acceptance');
    body.task_id=submitted.value.task_id;
   }else{
    if(typeof submitted.value.id!=='string')throw Error('Invalid message acceptance');
    body.message_id=submitted.value.id;
   }
  }else throw Error('BB_OPERATION_QUERY_UNCERTAIN');
  return {isError:body.status==='failed',content:[{type:'text',text:JSON.stringify(body)}]};
 };
}
// Pass setup to native agents.create/resume; resume recovery happens AFTER setup.
export function setupLocalBridge(origin){const client=localOperationClient(origin);return (_ctx,agent)=>{agent.bbOperationClient=client;};}

export function localTransport(origin) {
 const url=new URL(origin);
 if(url.protocol!=='http:'||url.hostname!=='127.0.0.1'||url.username||url.password||url.pathname!=='/'||url.search||url.hash)throw Error('Expected local client origin');
 return async(path,body,{signal}={})=>{
  const response=await fetch(new URL(path,url),{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body),redirect:'error',signal:signal?AbortSignal.any([signal,AbortSignal.timeout(Math.max(15000,(body.timeout??0)*1000+5000))]):AbortSignal.timeout(Math.max(15000,(body.timeout??0)*1000+5000))});
  const value=await response.json();
  if(response.status!==200){const error=new Error('BB_LOCAL_'+response.status);error.status=response.status;throw error;}
  return value;
 };
}
export function bindLocalControl(agent,origin){
 const post=localTransport(origin);
 agent.bbOperationClient=localOperationClient(origin);
 agent.bbConfirmPresentation=payload=>post('/chat/confirm_presentation',payload);
 agent.bbAcknowledge=async payload=>{
  try {const value=await post('/chat/ack_messages',payload);return {isError:false,content:[{type:'text',text:JSON.stringify({consumed_through:value.consumed_through})}]};}
  catch(error){if(error.status===409)return {isError:true,content:[{type:'text',text:JSON.stringify({error:{code:'consumption_gap'}})}]};throw error;}
 };
 return post;
}
