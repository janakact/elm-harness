// Terminal I/O only: Elm owns editing, navigation, layout and domain actions.
import { createRequire } from 'node:module';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';

if (!process.stdin.isTTY || !process.stdout.isTTY) {
  console.error('The TUI needs an interactive terminal. Run npm run tui in a terminal window.');
  process.exit(1);
}
const args=process.argv.slice(2);
const workspaceAt=args.indexOf('--workspace');
if(workspaceAt>=0&&!args[workspaceAt+1]){console.error('Usage: npm run tui -- --workspace /path/to/project [--new]');process.exit(1);}
const launchWorkspace=workspaceAt>=0?args[workspaceAt+1]:(args.find(arg=>arg.startsWith('--workspace='))?.slice(12)||'');
const clientId=randomUUID();
const app = createRequire(import.meta.url)('../dist/terminal.cjs').Elm.Terminal.Main.init({ flags: {clientId,workspace:launchWorkspace,newChat:args.includes('--new')} });
const base = process.env.HARNESS_URL || `http://127.0.0.1:${process.env.PORT || 8787}`;
const transport = new AbortController();
let backend, closing = false, pasted = null, snapshotTimer, queuedSnapshot, lastFrame = '';
const emit = event => { if (!closing) app.ports.incoming.send(event); };
const resize = () => emit({ type: 'Resize', columns: process.stdout.columns || 80, rows: process.stdout.rows || 24 });
const network = error => emit({ type: 'Network', error });

function cleanup(code = 0) {
  if (closing) return;
  closing = true;
  clearTimeout(snapshotTimer);
  transport.abort();
  process.stdin.setRawMode(false);
  process.stdin.pause();
  process.stdout.write('\x1b[0m\x1b[?2004l\x1b[?25h\x1b[?1049l');
  backend?.kill('SIGINT');
  process.exitCode = code;
}
app.ports.outgoing.subscribe(async command => {
  if (closing) return;
  if (command.type === 'Draw') {
    const cursor = command.cursor || { visible: false };
    const frame = command.text + JSON.stringify(cursor);
    if (frame !== lastFrame) {
      lastFrame = frame;
      process.stdout.write('\x1b[?25l\x1b[H' + command.text.split('\n').join('\x1b[K\r\n') + '\x1b[K');
      if (cursor.visible) process.stdout.write(`\x1b[${cursor.row};${cursor.column}H\x1b[?25h`);
    }
  } else if (command.type === 'Quit') cleanup();
  else if (command.type === 'Action') {
    try {
      const response = await fetch(base + '/api/action', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...command.data, actionId:command.data.actionId||randomUUID(), protocolVersion: 1, clientId }), signal: transport.signal });
      if (!response.ok) throw Error(await response.text());
    } catch (error) { if (!closing) network(error.message); }
  }
});
readline.emitKeypressEvents(process.stdin);
process.stdin.setRawMode(true);
process.stdin.resume();
process.stdout.write('\x1b[?1049h\x1b[2J\x1b[?25l\x1b[?2004h');
resize();
process.stdout.on('resize', resize);
process.stdin.on('keypress', (text, key = {}) => {
  if (key.sequence === '\x1b[200~' || key.name === 'paste-start') { pasted = ''; return; }
  if (key.sequence === '\x1b[201~' || key.name === 'paste-end') { if (pasted !== null) emit({ type: 'Paste', text: pasted }); pasted = null; return; }
  if (pasted !== null) { pasted += text || key.sequence || ''; return; }
  if (key.ctrl && ['c', 'q'].includes(key.name)) { cleanup(); return; }
  if (key.ctrl && key.name === 'd') { cleanup(); return; }
  if (key.name === 'return' || key.name === 'enter') emit({ type: 'Key', key: key.meta || key.shift ? 'alt+return' : 'return' });
  else if (key.ctrl || key.meta || ['up', 'down', 'left', 'right', 'home', 'end', 'pageup', 'pagedown', 'backspace', 'delete', 'escape', 'tab', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7'].includes(key.name)) emit({ type: 'Key', key: (key.ctrl ? 'ctrl+' : key.meta ? 'alt+' : '') + key.name });
  else if (text) emit({ type: 'Text', text });
});
process.on('SIGINT', () => cleanup());
process.on('SIGTERM', () => cleanup());
process.on('uncaughtException', error => { cleanup(1); console.error(error.message); });

async function connect() {
  try { await fetch(base + '/api/state', { signal: AbortSignal.timeout(2000) }); }
  catch (error) {
    if (process.env.HARNESS_URL) throw error;
    network('Starting local Elm backend…');
    backend = spawn(process.execPath, [new URL('./server.mjs', import.meta.url).pathname], { env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(Error('Backend did not start within 10 seconds')), 10000);
      backend.on('error', reject);
      backend.on('exit', code => { clearTimeout(timer); if (!closing) reject(Error(`Backend exited (${code}). Check your .env and saved workspace.`)); });
      backend.stdout.on('data', bytes => { if (bytes.toString().includes('Elm harness:')) { clearTimeout(timer); resolve(); } });
    });
  }
  while (!closing) {
    try {
      const response = await fetch(base + '/api/events', { signal: transport.signal });
      if (!response.ok) throw Error(`Backend returned ${response.status}`);
      let buffer = '';
      const decoder = new TextDecoder();
      for await (const chunk of response.body) {
        buffer = (buffer + decoder.decode(chunk, { stream: true })).replaceAll('\r\n', '\n');
        let end;
        while ((end = buffer.indexOf('\n\n')) >= 0) {
          const frame = buffer.slice(0, end); buffer = buffer.slice(end + 2);
          const data = frame.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
          if(data&&frame.includes('event: action-result')){emit({type:'ActionResult',data:JSON.parse(data)});continue;}
          if (data) { queuedSnapshot = JSON.parse(data); if (!snapshotTimer) snapshotTimer = setTimeout(() => { snapshotTimer = null; emit({ type: 'Snapshot', data: queuedSnapshot }); }, 33); }
        }
      }
      if (!closing) throw Error('Backend disconnected');
    } catch (error) {
      if (closing) break;
      network(error.message + ' · reconnecting…');
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
}
connect().catch(error => { cleanup(1); console.error(error.message); });
