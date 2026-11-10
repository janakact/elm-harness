import fs from 'node:fs/promises';
export function storage(file) {
  let chain=Promise.resolve();
  return { flush(){return chain;}, async read(){try{return JSON.parse(await fs.readFile(file,'utf8'));}catch(e){if(e.code==='ENOENT')return null;throw e;}}, write(document){chain=chain.then(async()=>{const temp=file+'.tmp';const handle=await fs.open(temp,'w',0o600);try{await handle.writeFile(JSON.stringify(document,null,2));await handle.sync();}finally{await handle.close();}try{await fs.copyFile(file,file+'.bak');}catch(e){if(e.code!=='ENOENT')throw e;}await fs.rename(temp,file);});return chain;} };
}
