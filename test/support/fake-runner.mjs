// Deliberately standalone: used as a real child under Bubblewrap, with no provider.
import fs from 'node:fs';
import {randomUUID} from 'node:crypto';
const args=process.argv.slice(2);
if(args.includes('--help')){
 console.log('--json --ignore-user-config --ignore-rules --sandbox --restricted --safe-mode --tools --strict-mcp-config --permission-prompts --include-partial-messages');process.exit(0);
}
if(args.includes('--version')){console.log('fixture-runner 1.0.0');process.exit(0);}
let input='';for await(const bytes of process.stdin)input+=bytes;
const claude=args.includes('--print'),resume=args.indexOf('--resume');
const session=claude?(resume>=0?args[resume+1]:`claude-fixture-${randomUUID()}`):(args.includes('resume')?args[args.indexOf('resume')+1]:`codex-fixture-${randomUUID()}`);
const emit=value=>process.stdout.write(JSON.stringify(value)+'\n');
if(input.includes('MALFORMED_JSON')){process.stdout.write('{broken\n');setTimeout(()=>{},10000);}
else if(input.includes('EXCESS_OUTPUT')){process.stdout.write('x'.repeat(100000));}
else if(input.includes('WAIT_FOR_CANCEL')){emit(claude?{type:'system',subtype:'init',session_id:session}:{type:'thread.started',thread_id:session});setTimeout(()=>{},10000);}
else if(input.includes('EXIT_FAILURE')){console.error('Fixture transport failure');process.exitCode=7;}
else{
 let writeDenied=false;try{fs.writeFileSync('forbidden-write.txt','Must not be written');}catch{writeDenied=true;}
 let secret='';try{secret=fs.readFileSync('.env','utf8');}catch{}
 const output=`Fixture review ✓. Workspace write denied: ${writeDenied}. Secret masked: ${secret===''}.`;
 if(claude){emit({type:'system',subtype:'init',session_id:session});emit({type:'stream_event',event:{delta:{type:'text_delta',text:input.includes('SLOW_RESPONSE')?'Working draft from Claude.':'Fixture '}}});if(input.includes('SLOW_RESPONSE'))await new Promise(resolve=>setTimeout(resolve,1500));emit({type:'result',session_id:session,is_error:false,result:output,usage:{input_tokens:20,output_tokens:8},total_cost_usd:resume>=0?0.03:0.02});}
 else{
  emit({type:'thread.started',thread_id:session});emit({type:'item.completed',item:{id:'observed-read',type:'command_execution',command:'Inspect README.md'}});
  if(input.includes('SLOW_RESPONSE')){emit({type:'item.updated',item:{id:'answer',type:'agent_message',text:'Working draft from Codex.'}});await new Promise(resolve=>setTimeout(resolve,1500));}
  // Split a multibyte UTF-8 character and a JSON line across writes.
  const event=Buffer.from(JSON.stringify({type:'item.completed',item:{id:'answer',type:'agent_message',text:output}})+'\n');const at=event.indexOf(Buffer.from('✓'))+1;process.stdout.write(event.subarray(0,at));await new Promise(resolve=>setTimeout(resolve,15));process.stdout.write(event.subarray(at));emit({type:'turn.completed',usage:{input_tokens:20,output_tokens:8}});
 }
}
