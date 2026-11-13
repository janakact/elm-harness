// Presentation and transport only. All application state lives in Elm.
class MathView extends HTMLElement {connectedCallback(){this.draw();} static get observedAttributes(){return ['latex','display'];}attributeChangedCallback(){this.draw();}draw(){if(globalThis.katex)katex.render(this.getAttribute('latex')||'',this,{displayMode:this.hasAttribute('display'),trust:false,throwOnError:false,output:'htmlAndMathml'});}}
customElements.define('math-view',MathView);
const clientId=crypto.randomUUID();
const app=Elm.Main.init({node:document.getElementById('app'),flags:{clientId}});
app.ports.action.subscribe(async action=>{try{const r=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...action,actionId:action.actionId||crypto.randomUUID(),protocolVersion:1,clientId})});if(!r.ok)throw Error(await r.text());}catch(e){app.ports.network.send(e.message);}});
const events=new EventSource('/api/events');events.onmessage=e=>app.ports.snapshot.send(JSON.parse(e.data));events.addEventListener('action-result',event=>app.ports.actionResult.send(JSON.parse(event.data)));events.onerror=()=>app.ports.network.send('Connection interrupted. Reconnecting…');
let follow=true,scheduled=false;
document.addEventListener('scroll',event=>{if(event.target.id==='chat'){const el=event.target;follow=el.scrollHeight-el.scrollTop-el.clientHeight<90;}},true);
const decorate=()=>{scheduled=false;document.querySelectorAll('pre code:not([data-decorated])').forEach(code=>{code.dataset.decorated='true';globalThis.hljs?.highlightElement(code);const copy=document.createElement('button');copy.className='copy-code';copy.textContent='Copy';copy.onclick=async()=>{await navigator.clipboard.writeText(code.textContent);copy.textContent='Copied';setTimeout(()=>copy.textContent='Copy',1200);};code.parentElement.append(copy);});const chat=document.getElementById('chat');if(follow&&chat)chat.scrollTop=chat.scrollHeight;};
new MutationObserver(()=>{if(!scheduled){scheduled=true;requestAnimationFrame(decorate);}}).observe(document.body,{childList:true,subtree:true,characterData:true});
// Native dialog and clipboard are presentation effects requested by Elm.
let stateReturnFocus;
const panelReturnFocus=new Map();
app.ports.ui.subscribe(effect=>{
  if(effect.type==='OpenPanel'){
    if(!document.getElementById(effect.id)?.open)panelReturnFocus.set(effect.id,document.activeElement);
    requestAnimationFrame(()=>{const dialog=document.getElementById(effect.id);if(dialog){if(!dialog.open)dialog.showModal();document.getElementById(effect.focus)?.focus();}});
  }else if(effect.type==='ClosePanel'){
    requestAnimationFrame(()=>{const dialog=document.getElementById(effect.id);if(dialog?.open){dialog.close();const target=effect.focus?document.getElementById(effect.focus):panelReturnFocus.get(effect.id);if(target?.isConnected)target.focus();panelReturnFocus.delete(effect.id);}});
  }else if(effect.type==='ChatChanged'){
    requestAnimationFrame(()=>{follow=true;const chat=document.getElementById('chat');if(chat)chat.scrollTop=chat.scrollHeight;});
  }else if(effect.type==='OpenState'){
    stateReturnFocus=document.activeElement;
    requestAnimationFrame(()=>{const dialog=document.getElementById('state-dialog');if(dialog&&!dialog.open){dialog.showModal();dialog.querySelector('input')?.focus();}});
  }else if(effect.type==='CloseState'){
    requestAnimationFrame(()=>{document.getElementById('state-dialog')?.close();stateReturnFocus?.focus();});
  }else if(effect.type==='CopyState'){
    if(!navigator.clipboard){app.ports.uiResult.send({ok:false});return;}
    navigator.clipboard.writeText(effect.text).then(()=>app.ports.uiResult.send({ok:true})).catch(()=>app.ports.uiResult.send({ok:false}));
  }
});
