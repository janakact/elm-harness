import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {launchRunner,probeRunners} from '../host/runners.mjs';
const fixture=await fs.mkdtemp(path.join(os.tmpdir(),'elm-runner-process-'));
const root=path.join(fixture,'project'),home=path.join(fixture,'sessions'),auth=path.join(fixture,'empty-auth');
await fs.mkdir(root);await fs.mkdir(auth);await fs.writeFile(path.join(root,'.env'),'SECRET_FIXTURE');
const binary=path.join(fixture,'fake-runner');await fs.writeFile(binary,`#!${process.execPath}\n`+await fs.readFile('test/support/fake-runner.mjs','utf8'),{mode:0o700});
process.env.HARNESS_CODEX_BIN=binary;process.env.HARNESS_CLAUDE_BIN=binary;
const command=input=>({backend:'codex',profile:'read-only-v1',args:['exec','--json','-'],root,input});
const options={home,credentialSource:auth};
test('runner capability probes do not launch a model and fail closed for missing binaries',async()=>{
 let caps=await probeRunners();assert.equal(caps.codex.available,true);assert.equal(caps.claude.available,true);process.env.HARNESS_CODEX_BIN=path.join(fixture,'missing');caps=await probeRunners();assert.equal(caps.codex.available,false);assert.match(caps.codex.error,/ENOENT/);process.env.HARNESS_CODEX_BIN=binary;
});
test('real process transport handles partial UTF-8/JSONL and enforces a read-only, masked workspace',async()=>{
 const events=[];await launchRunner(command('Review'),{...options,onFrame:(sequence,data)=>events.push({sequence,data})});assert.deepEqual(events.map(e=>e.sequence),[1,2,3,4]);const answer=events.find(e=>e.data.item?.type==='agent_message').data.item.text;assert.match(answer,/review ✓/);assert.match(answer,/write denied: true/);assert.match(answer,/Secret masked: true/);await assert.rejects(fs.access(path.join(root,'forbidden-write.txt')));assert.equal(await fs.readFile(path.join(root,'.env'),'utf8'),'SECRET_FIXTURE');
});
test('process transport reports malformed JSON, budget limits, timeouts and nonzero exits',async()=>{
 for(const [input,extra,pattern]of [['MALFORMED_JSON',{},/malformed JSONL/],['EXCESS_OUTPUT',{maxBytes:1000},/output exceeded/],['WAIT_FOR_CANCEL',{timeoutMs:100},/timed out/],['EXIT_FAILURE',{},/Fixture transport failure/]])await assert.rejects(launchRunner(command(input),{...options,...extra,onFrame:()=>{}}),pattern);
});
test('cancellation interrupts the process and pre-cancelled jobs never start',async()=>{
 const controller=new AbortController();const running=launchRunner(command('WAIT_FOR_CANCEL'),{...options,signal:controller.signal,onFrame:()=>controller.abort()});await assert.rejects(running,/cancelled/);await assert.rejects(launchRunner(command('Review'),{...options,signal:controller.signal,onFrame:()=>{}}),/cancelled/);
});
test('unsupported profiles and writable runner state inside a workspace are rejected',async()=>{
 await assert.rejects(launchRunner({...command('Review'),profile:'workspace-write'},{...options,onFrame:()=>{}}),/Unsupported/);await assert.rejects(launchRunner(command('Review'),{...options,home:root,onFrame:()=>{}}),/outside the workspace/);
});
