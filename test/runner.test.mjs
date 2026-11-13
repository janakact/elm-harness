import test from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const {Elm}=createRequire(import.meta.url)('../dist/server.cjs');
const Terminal=createRequire(import.meta.url)('../dist/terminal.cjs').Elm.Terminal.Main;
const tick=()=>new Promise(resolve=>setTimeout(resolve,10));
const runners={codex:{available:true,version:'fixture-codex',error:''},claude:{available:true,version:'fixture-claude',error:''}};
async function worker({document=null,autoSave=true,maxConcurrency=4,capabilities=runners}={}){
 const app=Elm.Server.Main.init({flags:{document,runners:capabilities,root:'/workspace',system:'',append:'',project:'PROJECT_RULES',maxConcurrency}}),events=[];
 app.ports.outgoing.subscribe(event=>{events.push(event);if(autoSave&&event.type==='Persist')queueMicrotask(()=>app.ports.incoming.send({type:'Saved',serial:event.serial}));});await tick();
 return {events,send:async event=>{app.ports.incoming.send({at:'2026-11-12T10:00:00.000Z',...event});await tick();},state:()=>events.filter(e=>e.type==='Snapshot').at(-1).data,save:()=>events.filter(e=>e.type==='Persist').at(-1),launches:()=>events.filter(e=>e.type==='LaunchRunner')};
}
const start=(backend='codex',text='Inspect the workspace')=>({type:'StartJob',threadId:'t1',backend,text,model:''});
const frame=(data,sequence=1,attempt=1,jobId='j1')=>({type:'RunnerFrame',jobId,attempt,sequence,data});
const exit=(ok=true,error='',attempt=1,jobId='j1')=>({type:'RunnerExit',jobId,attempt,ok,error});
const job=w=>w.state().public.state.jobs[0];
async function finish(w,session='session-1',text='Read-only findings',attempt=1,jobId='j1'){
 await w.send(frame({type:'thread.started',thread_id:session},1,attempt,jobId));
 await w.send(frame({type:'item.completed',item:{id:'message-1',type:'agent_message',text}},2,attempt,jobId));
 await w.send(frame({type:'turn.completed',usage:{input_tokens:21,output_tokens:7}},3,attempt,jobId));
 await w.send(exit(true,'',attempt,jobId));
}
test('external launch is durable, read-only, captures input, and cancellation prevents deferred or late execution',async()=>{
 const w=await worker({autoSave:false});await w.send(start());assert.equal(w.launches().length,0);const saved=w.save();assert.equal(job(w).status,'Running');assert.equal(saved.document.core.data.runners.entries.j1.job.attempt,1);
 await w.send({type:'Saved',serial:saved.serial+50});assert.equal(w.launches().length,0);await w.send({type:'Saved',serial:saved.serial});const launch=w.launches()[0];assert.equal(launch.profile,'read-only-v1');assert.equal(launch.root,'/workspace');assert.equal(Object.hasOwn(job(w),'input'),false);assert.ok(launch.args.includes('read-only'));assert.ok(launch.args.includes('never'));assert.ok(!launch.args.includes('--last'));assert.ok(launch.input.includes('PROJECT_RULES'));assert.ok(launch.input.includes('Inspect the workspace'));assert.ok(!launch.args.includes('deepseek/deepseek-v4-flash'));
 await w.send({type:'Saved',serial:saved.serial});assert.equal(w.launches().length,1);await w.send({type:'CancelJob',jobId:'j1'});await finish(w);assert.equal(job(w).status,'Cancelled');assert.equal(job(w).output,'');assert.ok(w.events.some(e=>e.type==='StopRunner'&&e.attempt===1));
 const never=await worker({autoSave:false});await never.send(start());const intent=never.save();await never.send({type:'CancelJob',jobId:'j1'});await never.send({type:'Saved',serial:intent.serial});assert.equal(never.launches().length,0);
 const broken=await worker({autoSave:false});await broken.send(start());const serial=broken.save().serial;await broken.send({type:'StorageFailed',error:'Disk full'});await broken.send({type:'Saved',serial});assert.equal(broken.launches().length,0);
});
test('Codex snapshots replace item text; events deduplicate and external tools are never executed natively',async()=>{
 const w=await worker();await w.send(start());await w.send(frame({type:'thread.started',thread_id:'session-1'}));
 await w.send(frame({type:'item.updated',item:{id:'m1',type:'agent_message',text:'Partial'}},2));await w.send(frame({type:'item.completed',item:{id:'m1',type:'agent_message',text:'Complete'}},3));await w.send(frame({type:'item.updated',item:{id:'m1',type:'agent_message',text:'Duplicate'}},3));assert.equal(job(w).output,'Complete');
 await w.send(frame({type:'item.completed',item:{id:'tool-1',type:'command_execution',command:'cat README.md'}},4));await w.send(frame({type:'turn.completed',usage:{input_tokens:10,output_tokens:2}},5));await w.send(frame({type:'turn.completed',usage:{input_tokens:900,output_tokens:900}},6));assert.equal(job(w).status,'Running','terminal JSON waits for process exit');assert.equal(job(w).usage.input,10);await w.send(exit());assert.equal(job(w).status,'Completed');assert.equal(job(w).observations.length,1);assert.equal(w.events.filter(e=>e.type==='Execute').length,0);assert.deepEqual(w.state().document.core.data.usage,{});
 const count=w.state().document.core.data.nodes.length;await w.send(exit());assert.equal(w.state().document.core.data.nodes.length,count);
});
test('Claude deltas reconcile with terminal text and cumulative session cost is replaced on explicit resume',async()=>{
 const w=await worker();await w.send(start('claude'));const launch=w.launches()[0];assert.ok(launch.args.includes('--restricted'));assert.ok(launch.args.includes('Read,Glob,Grep'));assert.ok(!launch.args.includes('bypassPermissions'));
 await w.send(frame({type:'system',subtype:'init',session_id:'claude-1'}));await w.send(frame({type:'stream_event',event:{delta:{type:'text_delta',text:'Hello'}}},2));await w.send(frame({type:'stream_event',event:{delta:{type:'text_delta',text:'Hello'}}},2));assert.equal(job(w).output,'Hello');
 await w.send(frame({type:'result',session_id:'claude-1',is_error:false,result:'Hello world',usage:{input_tokens:10,output_tokens:3},total_cost_usd:0.02},3));await w.send(exit());assert.equal(job(w).output,'Hello world');assert.equal(job(w).usage.cost,0.02);
 await w.send({type:'ResumeJob',jobId:'j1',text:'Review again'});assert.equal(job(w).attempt,2);assert.ok(w.launches().at(-1).args.includes('--resume'));assert.ok(w.launches().at(-1).args.includes('claude-1'));assert.equal(job(w).usage,null);
 await w.send(frame({type:'result',session_id:'claude-1',is_error:false,result:'Second review',usage:{input_tokens:15,output_tokens:4},total_cost_usd:0.03},1,2));await w.send(exit(true,'',2));assert.equal(job(w).usage.cost,0.03,'cumulative cost is not added twice');assert.match(job(w).usage.scope,/session cost/);assert.ok(w.state().document.core.data.nodes.some(n=>n.kind==='RunnerResult'&&n.text.includes('Hello world')));
});
test('resume is bound to the original session/workspace/model and rejects old attempts or shared sessions',async()=>{
 const w=await worker();await w.send({...start(),model:'runner-model'});await finish(w);await w.send({type:'OpenWorkspace',path:'/other-workspace',newChat:true,title:'Another chat',model:'native-model'});const load=w.events.filter(e=>e.type==='ReadWorkspace').at(-1);await w.send({type:'WorkspaceLoaded',requestId:load.requestId,root:'/other-workspace',system:'',append:'',project:''});await w.send({type:'ResumeJob',jobId:'j1',text:'Follow-up'});const resumed=w.launches().at(-1);assert.equal(resumed.root,'/workspace');assert.ok(resumed.args.includes('session-1'));assert.ok(resumed.args.includes('runner-model'));assert.equal(job(w).threadId,'t1');await w.send(frame({type:'item.completed',item:{id:'late',type:'agent_message',text:'Wrong attempt'}},99));await w.send(exit());assert.equal(job(w).status,'Running');assert.equal(job(w).output,'');
 await w.send(frame({type:'thread.started',thread_id:'replacement-session'},1,2));await w.send(exit(true,'',2));assert.equal(job(w).status,'Failed');assert.match(job(w).error,/replace.*session/);assert.equal(job(w).sessionId,'session-1');
 await w.send(start());await w.send(frame({type:'thread.started',thread_id:'session-1'},1,1,'j2'));await w.send(exit(true,'',1,'j2'));assert.equal(w.state().public.state.jobs.find(j=>j.id==='j2').status,'Failed');assert.match(w.state().public.state.jobs.find(j=>j.id==='j2').error,/belongs to another job/);
});
test('runner results enter native context only through explicit report and captured handoffs survive restart',async()=>{
 const w=await worker();await w.send(start());await finish(w,'session-1','CAPTURED_EXTERNAL_RESULT');await w.send({type:'Submit',threadId:'t1',text:'Native turn'});let requests=w.events.filter(e=>e.type==='Request');assert.ok(!JSON.stringify(requests.at(-1).body.messages).includes('CAPTURED_EXTERNAL_RESULT'));
 const run=w.state().runs.at(-1);await w.send({type:'Cancel',runId:run.id});await w.send({type:'ReportJob',jobId:'j1',target:'t1'});assert.ok(w.state().document.core.data.nodes.some(n=>n.kind==='Handoff'&&n.text.includes('CAPTURED_EXTERNAL_RESULT')));await w.send({type:'Run',threadId:'t1'});requests=w.events.filter(e=>e.type==='Request');assert.ok(JSON.stringify(requests.at(-1).body.messages).includes('CAPTURED_EXTERNAL_RESULT'));
 const restored=await worker({document:w.save().document});assert.equal(job(restored).status,'Completed');assert.equal(job(restored).output,'CAPTURED_EXTERNAL_RESULT');assert.equal(restored.launches().length,0);
});
test('external/native jobs share concurrency slots and queued jobs never replay after restart',async()=>{
 const w=await worker({maxConcurrency:1});await w.send({type:'Submit',threadId:'t1',text:'Occupy native slot'});await w.send(start());assert.equal(job(w).status,'Queued');assert.equal(w.launches().length,0);const saved=w.save().document;const restored=await worker({document:saved});assert.equal(job(restored).status,'Interrupted');assert.equal(restored.launches().length,0);
 await w.send({type:'StopThread',threadId:'t1'});assert.equal(job(w).status,'Running');assert.equal(w.launches().length,1);await w.send(start('claude'));assert.equal(w.state().public.state.jobs.find(j=>j.id==='j2').status,'Queued');await w.send({type:'CancelJob',jobId:'j1'});assert.equal(w.state().public.state.jobs.find(j=>j.id==='j2').status,'Running');
});
test('failures, incomplete exits, unsupported runners and missing targets produce recoverable errors',async()=>{
 for(const [data,ok,error,expected] of [[null,true,'',/terminal result/],[{type:'turn.failed',error:{message:'Upstream failed'}},true,'',/Upstream failed/],[null,false,'Authentication required',/Authentication required/],[{type:'item.completed',item:{}},true,'',/malformed/]]){
  const w=await worker();await w.send(start());if(data)await w.send(frame(data));await w.send(exit(ok,error));assert.equal(job(w).status,'Failed');assert.match(job(w).error,expected);
 }
 const w=await worker({capabilities:{codex:{available:false,version:'',error:'Install Codex CLI'}}});for(const action of [start(),{...start(),backend:'invalid'},{...start(),threadId:'missing'},{type:'ResumeJob',jobId:'missing',text:'Resume'},{type:'CancelJob',jobId:'missing'}]){await w.send({...action,actionId:'check',clientId:'fixture'});assert.equal(w.events.filter(e=>e.type==='ActionResult').at(-1).ok,false);}assert.equal(w.launches().length,0);assert.equal(w.state().error,'');
});
test('TUI runner commands use the shared protocol and F7 shows live job output through the public projection',async()=>{
 const w=await worker();await w.send(start());await finish(w);const app=Terminal.init({flags:{clientId:'terminal'}}),events=[];app.ports.outgoing.subscribe(e=>events.push(e));await tick();app.ports.incoming.send({type:'Resize',columns:160,rows:55});app.ports.incoming.send({type:'Snapshot',data:w.state()});await tick();
 for(const [line,type] of [['/agent claude Inspect files','StartJob'],['/agent resume j1 Follow up','ResumeJob'],['/agent cancel j1','CancelJob'],['/agent report j1','ReportJob']]){app.ports.incoming.send({type:'Line',line});await tick();assert.equal(events.filter(e=>e.type==='Action').at(-1).data.type,type);}
 app.ports.incoming.send({type:'Key',key:'f7'});await tick();assert.match(JSON.stringify(events.at(-1)),/Read-only findings/);
});

