import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
const cap = 64000;
export async function workspacePath(root, input, writing=false) {
  if (typeof input !== 'string' || !input || input.includes('\0')) throw Error('Invalid path');
  const target = path.resolve(root, input);
  if (target !== root && !target.startsWith(root + path.sep)) throw Error('Path escapes workspace');
  if (target.split(path.sep).some(p => p === '.git' || p === '.env' || p.startsWith('.env.') || ['.ssh','.aws','.codex','.npmrc','.pypirc'].includes(p))) throw Error('Sensitive path denied');
  let check = target;
  while (true) {
    try { const real = await fs.realpath(check); if(real.split(path.sep).some(p=>p==='.env'||p.startsWith('.env.')||['.ssh','.aws','.codex','.git','.npmrc','.pypirc'].includes(p)))throw Error('Sensitive resolved path denied'); if (real !== root && !real.startsWith(root + path.sep)) throw Error('Symlink escapes workspace'); break; }
    catch (e) { if (e.code !== 'ENOENT' || !writing || check === root) throw e; check = path.dirname(check); }
  }
  return target;
}
export function authorize(policy, name, approved) {
  const decision = policy == null ? ({read:'allow',write:'ask',bash:'ask'}[name] || 'deny') : policy[name];
  if (!['allow','ask'].includes(decision)) throw Error('Tool denied by chat policy');
  if (decision === 'ask' && !approved) throw Error('User approval required');
}
export async function workspaceMasks(root,mountRoot='/workspace') {
  const masks=[];
  async function mask(directory,relative='') {
    for(const entry of await fs.readdir(directory,{withFileTypes:true})) {
      const local=path.join(relative,entry.name), absolute=path.join(directory,entry.name), inside=path.join(mountRoot,local);
      if(entry.name==='.git')masks.push(['--ro-bind',absolute,inside]);
      else if(entry.name==='.env'||entry.name.startsWith('.env.')||['.ssh','.aws','.codex','.claude','.npmrc','.pypirc'].includes(entry.name))masks.push(entry.isDirectory()?['--tmpfs',inside]:['--ro-bind','/dev/null',inside]);
      else if(entry.isDirectory()&&!['node_modules','.elm-home','.cargo-home','elm-stuff','target','dist'].includes(entry.name))await mask(absolute,local);
    }
  }
  await mask(root);return masks;
}
export async function execute(root, command, signal) {
  const {name,args,approved} = command;
  if(signal?.aborted) throw Error('Tool cancelled');
  authorize(command.policy,name,approved);
  if (name === 'read') {
    const file = await workspacePath(root,args.path);
    const handle = await fs.open(file,'r');
    try { const stat = await handle.stat(); if (stat.size > 4_000_000) throw Error('File exceeds 4 MB read budget'); const content = await handle.readFile('utf8'); if(content.includes('\0')) throw Error('Binary file unsupported'); const offset=Math.max(1,Number(args.offset)||1), limit=Math.min(2000,Math.max(1,Number(args.limit)||200)); return content.split('\n').slice(offset-1,offset-1+limit).map((line,i)=>`${offset+i}: ${line}`).join('\n').slice(0,cap); } finally {await handle.close();}
  }
  if (name === 'write') {
    if(typeof args.content !== 'string' || Buffer.byteLength(args.content)>2_000_000) throw Error('Invalid or oversized write');
    const target=await workspacePath(root,args.path,true); await fs.mkdir(path.dirname(target),{recursive:true}); await workspacePath(root,args.path,true);
    const temp=target+`.harness-${process.pid}.tmp`; await fs.writeFile(temp,args.content,{mode:0o600}); await fs.rename(temp,target); return `Wrote ${Buffer.byteLength(args.content)} bytes to ${args.path}`;
  }
  if (name !== 'bash' || typeof args.command !== 'string') throw Error('Unknown tool or invalid arguments');
  const sandboxMasks=await workspaceMasks(root);
  return new Promise((resolve,reject)=>{
    const env={PATH:'/usr/bin:/bin',HOME:'/tmp',LANG:'C.UTF-8'};
    // Fail closed if the OS sandbox is unavailable; no shell allowlist pretends to be a sandbox.
    const mounts=['--unshare-all','--die-with-parent','--new-session','--ro-bind','/usr','/usr','--ro-bind','/bin','/bin','--ro-bind','/lib','/lib','--ro-bind','/lib64','/lib64','--proc','/proc','--dev','/dev','--tmpfs','/tmp',command.policy?.write==='deny'?'--ro-bind':'--bind',root,'/workspace','--chdir','/workspace'];
    for(const entry of sandboxMasks) mounts.push(...entry);
    const child=spawn('bwrap',[...mounts,'/bin/bash','--noprofile','--norc','-c',args.command],{cwd:root,env,detached:true,stdio:['ignore','pipe','pipe']}); let output='', stopped=false;
    const stop=()=>{stopped=true;try{process.kill(-child.pid,'SIGKILL');}catch{}};
    const timer=setTimeout(stop,Math.min(120000,Math.max(100,Number(args.timeoutMs)||30000))); signal?.addEventListener('abort',stop,{once:true});
    const append=data=>{output+=data.toString();if(Buffer.byteLength(output)>cap){output=output.slice(0,cap)+'\n[Output limit reached]';stop();}};
    child.stdout.on('data',append);child.stderr.on('data',append);child.on('error',reject);child.on('close',code=>{clearTimeout(timer);signal?.removeEventListener('abort',stop);const result=`${output}\n[exit ${code}${stopped?', stopped by budget/cancellation':''}]`;if(code===0&&!stopped)resolve(result);else reject(Error(result));});
  });
}
