// Explicit synthetic client for contract/fault tests, not a Dart implementation.
import {createServer} from 'node:http';
import {readFile,open} from 'node:fs/promises';
export async function clientDouble(file,session,{initialMessages=3,targetAccount='10000001'}={}){
 let state;try{state=JSON.parse(await readFile(file,'utf8'));}catch(e){if(e.code!=='ENOENT')throw e;state={available:initialMessages,prepared:{},confirmed:{},attempts:{},acks:0,events:[],requests:[]};}
 const save=async()=>{const out=await open(file,'w');await out.writeFile(JSON.stringify(state));await out.sync();await out.close();};
 const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
 const visible=(position)=>({message:{id:'message-'+position,position,sender_account:'10000002',target_account:targetAccount,created_at:'2026-11-11T00:00:00Z',kind:'body',content:[{type:'text',text:'body-'+position}],attachment:null},presentation:{content_digest:'opaque-content-'+position,receipt_id:'receipt-'+position},blocks:position===1?[{type:'text',text:'before'},{type:'image',data:png,mime_type:'image/png'},{type:'text',text:'after'}]:[{type:'text',text:'body-'+position}]});
 const messageEvent=position=>({version:1,event_id:'event-'+position,account:'10000001',consumer_session:session,type:'message.available',peer_account:'10000002',position});
 let waiter,enteredWait;const waitStarted=new Promise(resolve=>enteredWait=resolve);
 const server=createServer(async(req,res)=>{
  try{
   let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);
   state.requests.push({path:req.url,body});let status=200,value;
   if(body.consumer_session&&body.consumer_session!==session){status=404;value={error:{code:'not_found'}};}
   else if(req.url==='/events/subscribe')value=body;
   else if(req.url==='/events/read'||req.url==='/events/wait'){
    let items=state.events.filter(e=>e.cursor>body.after_cursor).slice(0,body.limit);
    if(req.url==='/events/wait'&&!items.length){await new Promise(resolve=>{waiter=resolve;setTimeout(resolve,30);});items=state.events.filter(e=>e.cursor>body.after_cursor).slice(0,body.limit);}
    value={items,next_cursor:items.at(-1)?.cursor??body.after_cursor,has_more:state.events.some(e=>e.cursor>(items.at(-1)?.cursor??body.after_cursor)),...req.url==='/events/wait'?{reason:items.length?'events':'timeout'}:{}};
   }else if(req.url==='/chat/read_messages'||req.url==='/chat/wait_messages'){
    if(req.url==='/chat/wait_messages'){enteredWait();await new Promise(resolve=>{waiter=resolve;});}
    const after=body.after_position??body.seen_position;
    const positions=[1,2,3].filter(p=>p>after&&p<=state.available).slice(0,body.limit??50);
    for(const p of positions)state.prepared['receipt-'+p]={position:p,consumer_session:session,digest:'opaque-content-'+p};
    value={items:positions.map(visible),next_position:positions.at(-1)??after,has_more:false,...req.url==='/chat/wait_messages'?{reason:'messages'}:{}};
   }else if(req.url==='/chat/confirm_presentation'){
    if(body.receipt_ids.some(id=>!state.prepared[id])){status=404;value={error:{code:'not_found'}};}
    else if(state.attempts[body.attempt_id]&&JSON.stringify(state.attempts[body.attempt_id])!==JSON.stringify(body)){status=409;value={error:{code:'conflict'}};}
    else{state.attempts[body.attempt_id]=body;for(const id of body.receipt_ids)state.confirmed[id]=true;value={confirmed_receipt_ids:body.receipt_ids};}
   }else if(req.url==='/chat/ack_messages'){
    if(Array.from({length:Math.max(0,body.through_position-state.acks)},(_,i)=>i+state.acks+1).some(p=>!state.confirmed['receipt-'+p])){status=409;value={error:{code:'consumption_gap',message:'Unconfirmed gap',fields:[]}};}
    else{state.acks=Math.max(state.acks,body.through_position);value={consumed_through:state.acks};}
   }else{status=404;value={error:{code:'not_found',message:'Not found',fields:[]}};}
   await save();res.writeHead(status,{'content-type':'application/json'});res.end(JSON.stringify(value));
  }catch(e){res.writeHead(500);res.end('{}');}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 return {state,visible,messageEvent,waitStarted,releaseWait(){waiter?.();waiter=undefined;},origin:'http://127.0.0.1:'+server.address().port,async publish(event,wake=true){state.available=Math.max(state.available,event.position??0);state.events.push({cursor:state.events.length+1,event});await save();if(wake){waiter?.();waiter=undefined;}},async close(){await new Promise(resolve=>server.close(resolve));}};
}
