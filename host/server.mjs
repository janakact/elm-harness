import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { storage } from './storage.mjs';
import { stream } from './openrouter.mjs';
import { execute } from './tools.mjs';
const require=createRequire(import.meta.url);
try{process.loadEnvFile('.env');}catch(e){if(e.code!=='ENOENT')throw e;}
const root=await fs.realpath(process.env.HARNESS_ROOT||process.cwd());
const store=storage(path.resolve(process.env.HARNESS_WORKSPACE||'workspace.json'));
const optional=async file=>{try{return await fs.readFile(file,'utf8');}catch(e){if(e.code==='ENOENT')return '';throw e;}};
const document=await store.read();
const flags={document,root,maxConcurrency:Number(process.env.HARNESS_CONCURRENCY||4),system:await optional(path.join(root,'SYSTEM.md')),append:await optional(path.join(root,'APPEND_SYSTEM.md')),project:await optional(path.join(root,'AGENTS.md'))};
const app=require('../dist/server.cjs').Elm.Server.Main.init({flags});
let lastPersist=-1;let snapshot=null;const controllers=new Map(),clients=new Set();let closing=false;
let mutations=Promise.resolve();
const send=event=>{if(!closing)app.ports.incoming.send({...event,at:new Date().toISOString()});};
app.ports.outgoing.subscribe(async command=>{
  try{
    if(command.type==='Snapshot'){snapshot=command.data;for(const client of clients)client.write(`data: ${JSON.stringify(snapshot)}\n\n`);}
    if(command.type==='Persist'&&command.serial>lastPersist){lastPersist=command.serial;await store.write(command.document);}
    if(command.type==='Abort'){controllers.get(command.requestId)?.abort();for(const controller of controllers.values())if(controller.threadId===command.requestId||controller.id===command.requestId)controller.abort();}
    if(command.type==='Request'){
      const controller=new AbortController();controller.id=command.requestId;controller.threadId=command.threadId;controllers.set(command.requestId,controller);
      try{await stream(command.body,process.env.OPENROUTER_API_KEY,AbortSignal.any([controller.signal,AbortSignal.timeout(180000)]),data=>send({type:'Chunk',requestId:command.requestId,data}));send({type:'Finished',requestId:command.requestId});}catch(e){send({type:'Failed',requestId:command.requestId,error:e.message});}finally{controllers.delete(command.requestId);}
    }
    if(command.type==='Execute'){
      const controller=new AbortController();controllers.set(command.callId,controller);
      try{send({type:'ToolFinished',callId:command.callId,text:await (command.name==='read'?execute(root,command,controller.signal):(mutations=mutations.catch(()=>{}).then(()=>execute(root,command,controller.signal)))),ok:true});}catch(e){send({type:'ToolFinished',callId:command.callId,text:e.message,ok:false});}finally{controllers.delete(command.callId);}
    }
  }catch(e){send({type:'StorageFailed',error:e.message});}
});
const mime={'.html':'text/html','.css':'text/css','.js':'text/javascript','.mjs':'text/javascript','.woff2':'font/woff2'};
const server=http.createServer(async(req,res)=>{
  try{
    const url=new URL(req.url,'http://localhost');
    if(req.method==='GET'&&url.pathname==='/api/state'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify(snapshot));return;}
    if(req.method==='GET'&&url.pathname==='/api/events'){res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache'});clients.add(res);if(snapshot)res.write(`data: ${JSON.stringify(snapshot)}\n\n`);req.on('close',()=>clients.delete(res));return;}
    if(req.method==='POST'&&url.pathname==='/api/action'){
      if(req.headers.origin&&req.headers.origin!==`http://${req.headers.host}`){res.writeHead(403).end();return;}
      let body='';for await(const chunk of req){body+=chunk;if(body.length>2_000_000)throw Error('Action too large');}
      const action=JSON.parse(body);if(action.protocolVersion!==1)throw Error('Unsupported protocol');
      send(action);res.writeHead(202).end('{}');return;
    }
    let file;
    if(url.pathname==='/')file='public/index.html';
    else if(url.pathname==='/browser.js')file='dist/browser.js';
    else if(url.pathname.startsWith('/vendor/'))file=path.join('node_modules',decodeURIComponent(url.pathname.slice(8)));
    else file=path.join('public',decodeURIComponent(url.pathname));
    const resolved=path.resolve(file);if(![path.resolve('public')+path.sep,path.resolve('dist')+path.sep,path.resolve('node_modules')+path.sep].some(prefix=>resolved.startsWith(prefix)))throw Error('Invalid path');
    res.setHeader('Content-Type',mime[path.extname(file)]||'application/octet-stream');res.end(await fs.readFile(file));
  }catch(e){res.writeHead(400,{'Content-Type':'text/plain'}).end(e.code==='ENOENT'?'Not found':e.message);}
});
server.listen(Number(process.env.PORT||8787),'127.0.0.1',()=>console.log(`Elm harness: http://127.0.0.1:${process.env.PORT||8787}`));
process.on('SIGINT',()=>{closing=true;for(const controller of controllers.values())controller.abort();server.close();process.exit(0);});
