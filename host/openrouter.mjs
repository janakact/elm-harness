export async function stream(body,key,signal,onChunk) {
  if(!key) throw Error('OPENROUTER_API_KEY is missing');
  const response=await fetch('https://openrouter.ai/api/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${key}`},body:JSON.stringify(body),signal});
  if(!response.ok) throw Error(`OpenRouter ${response.status}: ${(await response.text()).slice(0,1000)}`);
  let buffer='',done=false;
  const decoder=new TextDecoder();
  for await(const bytes of response.body) {
    buffer=(buffer+decoder.decode(bytes,{stream:true})).replaceAll('\r\n','\n');
    let boundary;
    while((boundary=buffer.indexOf('\n\n'))>=0){const frame=buffer.slice(0,boundary);buffer=buffer.slice(boundary+2);const data=frame.split('\n').filter(l=>l.startsWith('data:')).map(l=>l.slice(5).trimStart()).join('\n');if(!data)continue;if(data==='[DONE]'){done=true;continue;}onChunk(JSON.parse(data));}
  }
  if(!done) throw Error('Model stream interrupted before [DONE]');
}
