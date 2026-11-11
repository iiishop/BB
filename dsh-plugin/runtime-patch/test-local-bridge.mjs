import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {localOperationClient} from './local-bridge.mjs';
for(const url of ['https://127.0.0.1','http://example.com','http://user:password@127.0.0.1','http://127.0.0.1/path'])assert.throws(()=>localOperationClient(url));
let mode='new',queries=0,submits=0;
const server=createServer(async(req,res)=>{
 let raw='';for await(const c of req)raw+=c;const args=JSON.parse(raw);
 if(req.url==='/operations/get'){
  queries++;
  if(mode==='new'){res.writeHead(404,{'content-type':'application/json'});res.end('{}');return;}
  if(mode==='unavailable'){res.writeHead(503,{'content-type':'application/json'});res.end('{}');return;}
  res.writeHead(200,{'content-type':'application/json'});
  res.end(JSON.stringify({operation_id:args.operation_id,kind:'download',status:mode,task_id:'task',token:'DO_NOT_FORWARD'}));return;
 }
 submits++;res.writeHead(202,{'content-type':'application/json'});res.end(JSON.stringify({operation_id:args.operation_id,task_id:'task',token:'DO_NOT_FORWARD'}));
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
try{
 const client=localOperationClient('http://127.0.0.1:'+server.address().port);
 const args={operation_id:'op',consumer_session:'session',media_id:'media'};
 for(mode of ['new','pending','succeeded','failed']){
  const result=await client('start_download',args);
  assert.equal(result.isError,mode==='failed');assert.ok(!JSON.stringify(result).includes('DO_NOT_FORWARD'));
  assert.equal(JSON.parse(result.content[0].text).task_id,'task');
 }
 mode='unavailable';await assert.rejects(client('start_download',args),/UNCERTAIN/);
 assert.equal(submits,1);assert.equal(queries,5);
 console.log(JSON.stringify({result:'PASS',client:'HTTP TEST DOUBLE',queries,submits}));
}finally{await new Promise(r=>server.close(r));}
