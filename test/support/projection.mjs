import {createRequire} from 'node:module';
const Elm=createRequire(import.meta.url)('../../dist/server.cjs').Elm;
export async function projectFixture(snapshot){
 const app=Elm.Server.Main.init({flags:{document:snapshot.document,root:'/workspace',system:'',append:'',project:''}});
 const projected=await new Promise(resolve=>app.ports.outgoing.subscribe(event=>{if(event.type==='Snapshot')resolve(event.data);}));
 projected.public.runs=(snapshot.runs||[]).map(run=>({...run,purpose:run.purpose||'conversation'}));
 return {...projected,...snapshot,public:projected.public};
}
