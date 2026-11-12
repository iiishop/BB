import assert from 'node:assert/strict';
import {fork,execFileSync} from 'node:child_process';
import {mkdtemp,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
const runtime=resolve(process.argv[2]);
const root=await mkdtemp(resolve('dsh-plugin/.evidence/r3-presentations-'));
const runs=[];
async function run(phase,sessionId,crash=false){
 const child=fork(resolve('dsh-plugin/runtime-patch/presentation-worker.mjs'),[runtime,root,phase,sessionId],{silent:true});
 let stderr='',stdout='',timedout=false;const trace=[];
 const kill=()=>{const daemon=JSON.parse(execFileSync(process.env.MULTICA_CLI_PATH,['daemon','status','--output','json'],{encoding:'utf8'}));assert.notEqual(child.pid,daemon.pid);child.kill('SIGKILL');};
 const timer=setTimeout(()=>{timedout=true;kill();},20000);
 child.stderr.on('data',d=>stderr+=d);child.stdout.on('data',d=>stdout+=d);
 child.on('message',m=>{trace.push(m);if(crash&&m.kind==='checkpoint')kill();});
 const result=await new Promise(resolve=>child.on('close',(code,signal)=>resolve({code,signal})));
 clearTimeout(timer);runs.push({phase,sessionId,...result,stderr,stdout,trace});
 await writeFile(resolve(root,'runs.json'),JSON.stringify(runs,null,2));
 assert.equal(timedout,false,stderr);assert.equal(result.code,crash?null:0,stderr);assert.equal(result.signal,crash?'SIGKILL':null);
 console.log(JSON.stringify({phase,sessionId,...result}));
}
await run('control','control');await run('replay','control');
await run('filtered','filtered');
for(const phase of ['presentation-before-confirm','presentation-after-confirm-before-receipt']){
 await run(phase,phase,true);await run('recover',phase);await run('replay',phase);
}
await run('accepted-before-receipt','cursor-crash',true);await run('recover-admission','cursor-crash');await run('replay','cursor-crash');
console.log(JSON.stringify({evidence:root,result:'PASS',client:'SYNTHETIC DURABLE CLIENT; real Cordis/DSH/JSONL and image store'}));
