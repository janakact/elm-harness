import test from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const Elm=createRequire(import.meta.url)('../dist/server.cjs').Elm;
const tick=()=>new Promise(resolve=>setTimeout(resolve,12));
async function worker(document=null,autoSave=false){
 const app=Elm.Server.Main.init({flags:{document,root:'/workspace',system:'',append:'',project:''}}),events=[];
 app.ports.outgoing.subscribe(event=>{events.push(event);if(autoSave&&event.type==='Persist')queueMicrotask(()=>app.ports.incoming.send({type:'Saved',serial:event.serial}));});await tick();
 return {events,send:async event=>{app.ports.incoming.send({at:'fixture-time',...event});await tick();},state:()=>events.filter(e=>e.type==='Snapshot').at(-1).data,persist:()=>events.filter(e=>e.type==='Persist').at(-1),requests:()=>events.filter(e=>e.type==='Request')};
}
const tool=(requestId,id='read-1')=>({type:'Chunk',requestId,data:{choices:[{delta:{tool_calls:[{index:0,id,function:{name:'read',arguments:'{"path":"a.txt"}'}}]}}]}});
test('native model and tool effects wait for durable-save acknowledgement; duplicate acknowledgements never replay',async()=>{
 const w=await worker();await w.send({type:'Submit',threadId:'t1',text:'Read a file'});assert.equal(w.requests().length,0);const intent=w.persist();assert.ok(intent.document.core.data.interrupted.includes('t1'));
 await w.send({type:'Saved',serial:intent.serial+100});assert.equal(w.requests().length,0);await w.send({type:'Saved',serial:intent.serial});assert.equal(w.requests().length,1);
 const req=w.requests()[0];await w.send(tool(req.requestId));await w.send({type:'Finished',requestId:req.requestId});assert.equal(w.events.filter(e=>e.type==='Execute').length,0);const toolIntent=w.persist();assert.ok(toolIntent.document.core.data.nodes.some(n=>n.kind==='ToolCall'));
 await w.send({type:'Saved',serial:toolIntent.serial});await w.send({type:'Saved',serial:toolIntent.serial});assert.equal(w.events.filter(e=>e.type==='Execute').length,1);
});
test('cancellation before save, failed persistence, and restart cannot silently launch a deferred effect',async()=>{
 const w=await worker();await w.send({type:'Submit',threadId:'t1',text:'Never start'});const intent=w.persist();const run=w.state().runs.at(-1);await w.send({type:'Cancel',runId:run.id});await w.send({type:'Saved',serial:intent.serial});assert.equal(w.requests().length,0);
 const restored=await worker(intent.document,true);assert.equal(restored.requests().length,0);assert.ok(restored.state().document.core.data.nodes.some(n=>n.text.includes('interrupted')));
 const broken=await worker();await broken.send({type:'Submit',threadId:'t1',text:'Failed save'});const serial=broken.persist().serial;await broken.send({type:'StorageFailed',error:'Disk unavailable'});await broken.send({type:'Saved',serial});assert.equal(broken.requests().length,0);assert.match(broken.state().error,/Disk unavailable/);
});
test('a saved tool effect cannot attach to a later run which reuses its provider call ID',async()=>{
 const w=await worker();await w.send({type:'Submit',threadId:'t1',text:'First'});await w.send({type:'Saved',serial:w.persist().serial});const first=w.requests().at(-1);await w.send(tool(first.requestId,'reused'));await w.send({type:'Finished',requestId:first.requestId});const pending=w.persist();await w.send({type:'StopThread',threadId:'t1'});
 await w.send({type:'Submit',threadId:'t1',text:'Second'});await w.send({type:'Saved',serial:w.persist().serial});const second=w.requests().at(-1);await w.send(tool(second.requestId,'reused'));await w.send({type:'Finished',requestId:second.requestId});await w.send({type:'Saved',serial:pending.serial});assert.equal(w.events.filter(e=>e.type==='Execute').length,0);await w.send({type:'Saved',serial:w.persist().serial});assert.equal(w.events.filter(e=>e.type==='Execute').length,1);
});
test('the session plugin owns migrated state and requests a new chat using the explicitly selected public thread',async()=>{
 const w=await worker(null,true);await w.send({type:'OpenWorkspace',path:'/second',newChat:true,title:'Second',model:'second-model'});const load=w.events.find(e=>e.type==='ReadWorkspace');await w.send({type:'WorkspaceLoaded',requestId:load.requestId,root:'/second',system:'',append:'',project:''});
 await w.send({type:'UserAction',threadId:'t1',action:'StartChat'});const created=w.state().document.core.data.threads.find(t=>t.id===w.state().document.core.data.focused);assert.equal(created.workspace,'/workspace');assert.notEqual(created.model,'second-model');assert.equal(w.requests().length,0);
 const doc=structuredClone(w.state().document);doc.user={schemaVersion:1,data:{replies:7,customPreference:{keep:true}}};const restored=await worker(doc,true);assert.equal(restored.state().extension.replies,7);await restored.send({type:'UserAction',action:'ToggleCount',threadId:'t1'});assert.equal(restored.state().document.user.data.showCount,false);assert.deepEqual(restored.state().document.user.data.customPreference,{keep:true});await restored.send({type:'UserAction',action:'ResetCount',threadId:'t1'});assert.equal(restored.state().extension.replies,0);
});
test('unknown or malformed plugin data is quarantined and preserved while core actions continue',async()=>{
 const baseline=await worker(null,true);for(const user of [{schemaVersion:99,data:{future:['keep','everything']}},{schemaVersion:2,data:{replies:'invalid',showCount:true}}]){
  const doc=structuredClone(baseline.state().document);doc.user=user;const w=await worker(doc,true);assert.equal(w.state().error,'');assert.ok(w.state().pluginError);assert.deepEqual(w.state().document.user,user);
  const count=w.state().document.core.data.threads.length;await w.send({type:'UserAction',action:'StartChat',threadId:'t1'});assert.equal(w.state().document.core.data.threads.length,count);assert.ok(w.events.some(e=>e.type==='ActionResult'&&!e.ok));await w.send({type:'NewChat',title:'Core still works',model:'test-model'});assert.equal(w.state().document.core.data.threads.length,count+1);assert.deepEqual(w.persist().document.user,user);
 }
});
test('permission ask preset actually asks for all tools',async()=>{
 const Tui=createRequire(import.meta.url)('../dist/terminal.cjs').Elm.Terminal.Main;
 const w=await worker(null,true),app=Tui.init({flags:null}),events=[];app.ports.outgoing.subscribe(e=>events.push(e));await tick();app.ports.incoming.send({type:'Snapshot',data:w.state()});await tick();app.ports.incoming.send({type:'Line',line:'/permissions ask'});await tick();const action=events.filter(e=>e.type==='Action').at(-1).data;assert.deepEqual(action.policy,{read:'ask',write:'ask',bash:'ask'});
});
test('public action results correlate rejection and acceptance separately from execution',async()=>{
 const w=await worker();await w.send({type:'Submit',threadId:'missing',text:'invalid',clientId:'client-a',actionId:'action-1'});let result=w.events.filter(e=>e.type==='ActionResult').at(-1);assert.equal(result.actionId,'action-1');assert.equal(result.clientId,'client-a');assert.equal(result.ok,false);assert.match(result.error,/Chat not found/);assert.equal(w.requests().length,0);
 await w.send({type:'Submit',threadId:'t1',text:'valid',clientId:'client-a',actionId:'action-2'});result=w.events.filter(e=>e.type==='ActionResult').at(-1);assert.equal(result.actionId,'action-2');assert.equal(result.ok,true);assert.equal(w.requests().length,0,'accepted is not executed before save acknowledgement');await w.send({type:'Saved',serial:w.persist().serial});assert.equal(w.requests().length,1);
});
test('public projection excludes private persistence-only fields without changing plugin data',async()=>{
 const w=await worker();const doc=structuredClone(w.state().document);doc.core.data.privateStorageMetadata={revisionHint:'not a UI contract'};doc.core.data.nodes[0].privateCache='not public';const restored=await worker(doc);assert.equal(restored.state().public.apiVersion,1);assert.ok(!JSON.stringify(restored.state().public).includes('not public'));assert.ok(!JSON.stringify(restored.state().public).includes('privateStorageMetadata'));assert.equal(restored.state().public.state.nodes.n1.text,'Session started');
});
test('chat dates persist, forks get their own creation time, and older deliveries do not move activity backwards',async()=>{
 const w=await worker(null,true);const createdAt='2026-11-10T08:00:00.000Z',activeAt='2026-11-12T16:30:00.000Z';await w.send({type:'NewChat',title:'Dated',model:'test-model',at:createdAt});const initial=w.state().document.core.data.threads.find(t=>t.title==='Dated');assert.equal(initial.createdAt,createdAt);assert.equal(initial.updatedAt,createdAt);
 await w.send({type:'Send',from:'t1',target:initial.id,text:'New activity',refs:[],at:activeAt});await w.send({type:'Send',from:'t1',target:initial.id,text:'Older recorded delivery',refs:[],at:createdAt});let thread=w.state().document.core.data.threads.find(t=>t.id===initial.id);assert.equal(thread.updatedAt,activeAt);assert.equal(w.state().public.state.threads[initial.id].updatedAt,activeAt);
 await w.send({type:'Fork',nodeId:thread.head,title:'Recent fork',task:'',at:'2026-11-13T08:00:00.000Z'});const fork=w.state().document.core.data.threads.find(t=>t.title==='Recent fork');assert.equal(fork.createdAt,'2026-11-13T08:00:00.000Z');assert.equal(fork.updatedAt,fork.createdAt);
 const saved=w.state().document;const restored=await worker(saved,true);assert.equal(restored.state().document.core.data.threads.find(t=>t.id===initial.id).updatedAt,activeAt);
 // Old documents derive the best recorded date from their own nodes.
 const legacy=structuredClone(saved);for(const chat of legacy.core.data.threads){delete chat.createdAt;delete chat.updatedAt;}const migrated=await worker(legacy,true);thread=migrated.state().document.core.data.threads.find(t=>t.id===initial.id);assert.equal(thread.createdAt,createdAt);assert.equal(thread.updatedAt,activeAt);
});
