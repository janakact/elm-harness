import {chromium} from 'playwright-core';
import assert from 'node:assert/strict';
const base=process.env.HARNESS_URL||'http://127.0.0.1:8788';
const state=await (await fetch(base+'/api/state')).json();
state.document.core.data.nodes=[{id:'n1',parentId:null,refs:[],threadId:'t1',actor:'System',kind:'Notice',text:'Session started',at:''}];
for(let i=2;i<35;i++)state.document.core.data.nodes.push({id:'n'+i,parentId:'n'+(i-1),refs:[],threadId:'t1',actor:i%2?'Agent':'User',kind:i%2?'AgentMessage':'UserMessage',text:i===33?'# Rich content\n\n**Strong** and a [link](https://example.com).\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```js\nconst answer = 42;\n```\n\nInline \\(Q(s,a)\\) and display \\[V(s)=\\max_a Q(s,a)\\]\n\n<script>window.evil=true</script>':'A message in the conversation.\n\n'+('Long text to exercise the conversation viewport. '.repeat(10)),at:''});
state.document.core.data.threads[0].head='n34';state.document.core.data.seq=34;state.runs=[];
const browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
try{
 const page=await browser.newPage({viewport:{width:1440,height:940}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/api/events',route=>route.fulfill({status:200,contentType:'text/event-stream',body:'data: '+JSON.stringify(state)+'\n\n'}));
 await page.goto(base);await page.waitForSelector('textarea:not([disabled])');await page.waitForSelector('.katex');await page.waitForSelector('code.hljs');
 assert.equal(await page.evaluate(()=>document.documentElement.scrollHeight>innerHeight),false);
 assert.ok(await page.locator('#chat').evaluate(el=>el.scrollHeight>el.clientHeight));assert.equal(await page.evaluate(()=>window.evil),undefined);assert.ok(await page.locator('table').count());assert.ok(await page.locator('.copy-code').count());
 await page.getByRole('button',{name:'Graph & details'}).click();await page.screenshot({path:'/tmp/elm-v03-ui.png'});
 await page.setViewportSize({width:390,height:844});assert.equal(await page.evaluate(()=>document.documentElement.scrollHeight>innerHeight),false);
 assert.deepEqual(errors,[]);console.log('Browser passed: fixed viewport, chat scrolling, Markdown/table/code/copy, KaTeX, safe HTML, mobile layout');
}finally{await browser.close();}
