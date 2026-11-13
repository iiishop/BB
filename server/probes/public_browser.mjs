// Run from repository root after npm ci/build in admin-ui and uv sync --project server.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { once } from 'node:events';
import net from 'node:net';
import path from 'node:path';
const require=createRequire(new URL('../../admin-ui/package.json',import.meta.url));
const { chromium,expect }=require('@playwright/test');
const root=path.resolve(new URL('../..',import.meta.url).pathname);
const evidence=path.join(root,'server/.evidence');
await mkdir(evidence,{recursive:true});
const directory=await mkdtemp(path.join(evidence,'browser-b-'));
const python=path.join(root,'server/.venv/bin/python');
const cli=path.join(root,'server/.venv/bin/bb-admin');
const daemon=process.env.MULTICA_CLI_PATH ? JSON.parse(spawnSync(process.env.MULTICA_CLI_PATH,['daemon','status','--output','json'],{encoding:'utf8'}).stdout).pid : null;
async function port(){ const s=net.createServer();s.listen(0,'127.0.0.1');await once(s,'listening');const p=s.address().port;await new Promise(r=>s.close(r));return p; }
const browser=await chromium.launch({headless:true});
const results=[];
async function scenario(fixture){
  const name=fixture?'external-fixtures':'native-cli';
  const state=path.join(directory,name);await mkdir(state);
  const adminPort=await port(); const businessPort=await port();
  const origin=`http://127.0.0.1:${adminPort}`;
  const log=createWriteStream(path.join(state,'server.log'));
  const child=fixture ? spawn(python,[path.join(root,'server/probes/public_browser_fixture.py'),'--directory',state,'--port',String(adminPort)],{cwd:root,stdio:['ignore','pipe','pipe']}) : spawn(cli,[],{cwd:root,env:{...process.env,BB_ADMIN_PORT:String(adminPort),BB_PORT:String(businessPort),BB_ADMIN_DATABASE_PATH:path.join(state,'admin.db'),BB_DATABASE_PATH:path.join(state,'business.db')},stdio:['ignore','pipe','pipe']});
  child.stdout.pipe(log,{end:false});child.stderr.pipe(log,{end:false});
  const context=await browser.newContext({viewport:{width:1440,height:900}});
  const page=await context.newPage();const errors=[];const csp=[];let eventStreams=0;
  page.on('pageerror',e=>errors.push(e.message));
  page.on('console',m=>{if(m.type()==='error'&&/Content Security Policy|violates/.test(m.text()))csp.push(m.text());});
  page.on('response',r=>{if(r.url().includes('/events?'))eventStreams++;});
  try {
    await expect.poll(async()=>{ if(child.exitCode!==null)throw new Error('server exited');try{return (await fetch(origin+'/admin/')).status;}catch{return 0;}},{timeout:20000}).toBe(200);
    await page.goto(origin+'/admin/');
    await page.getByLabel('用户名').fill('admin');
    await page.getByLabel('密码',{exact:true}).fill('admin');
    await page.getByRole('button',{name:'登录',exact:true}).click();
    await page.getByLabel('当前密码').fill('admin');
    await page.getByLabel(/^新密码/).fill('Forge-Admin-12345');
    await page.getByLabel('再次输入新密码').fill('Forge-Admin-12345');
    await page.getByRole('button',{name:'修改密码并退出所有会话'}).click();
    await page.getByLabel('密码',{exact:true}).fill('Forge-Admin-12345');
    await page.getByRole('button',{name:'登录',exact:true}).click();
    await expect(page.getByRole('heading',{name:'欢迎，admin'})).toBeVisible();
    await page.getByRole('link',{name:'配置',exact:true}).click();
    await page.locator('input[placeholder="bb.example.com"]').fill('bb.forge-example.test');
    await page.getByRole('button',{name:'保存域名草稿'}).click();
    await expect(page.getByText('草稿已保存')).toBeVisible();
    await page.getByRole('button',{name:'开始只读探测'}).click();
    const current=()=>page.evaluate(async()=> (await (await fetch('/admin/api/tasks/current')).json()).task);
    await expect.poll(async()=> (await current())?.stage,{timeout:15000}).toMatch(/awaiting_authorization|finished/);
    const task=await current();assert.equal(task.kind,'probe');assert.equal(task.checks.length,6);
    // Explicit native EventSource replay uses the actual cookie/CSRF boundary and durable journal.
    const replay=await page.evaluate(taskId=>new Promise((resolve,reject)=>{const es=new EventSource(`/admin/api/tasks/${taskId}/events?after_seq=0`);const timeout=setTimeout(()=>{es.close();reject(new Error('SSE timeout'));},5000);es.addEventListener('task',e=>{clearTimeout(timeout);es.close();resolve({id:e.lastEventId,data:JSON.parse(e.data)});});}),task.task_id);
    assert.equal(replay.id,'1');assert.equal(replay.data.task_id,task.task_id);
    await page.reload();await expect(page.getByRole('heading',{name:'配置',exact:true})).toBeVisible();
    assert.equal((await current()).task_id,task.task_id);
    if(fixture){
      assert.equal(task.stage,'awaiting_authorization');
      await page.getByRole('button',{name:'补充管理凭据'}).click();
      let dialog=page.getByRole('dialog',{name:'补充管理凭据'});
      await dialog.getByLabel(/^管理 API Token/).fill('synthetic-browser-token');
      await dialog.getByRole('button',{name:'提交凭据并恢复任务'}).click();
      await page.getByRole('button',{name:'创建并连接 Tunnel'}).click();
      dialog=page.getByRole('dialog',{name:'确认公网执行计划'});
      await expect(dialog).toBeVisible();await page.screenshot({path:path.join(state,'confirmation.png'),fullPage:false,animations:'disabled'});
      await dialog.getByRole('button',{name:'取消',exact:true}).click();
      assert.equal((await current()).task_id,task.task_id);
      await page.getByRole('button',{name:'创建并连接 Tunnel'}).click();
      dialog=page.getByRole('dialog',{name:'确认公网执行计划'});
      await dialog.getByRole('checkbox').check();
      await dialog.getByRole('button',{name:'确认并执行'}).click();
      await expect.poll(async()=> (await current())?.classification,{timeout:15000}).toBe('passed');
      const executed=await current();assert.equal(executed.kind,'execute');
      await page.reload();await expect(page.getByRole('heading',{name:'配置',exact:true})).toBeVisible();
      assert.equal((await current()).task_id,executed.task_id);
      assert.equal((await current()).resources.length,3);
    }
    await page.screenshot({path:path.join(state,'configuration.png'),fullPage:true,animations:'disabled'});
    assert.deepEqual(errors,[]);assert.deepEqual(csp,[]);assert.ok(eventStreams>=1);
    results.push({name,status:'PASS',backend:'product bb-admin app, persistence, worker, routes, SSE, static mount',external:fixture?'FAKE cloud, installer and public-instance verifier; NOT cloud/OS acceptance':'actual local read-only probe; no cloud credentials or system modifications',task_id:task.task_id,task_stage:task.stage,event_streams:eventStreams,page_errors:errors,csp_violations:csp});
  } finally {
    await context.close();
    assert.notEqual(child.pid,daemon);
    if(child.exitCode===null){
      const exited=once(child,'exit');let timer;
      child.kill('SIGTERM');
      try {
        await Promise.race([exited,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('child did not stop')),10000);})]);
      } catch(error) {
        // Only the exact child started above; never leave run-owned work behind.
        child.kill('SIGKILL');await exited;throw error;
      } finally {clearTimeout(timer);}
    }
    log.end();
  }
  if(fixture){const effects=JSON.parse(await readFile(path.join(state,'external-effects.json'),'utf8'));assert.deepEqual(effects,{cloud:{tunnel:1,ingress:1,dns:1},platform:['connect']});}
}
try {await scenario(false);await scenario(true);} finally {await browser.close();await writeFile(path.join(directory,'results.json'),JSON.stringify(results,null,2));}
console.log(JSON.stringify({artifact_directory:directory,scenarios:results.length,passed:results.filter(x=>x.status==='PASS').length}));
