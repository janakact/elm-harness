import { spawn } from 'node:child_process';
import { chromium } from 'playwright-core';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
const fixture=await fs.mkdtemp(path.join(os.tmpdir(),'elm-workspace-browser-'));
const first=path.join(fixture,'first'),second=path.join(fixture,'second project'),third=path.join(fixture,'third');
for(const root of [first,second,third])await fs.mkdir(root);
await fs.writeFile(path.join(second,'AGENTS.md'),'SECOND WORKSPACE PROJECT RULES');
const port=process.env.TEST_PORT||'8795',base=`http://127.0.0.1:${port}`;
const server=spawn(process.execPath,['host/server.mjs'],{env:{...process.env,PORT:port,HARNESS_ROOT:first,HARNESS_WORKSPACE:path.join(fixture,'state.json')},stdio:['ignore','pipe','pipe']});
let browser;
try{
 await new Promise((resolve,reject)=>{server.stdout.on('data',bytes=>{if(bytes.toString().includes('http://'))resolve();});server.on('error',reject);server.on('exit',code=>reject(Error('Test server exited '+code)));});
 browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 const page=await browser.newPage({viewport:{width:1440,height:900}}),errors=[];page.on('pageerror',error=>errors.push(error.message));
 await page.goto(base);await page.waitForSelector('textarea:not([disabled])');
 await page.getByRole('button',{name:'Settings',exact:true}).click();
 const directory=page.getByRole('textbox',{name:'Workspace directory'});
 await directory.fill(path.join(fixture,'missing'));await page.getByRole('button',{name:'Open workspace',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.error')?.textContent.includes('ENOENT'));assert.equal(await page.locator('.workspace-title').textContent(),'Main');
 await directory.fill(second);await page.getByRole('button',{name:'New chat in workspace',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.workspace-title')?.textContent==='Chat 2');
 assert.ok((await page.locator('.composer-toolbar').textContent()).includes(second));await page.getByText('Effective system prompt · framework v3').click();assert.ok((await page.locator('.settings').textContent()).includes('SECOND WORKSPACE PROJECT RULES'));
 async function command(text,title){await page.locator('textarea').fill(text);await page.getByRole('button',{name:'Send ↑',exact:true}).click();await page.waitForFunction(expected=>document.querySelector('.workspace-title')?.textContent===expected,title);}
 await command('/rename Workspace B','Workspace B');await command('/new Another B','Another B');
 let state=await(await fetch(base+'/api/state')).json();assert.equal(state.document.core.data.threads.filter(t=>t.workspace===second).length,2);assert.equal(state.document.core.data.threads.find(t=>t.id==='t1').workspace,first);
 await page.getByRole('button',{name:first,exact:true}).click();await page.waitForFunction(()=>document.querySelector('.workspace-title')?.textContent==='Main');assert.ok(!(await page.locator('.chat').textContent()).includes('SECOND WORKSPACE PROJECT RULES'));
 await command(`/workspace "${second}"`,'Another B');state=await(await fetch(base+'/api/state')).json();assert.equal(state.document.core.data.threads.length,3);
 await command(`/new --workspace "${third}" Fresh C`,'Fresh C');state=await(await fetch(base+'/api/state')).json();assert.equal(state.document.core.data.threads.find(t=>t.title==='Fresh C').workspace,third);
 await page.getByRole('button',{name:'Commands',exact:true}).click();assert.ok((await page.locator('.command-panel').textContent()).includes('/workspaces'));await page.locator('.command-item').filter({hasText:'/workspace [PATH]'}).click();await page.waitForFunction(()=>document.querySelector('textarea')?.value==='/workspace ');assert.equal(await page.locator('textarea').inputValue(),'/workspace ');
 const forged=await fetch(base+'/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({protocolVersion:1,type:'WorkspaceLoaded',root:'/etc',requestId:'fake'})});assert.equal(forged.status,400);
 assert.equal(await page.evaluate(()=>document.documentElement.scrollHeight>innerHeight),false);await page.setViewportSize({width:390,height:844});assert.equal(await page.evaluate(()=>document.documentElement.scrollHeight>innerHeight),false);
 assert.deepEqual(errors,[]);console.log('Workspace browser passed: directory validation, per-chat roots/prompts, rename/new/switch commands, command menu, client-event validation, fixed viewport.');
}finally{await browser?.close();server.kill('SIGINT');}