test('invalid session IDs and oversized result text fail closed and stop their owning attempt',async()=>{
 for(const data of [{type:'thread.started',thread_id:'--unsafe-option'},{type:'item.completed',item:{id:'too-large',type:'agent_message',text:'x'.repeat(500001)}}]){
  const w=await worker();await w.send(start());await w.send(frame(data));assert.ok(w.events.some(e=>e.type==='StopRunner'&&e.jobId==='j1'&&e.attempt===1));await w.send(exit());assert.equal(job(w).status,'Failed');assert.ok(job(w).output.length<=500000);
 }
});

test('local model catalogs are normalized in Elm and public projections expose only visible choices',async()=>{
 const capabilities={...runners,codex:{...runners.codex,modelCache:{privateMetadata:'not public',models:[{slug:'visible-model',display_name:'Visible model',visibility:'list'},{slug:'hidden-model',display_name:'Hidden',visibility:'hide'},{slug:'visible-model',display_name:'Duplicate',visibility:'list'}]}}};
 const w=await worker({capabilities});assert.deepEqual(w.state().public.state.runnerCapabilities.codex.models,[{id:'visible-model',label:'Visible model'}]);assert.deepEqual(w.state().public.state.runnerCapabilities.claude.models.map(m=>m.id),['sonnet','opus','haiku']);assert.ok(!JSON.stringify(w.state().public).includes('not public'));
});

