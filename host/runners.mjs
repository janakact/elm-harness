// Process I/O only. Elm supplies argv/input and interprets every vendor event.
import {spawn} from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {createHash} from 'node:crypto';
import {StringDecoder} from 'node:string_decoder';
import {workspaceMasks} from './tools.mjs';

const required={codex:['--json','--ignore-user-config','--ignore-rules','--sandbox'],claude:['--restricted','--safe-mode','--tools','--strict-mcp-config','--permission-prompts','--include-partial-messages']};
const binaries=new Map();
const executable=backend=>process.env[`HARNESS_${backend.toUpperCase()}_BIN`]||binaries.get(backend)||backend;
async function installedBinary(backend){
  if(process.env[`HARNESS_${backend.toUpperCase()}_BIN`])return;
  // Resolve installed mise tools without running an auto-installing wrapper.
  const base=path.join(os.homedir(),'.local/share/mise/installs',backend);
  let versions;try{versions=await fs.readdir(base);}catch(error){if(error.code==='ENOENT')return;throw error;}
  versions=versions.filter(version=>/^\d+\.\d+\.\d+$/.test(version)).sort((a,b)=>a.localeCompare(b,undefined,{numeric:true})).reverse();
  for(const version of versions)for(const suffix of [path.join('bin',backend),backend]){
    const binary=path.join(base,version,suffix);try{if((await fs.stat(binary)).isFile()){binaries.set(backend,binary);return;}}catch(error){if(error.code!=='ENOENT')throw error;}
  }
}

function capture(binary,args,timeout=4000){
  return new Promise((resolve,reject)=>{
    const child=spawn(binary,args,{stdio:['ignore','pipe','pipe'],env:{...process.env,MISE_AUTO_INSTALL:'0'}});let output='',settled=false;
    const finish=(error)=>{if(settled)return;settled=true;clearTimeout(timer);error?reject(error):resolve(output);};
    const timer=setTimeout(()=>{child.kill('SIGKILL');finish(Error('CLI capability check timed out'));},timeout);
    const append=bytes=>{output+=bytes.toString();if(output.length>100000){child.kill('SIGKILL');finish(Error('CLI capability output exceeded limit'));}};
    child.stdout.on('data',append);child.stderr.on('data',append);child.on('error',finish);child.on('close',code=>finish(code===0?null:Error(output.trim().slice(0,1200)||`CLI exited ${code}`)));
  });
}

export async function probeRunners(){
  let modelCache=null;
  try{
    const file=path.join(process.env.CODEX_HOME||path.join(os.homedir(),'.codex'),'models_cache.json');
    if((await fs.stat(file)).size<=5000000)modelCache=JSON.parse(await fs.readFile(file,'utf8'));
  }catch{} // A missing/stale cache leaves CLI default and custom selection available.
  let sandboxError='';try{await capture('bwrap',['--ro-bind','/','/','--unshare-pid','--proc','/proc','--dev','/dev','--','/usr/bin/true']);}catch(error){sandboxError='Read-only process sandbox unavailable: '+error.message;}
  return Object.fromEntries(await Promise.all(Object.keys(required).map(async backend=>{
    try{
      if(sandboxError)throw Error(sandboxError);
      await installedBinary(backend);
      const help=await capture(executable(backend),backend==='codex'?['exec','--help']:['--help']);
      for(const flag of required[backend])if(!help.includes(flag))throw Error(`Installed ${backend} lacks ${flag}; update the CLI`);
      if(backend==='codex')await capture(executable(backend),['exec','resume','--help']);
      const version=(await capture(executable(backend),['--version'])).trim().split('\n').at(-1);
      return [backend,{available:true,version,error:'',modelCache:backend==='codex'?modelCache:null}];
    }catch(error){return [backend,{available:false,version:'',error:`${backend}: ${error.message}`,modelCache:backend==='codex'?modelCache:null}];}
  })));
}

export function runnerHome(stateFile){
  const identity=createHash('sha256').update(path.resolve(stateFile)).digest('hex').slice(0,16);
  return path.resolve(process.env.HARNESS_RUNNER_HOME||path.join(process.env.XDG_STATE_HOME||path.join(os.homedir(),'.local/state'),'elm-harness','runners',identity));
}

async function credentials(home,backend,source){
  const config=path.join(home,backend);await fs.mkdir(config,{recursive:true,mode:0o700});
  // Copy only login material into private runner storage; never user/project config.
  const name=backend==='codex'?'auth.json':'.credentials.json';
  const original=source||(backend==='codex'?(process.env.CODEX_HOME||path.join(os.homedir(),'.codex')):(process.env.CLAUDE_CONFIG_DIR||path.join(os.homedir(),'.claude')));
  try{await fs.access(path.join(config,name));}catch(error){if(error.code!=='ENOENT')throw error;try{await fs.copyFile(path.join(original,name),path.join(config,name));await fs.chmod(path.join(config,name),0o600);}catch(copyError){if(copyError.code!=='ENOENT')throw copyError;}}
  return config;
}

