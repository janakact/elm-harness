import { createRequire } from 'node:module';
import readline from 'node:readline';
const app=createRequire(import.meta.url)('../dist/terminal.cjs').Elm.Terminal.Main.init({flags:null});
const base=process.env.HARNESS_URL||'http://127.0.0.1:8787';
const rl=readline.createInterface({input:process.stdin,output:process.stdout,prompt:'you › '});let previous='';
app.ports.outgoing.subscribe(async command=>{if(command.type==='Draw'&&command.text!==previous){previous=command.text;process.stdout.write('\x1b[2J\x1b[H'+command.text);rl.prompt(true);}if(command.type==='Action'){try{const r=await fetch(base+'/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...command.data,protocolVersion:1})});if(!r.ok)console.error(await r.text());}catch(e){console.error(e.message);}}});
rl.on('line',line=>{app.ports.incoming.send({type:'Line',line});rl.prompt();});
try{const response=await fetch(base+'/api/events');let buffer='';const decoder=new TextDecoder();for await(const chunk of response.body){buffer+=decoder.decode(chunk,{stream:true});let end;while((end=buffer.indexOf('\n\n'))>=0){const frame=buffer.slice(0,end);buffer=buffer.slice(end+2);if(frame.startsWith('data: '))app.ports.incoming.send({type:'Snapshot',data:JSON.parse(frame.slice(6))});}}}catch(e){console.error('Start npm start first:',e.message);process.exitCode=1;rl.close();}