test('TUI immediately shows pending, then running output and complete external responses without F7',async()=>{
 const w=await worker(),app=Terminal.init({flags:{clientId:'terminal'}}),events=[];
 app.ports.outgoing.subscribe(e=>events.push(e));await tick();const emit=async event=>{app.ports.incoming.send(event);await tick();};const draw=()=>events.filter(e=>e.type==='Draw').at(-1).text;
 await emit({type:'Resize',columns:160,rows:55});await emit({type:'Snapshot',data:w.state()});await emit({type:'Line',line:'/agent codex --model chosen-model Inspect files'});const request=events.filter(e=>e.type==='Action').at(-1).data;assert.equal(request.model,'chosen-model');assert.match(draw(),/Sending codex agent request/);
 await w.send(request);await emit({type:'ActionResult',data:{clientId:'terminal',actionId:request.actionId,ok:true,error:''}});await emit({type:'Snapshot',data:w.state()});assert.match(draw(),/Starting codex/);assert.ok(!draw().includes('Sending codex agent request'));
 await w.send(frame({type:'thread.started',thread_id:'test-session'}));await w.send(frame({type:'item.updated',item:{id:'answer',type:'agent_message',text:'LIVE_DRAFT_FINDING'}},2));await emit({type:'Snapshot',data:w.state()});assert.match(draw(),/LIVE_DRAFT_FINDING/);
 await w.send(frame({type:'item.completed',item:{id:'answer',type:'agent_message',text:'COMPLETE_REVIEW_FINDING'}},3));await w.send(frame({type:'turn.completed',usage:{input_tokens:10,output_tokens:4}},4));await w.send(exit());await emit({type:'Snapshot',data:w.state()});assert.match(draw(),/COMPLETE_REVIEW_FINDING/);assert.ok(!draw().includes('LIVE_DRAFT_FINDING'));
});

test('cancelled/failed partial responses are preserved in history across follow-ups and restart',async()=>{
 const w=await worker();await w.send(start());await w.send(frame({type:'thread.started',thread_id:'partial-session'}));await w.send(frame({type:'item.updated',item:{id:'answer',type:'agent_message',text:'PARTIAL_REVIEW_FINDING'}},2));await w.send({type:'CancelJob',jobId:'j1'});assert.ok(w.state().document.core.data.nodes.some(n=>n.kind==='RunnerResult'&&n.text.includes('PARTIAL_REVIEW_FINDING')));
 await w.send({type:'ResumeJob',jobId:'j1',text:'Try again'});await w.send(frame({type:'item.updated',item:{id:'answer',type:'agent_message',text:'FAILED_PARTIAL_FINDING'}},1,2));await w.send(exit(false,'Provider failed',2));const restored=await worker({document:w.save().document});assert.ok(restored.state().document.core.data.nodes.some(n=>n.kind==='RunnerResult'&&n.text.includes('FAILED_PARTIAL_FINDING')));assert.ok(restored.state().document.core.data.nodes.some(n=>n.kind==='RunnerResult'&&n.text.includes('PARTIAL_REVIEW_FINDING')));
});