export async function launchRunner(command,{home,signal,onFrame,timeoutMs=600000,maxBytes=2000000,credentialSource}){
  if(command.profile!=='read-only-v1'||!Object.hasOwn(required,command.backend))throw Error('Unsupported runner profile');
  if(signal?.aborted)throw Error('External job cancelled');
  const canonical=await fs.realpath(command.root);const privateHome=path.join(home,command.backend);
  // CLI session storage must never be a writable hole in a project mount.
  if(privateHome===canonical||privateHome.startsWith(canonical+path.sep))throw Error('HARNESS_RUNNER_HOME must be outside the workspace');
  const config=await credentials(home,command.backend,credentialSource);
  const env={PATH:process.env.PATH,HOME:privateHome,LANG:'C.UTF-8',TERM:'dumb',NO_COLOR:'1',MISE_AUTO_INSTALL:'0'};
  if(command.backend==='codex'){
    env.CODEX_HOME=config;
    if(process.env.OPENAI_API_KEY)env.OPENAI_API_KEY=process.env.OPENAI_API_KEY;
  }else{
    env.CLAUDE_CONFIG_DIR=config;
    for(const key of ['ANTHROPIC_API_KEY','CLAUDE_CODE_OAUTH_TOKEN'])if(process.env[key])env[key]=process.env[key];
  }
  const masks=await workspaceMasks(canonical,canonical);
  const mounts=['--die-with-parent','--new-session','--unshare-pid','--ro-bind','/','/','--proc','/proc','--dev','/dev','--tmpfs','/tmp','--tmpfs',os.homedir(),'--ro-bind',canonical,canonical,'--bind',privateHome,privateHome,'--chdir',canonical];
  // The executable (and its runtime) may live in the user's home directory.
  // Expose installed tools read-only, while keeping personal files hidden.
  for(const folder of ['.local/bin','.local/share/mise/installs','.local/share/mise/shims']){
    const target=path.join(os.homedir(),folder);try{await fs.access(target);mounts.push('--ro-bind',target,target);}catch(error){if(error.code!=='ENOENT')throw error;}
  }
  for(const mask of masks)mounts.push(...mask);
  const binary=executable(command.backend);
  // Explicit binaries outside the system/runtime mounts are exposed read-only.
  if(path.isAbsolute(binary)){await fs.access(binary);mounts.push('--ro-bind',binary,binary);}
  if(signal?.aborted)throw Error('External job cancelled');
  return new Promise((resolve,reject)=>{
    const child=spawn('bwrap',[...mounts,'--',binary,...command.args],{cwd:canonical,env,detached:true,stdio:['pipe','pipe','pipe']});
    const decoder=new StringDecoder('utf8');let pending='',bytes=0,sequence=0,stderr='',failure='',killTimer;
    const stop=reason=>{if(failure)return;failure=reason;try{process.kill(-child.pid,'SIGTERM');}catch{}killTimer=setTimeout(()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}},300);};
    const cancel=()=>stop('External job cancelled');
    const timer=setTimeout(()=>stop('External job timed out'),timeoutMs);signal?.addEventListener('abort',cancel,{once:true});
    const line=source=>{if(!source.trim()||failure)return;try{onFrame(++sequence,JSON.parse(source));}catch{stop('Runner emitted malformed JSONL');}};
    child.stdout.on('data',data=>{
      bytes+=data.length;if(bytes>maxBytes){stop('External output exceeded limit');return;}
      pending+=decoder.write(data);let end;while((end=pending.indexOf('\n'))>=0){line(pending.slice(0,end));pending=pending.slice(end+1);}
      if(pending.length>1000000)stop('Runner JSON frame exceeded limit');
    });
    child.stderr.on('data',data=>{bytes+=data.length;stderr=(stderr+data.toString()).slice(-4000);if(bytes>maxBytes)stop('External output exceeded limit');});
    // A fast process can close stdin before consuming its full prompt.
    child.stdin.on('error',error=>{if(error.code!=='EPIPE')stop(error.message);});
    child.on('error',error=>{failure=error.message;});
    child.on('close',(code,exitSignal)=>{
      pending+=decoder.end();if(pending.trim())line(pending);
      clearTimeout(timer);clearTimeout(killTimer);signal?.removeEventListener('abort',cancel);
      if(failure||code!==0)reject(Error(failure||`Runner exited ${code??exitSignal}: ${stderr.trim()}`));else resolve();
    });
    child.stdin.end(command.input);
    if(signal?.aborted)cancel();
  });
}
