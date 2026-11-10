# Elm Agent Harness

An Elm coding-agent harness following `elm_harness_design_v0.3.md`. The canonical graph and agent loop execute in an Elm `Platform.worker` on Node. Browser and terminal clients are also Elm programs. Small JavaScript adapters handle OS/network effects and rich-rendering leaves. Rust is no longer used.

## Start

Requires Node.js 22+, npm, and Linux Bubblewrap (`bwrap`) for sandboxed bash. The Elm compiler is installed with npm.

```sh
npm install
npm start
```

Open **http://127.0.0.1:8787**. The host loads `OPENROUTER_API_KEY` from `.env` or the environment; clients never receive it. The default model is `deepseek/deepseek-v4-flash`. Settings changes the selected thread's model and shows the effective system prompt.

In another terminal, run `npm run tui` for the interactive terminal client. Plain text sends a prompt; `/select NODE`, `/focus THREAD`, `/fork NAME`, `/model MODEL`, `/approve CALL`, `/deny CALL`, `/cancel RUN`, `/send THREAD MESSAGE`, and `/compact SUMMARY` operate through the same canonical Elm worker. The terminal must connect to the running server.

## Coding workflow

The model has exactly **read**, **write**, and **bash**. Read is bounded and limited to workspace text files. Write and bash require approval of the displayed arguments for each call. All calls, results and approval decisions are graph events. The Elm loop sends results back to the model automatically until it finishes or reaches its budget.

Bash runs in a Bubblewrap namespace with the workspace mounted at `/workspace`, no network, a temporary home, a minimal environment, and masked root credentials. It cannot see the host home directory. It fails closed when Bubblewrap is unavailable. Shell commands should use relative workspace paths (the system prompt reports the host root for file tools). Mutating tools are serialized to avoid simultaneous checkout edits. Review commands before approving them. `write` can create or replace any authorized workspace source file.

Click **+ New chat** in the left sidebar to start a fresh conversation with no inherited history. Existing chats remain available in the sidebar. In the terminal use `/new` or `/new TITLE`. Forking from a node shares its ancestry instead.

The page stays fixed in the viewport; the chat scrolls with its composer anchored below. **Graph & details** opens the history index and full selected-node view. Select a node to fork or deliver captured context to another thread. Messages sent while a thread is running wait in its durable inbox.

Markdown supports code, lists, tables, links and math `\(...\)`, `\[...\]`, and `$$...$$`. KaTeX and syntax highlighting are local assets. Code has a copy button; terminal math retains readable LaTeX. Untrusted HTML is sanitized.

## Prompts and context

The default system prompt is composed in Elm. Workspace `SYSTEM.md` replaces the default preamble; `APPEND_SYSTEM.md` adds instructions; `AGENTS.md` supplies project instructions. Restart after changing prompt files. The effective prompt and its version are recorded with each model request. Tool output and branch messages remain task data.

To compact, put a faithful summary in the composer and click **Compact** (or `/compact SUMMARY`). Later context begins at that summary; original graph nodes remain available. The loop stops after 25 tool rounds without another user instruction or when serialized context exceeds 200,000 characters, prompting explicit compaction.

## State and configuration

`workspace.json` has independent core and user namespaces. The host serializes atomic saves, fsyncs temporary files, and keeps `workspace.json.bak`. Unsupported/invalid documents are preserved and displayed as errors. Interrupted tools receive explicit recovery results; commands are never automatically replayed after a restart. User v1 data migrates by adding the v2 display default.

Environment options: `PORT` (8787), `HARNESS_ROOT` (current directory), `HARNESS_WORKSPACE` (workspace.json), `HARNESS_CONCURRENCY` (4, range 1–16), and terminal `HARNESS_URL`.

## Source and checks

- `elm/Core.elm`: pure graph, context, agent loop, inbox and scheduling.
- `elm/Server/Main.elm`: canonical Elm composition, ports and persistence decisions.
- `elm/Prompt.elm`, `elm/Protocol.elm`: schemas, prompts and protocol/migrations.
- `elm/Main.elm`, `elm/Terminal/Main.elm`, `elm/Rich.elm`: clients and shared rich-content semantics.
- `elm/User.elm`: user-owned state and event hook; retained across framework updates.
- `host/*.mjs`: transport, storage, tools and terminal adapters.

`npm test` compiles all three Elm programs and exercises the compiled backend. With a test server on port 8788, `node test/browser-check.mjs` checks rendering and viewport behavior. Set `HARNESS_URL` to use another address. Browser checks require Chromium at `/usr/bin/chromium`.
