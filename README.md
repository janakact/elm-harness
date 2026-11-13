# Elm Agent Harness

An Elm coding-agent harness following `elm_harness_design_v0.3.md`. The canonical graph and agent loop execute in an Elm `Platform.worker` on Node. Browser and terminal clients are also Elm programs. Small JavaScript adapters handle OS/network effects and rich-rendering leaves. Rust is no longer used.

For everyday use, start with the **[User guide](docs/USER_GUIDE.md)**. It covers setup, chats and workspaces, model selection, agent follow-ups, permissions, commands and troubleshooting.

## Start

Requires Node.js 22+, npm, and Linux Bubblewrap (`bwrap`) for sandboxed bash and external agent jobs. The Elm compiler is installed with npm.

```sh
npm install
npm start
```

Set `OPENROUTER_API_KEY` in `.env` before sending a native chat prompt. Codex and Claude jobs use their own CLI authentication; see the [agent setup guide](docs/USER_GUIDE.md#use-codex-or-claude).

Open **http://127.0.0.1:8787**. The host loads `OPENROUTER_API_KEY` from `.env` or the environment; clients never receive it. The default model is `deepseek/deepseek-v4-flash`. The gear button in the chat header opens **Chat settings** for its model, permissions, context budget and effective prompt. The sidebar **Workspace** button opens folder navigation separately.

Run `npm run tui` in a terminal for the full-screen interface. It compiles Elm, connects to the backend if it is already running, or starts a local backend automatically. A backend started by the TUI stops when you quit; an existing backend stays running. `HARNESS_URL` connects to a separately managed server without starting one.

The TUI has a fixed composer, scrollable conversation and selected-message inspector. Wide terminals show chat and compact history sidebars; narrow terminals show the selected pane. History contains only the current chat and uses Chat/Tool labels. Incoming streams preserve draft text and the selected history node.

| Key | Action |
| --- | --- |
| Tab | Switch panes |
| F2 / F3 / F4 | Chats / history / composer |
| ↑ / ↓ | Navigate the active list or scroll conversation |
| Enter in history | Inspect the complete selected message/tool output |
| PageUp / PageDown | Scroll conversation or inspector |
| Esc | Return to conversation and composer |
| Enter / Alt+Enter | Send / insert a line break |
| Ctrl+N | New chat |
| F6, then 1 / 2 / 3 | Session plugin: toggle/reset count or start a new chat |
| F7 | External agent jobs for this chat |
| F5, then y / n | Review pending tool arguments, allow once / deny |
| Ctrl+R / Ctrl+X | Resume / stop current run |
| F1 | Keyboard help |
| Ctrl+C / Ctrl+Q | Quit and restore the terminal |

Bracketed paste inserts multiline content without sending it. Left/right, Home/End, Backspace/Delete, Ctrl+U and Ctrl+K edit the composer. Slash commands include `/new`, `/fork NAME`, `/model MODEL`, `/send THREAD MESSAGE`, `/permissions`, `/budget`, `/context`, `/usage`, `/compact`, `/focus THREAD`, `/select NODE`, `/approve CALL`, `/deny CALL`, `/cancel RUN`, `/help`, and `/quit`. All mutations go through the same canonical Elm worker.

## Coding workflow

The model-facing tool vocabulary is **read**, **write**, and **bash**. Read is bounded and limited to workspace text files. Each chat persists an **allow / ask / deny** policy for each tool. Defaults allow read and ask for each write/bash call. Denied tools are omitted from that chat's model schemas and rejected if requested anyway. All calls, results and permission decisions are graph events. The Elm loop sends results back to the model automatically until it finishes or reaches its budget.

Change permissions in **Chat settings**, or use `/permissions TOOL allow|ask|deny`. `/permissions read-only` allows read and denies write/bash; `/permissions ask` asks for all three tools. Revoking a tool clears its pending approvals and aborts its active execution. Forks inherit the source chat's permissions and input budget; new chats start with defaults. The host rechecks permissions when queued tools start.

Bash runs in a Bubblewrap namespace with the workspace mounted at `/workspace`, no network, a temporary home, a minimal environment, and masked root credentials. It cannot see the host home directory. It fails closed when Bubblewrap is unavailable. Shell commands should use relative workspace paths (the system prompt reports the host root for file tools). Bash can inspect files and modify the workspace unless write is denied; denying write mounts its workspace read-only. Deny bash as well for the read-only preset. Mutating tools are serialized to avoid simultaneous checkout edits. Review commands before approving them. `write` can create or replace any authorized workspace source file.

Click **+ New chat** in the left sidebar to start a fresh conversation with no inherited history. Existing chats remain available in the sidebar. In the terminal use `/new` or `/new TITLE`. Forking from a node shares its ancestry instead.

Conversations are ordered by their latest activity, newest first. Each shows a local date; its tooltip includes the workspace path and last-active time. The folder name appears once in the sidebar workspace picker, rather than beneath every chat. Older chats use recorded message dates when available; missing dates are shown as unavailable.

The page stays fixed in the viewport; the chat scrolls with its composer anchored below. **Graph & details** opens the history index and full selected-node view. Select a node, enter an optional branch name, and click **Fork from here** to create an independent chat sharing history up to that point. Forking does not start a model request or replay an unfinished tool; send a prompt or click **Run** to continue.

To share context, select a node, choose a **Reference recipient**, optionally add a note, and click **Send reference**. The recipient receives the selected node's captured content and a graph reference. An empty note uses a default message. An idle recipient uses it on its next prompt or **Run**; a busy recipient receives it at its next turn boundary through its durable inbox. Neither action creates an isolated Git checkout; branches retain the source workspace directory.

Markdown supports code, lists, tables, links and math `\(...\)`, `\[...\]`, and `$$...$$`. KaTeX and syntax highlighting are local assets. Code has a copy button; terminal math retains readable LaTeX. Untrusted HTML is sanitized.

## Codex and Claude jobs

Open **Agents** in the chat header (or enter `/agent` with no arguments) to start a read-only Codex or Claude Code job. Choose its runner and model from the dropdown, then describe the task. Codex choices come from its local model catalog; Claude offers Sonnet, Opus and Haiku aliases. CLI default and a custom model ID remain available. Changing the runner resets the model selection. A new job captures the current chat context and workspace. The native OpenRouter agent remains this chat's default; the OpenRouter model name is never passed to an external CLI.

Both chat views immediately show a sending indicator for `/agent`, followed by queued/running progress and streamed output. Full Codex/Claude responses stay visible in the conversation after completion; the drawer also shows tool observations, reported usage and failures. Cancelled or failed partial responses remain in history. **Cancel job** stops the child process. **Continue session** beside the response or in the drawer sends a follow-up to that job's recorded native session, using its original workspace and configured model. You can return later with `/agent resume JOB MESSAGE`, preserving its native conversation history. A fresh job always starts a fresh session. **Use result as context** beside a response (or **Send result to chat** in the drawer) delivers a captured result into the recipient's normal context/inbox without starting a model call. Earlier attempt results remain in the immutable history graph. Forking a conversation does not copy or resume an external session.

The same commands work in the browser and TUI:

```text
/agent codex Review the implementation and identify missing tests
/agent claude Explain the architecture
/agent codex --model MODEL_ID Review the error handling
/agents
/agent resume j1 Check the error handling too
/agent cancel j1
/agent report j1
/agent report j1 t2
```

F7 opens an additional live job view in the TUI; responses also appear directly in the conversation. Job IDs appear in the view. External jobs and native requests share `HARNESS_CONCURRENCY`. Jobs wait for a durable save before starting. Restart marks queued/running jobs **Interrupted** and never automatically replays them; explicitly resume a recorded session or create a new job.

Install and authenticate the official CLIs before use. Startup probes verify the installed flags and Bubblewrap; unavailable runners show the reason in the drawer. Existing mise installations are resolved without invoking auto-installing wrappers. `HARNESS_CODEX_BIN` and `HARNESS_CLAUDE_BIN` override executable paths. Codex accepts `OPENAI_API_KEY` or its saved login; Claude accepts `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` or its saved Linux login. The OpenRouter key does not authenticate either CLI. Login material is copied on first use into private runner storage; user/project CLI configuration, hooks and MCP servers are not loaded.

Both adapters run inside a Bubblewrap process namespace with the workspace mounted read-only, a private writable CLI home, temporary files and masked workspace secrets. Codex also uses its read-only sandbox with approvals disabled. Claude uses restricted mode with only Read/Glob/Grep and no interactive permission prompts. This external profile is separate from the native chat's three-tool policy. The wrapper permits model API networking; it is write isolation, not a network-isolated native bash tool. Tool observations never cause our native tools to execute again.

Private CLI sessions are stored by default under `$XDG_STATE_HOME/elm-harness/runners` (or `~/.local/state/elm-harness/runners`), separated by harness state-file identity. `HARNESS_RUNNER_HOME` overrides this and must be outside the workspace. Keep that directory if you need to resume native sessions. Each attempt has a ten-minute timeout, a 2 MB process-output limit and a 500,000-character text limit. Exceeding a limit fails the job visibly rather than reporting a silently truncated success. Runner usage stays separate from native OpenRouter totals: Codex reports attempt tokens; Claude reports its CLI usage and cumulative session cost, which is replaced rather than added again on resume. Missing usage remains unknown.

The adapters follow the [official Codex non-interactive interface](https://learn.chatgpt.com/docs/non-interactive-mode) and [Claude's programmatic interface](https://code.claude.com/docs/en/headless). CLI capabilities were checked locally; automated end-to-end tests use fixture processes and make no paid provider requests. Worktree writes and delegated task/join workflows are still the next increment.

## Prompts and context

The default system prompt is composed in Elm. Workspace `SYSTEM.md` replaces the default preamble; `APPEND_SYSTEM.md` adds instructions; `AGENTS.md` supplies project instructions. Restart after changing prompt files. The effective prompt and its version are recorded with each model request. Tool output and branch messages remain task data.

Chat settings opens in a separate drawer, so it does not resize the conversation. Workspace navigation opens its own folder picker.

The chat meter and `/context` show an **estimated input size**, including the effective prompt and permitted tool schemas. Each chat has a configurable estimated input budget (default 50,000; set it in Settings or `/budget TOKENS`). This estimate is a local heuristic, not the model's tokenizer or advertised context capacity. An oversized request stops with a notice; the harness does not silently truncate it. The 25-tool-round guard also remains.

Click **Compact context** or run `/compact` to generate a summary with the chat's selected model. The summary call has no tools. Review and edit the preview, then click **Apply reviewed summary** or run `/compact apply [EDITED TEXT]`. `/compact preview` opens the complete preview in the TUI; `/compact discard` keeps the original context. A summary is applied only after explicit acceptance against its captured source head. Later context starts at the accepted summary; every original graph node remains available. User prompts and references arriving during review wait until apply/discard. Failed, truncated or cancelled summaries leave the original context in use. Unaccepted previews are discarded on restart. `/compact SUMMARY` still accepts a summary you supply directly.

The meter and `/usage` also show **provider-reported** token totals and cost in credits, persisted once per request and attributed to the owning chat, model and conversation/compaction purpose. Forks do not inherit the parent's billed usage. Missing cost stays unknown or is marked partial; prices are never inferred. Summary generation is an additional model request and appears in these totals. The usage fields follow [OpenRouter's usage accounting format](https://openrouter.ai/docs/cookbook/administration/usage-accounting).

## State and configuration

`workspace.json` has independent core and user namespaces. The host serializes atomic saves, fsyncs temporary files, and keeps `workspace.json.bak`. Unsupported/invalid documents are preserved and displayed as errors. Interrupted tools receive explicit recovery results; commands are never automatically replayed after a restart. User v1 data migrates by adding the v2 display default.

Environment options: `PORT` (8787), `HARNESS_ROOT` (current directory), `HARNESS_WORKSPACE` (workspace.json), `HARNESS_CONCURRENCY` (4, range 1–16), and terminal `HARNESS_URL`.

## Browser usability and state inspection

Selecting a chat, opening a new chat/workspace, or choosing a slash command focuses the composer. Unsent drafts remain separate for each chat; streaming updates do not steal focus while you inspect settings or history.

The small **{}** button in the header opens **Application state**, a read-only JSON explorer. It shows the backend's public snapshot (saved core/user data, runs, graph projection and navigation results) together with the browser's local state. Expand/collapse branches, search keys or values, refresh the captured snapshot, or copy JSON. The snapshot remains stable while you explore it. Escape, the close button, or the backdrop closes the popup; keyboard focus returns to the opener. Host environment variables and API credentials are not added to this projection.

See [DESIGN_STATUS.md](DESIGN_STATUS.md) for the remaining v0.3 work and recommended next implementation priorities.

## Small typed plugins

[User.elm](elm/User.elm) is a working state/view plugin. It imports shared [App.Public](elm/App/Public.elm) types, owns its reply counter and preferences, and returns typed core action requests. Its sidebar/inspector views use the same small [App.Ui](elm/App/Ui.elm) description in HTML and the TUI. Use F6 in the terminal to open its controls. Adding a plugin means composing an ordinary Elm module and recompiling.

Browser/TUI consume a versioned public projection, independently of the saved-document format. Plugin state migrates independently; an unsupported or malformed session-plugin payload is preserved and disables that plugin while core chats remain usable. Native model/tool effects wait for save acknowledgment, and correlated action acceptance is separate from completion.

See [PLUGIN_RUNNER_DESIGN.md](PLUGIN_RUNNER_DESIGN.md) and its high-level SVG for the wiring and remaining work.

## Source and checks

- `elm/Core.elm`: canonical graph, native loop, inbox and scheduling.
- `elm/App/Public.elm`, `elm/App/Projection.elm`, `elm/App/RunStatus.elm`: public client/plugin types, backend projection and typed lifecycle.
- `elm/Agent/*.elm`, `elm/Providers/OpenRouter.elm`: provider-neutral context and OpenRouter codec.
- `elm/Runner.elm`, `elm/Runner/*.elm`: external job state, session ownership, CLI arguments, normalized events and shared presentation.
- `elm/App/Ui.elm`: small shared plugin view vocabulary.
- `elm/Server/Main.elm`: canonical Elm composition, ports and persistence decisions.
- `elm/Prompt.elm`, `elm/Protocol.elm`: schemas, prompts and protocol/migrations.
- `elm/Policy.elm`, `elm/Accounting.elm`: typed tool policies, usage records and local context estimates.
- `elm/StateViewer.elm`: read-only expandable/searchable JSON state explorer.
- `elm/Main.elm`, `elm/Terminal/Main.elm`, `elm/Terminal/Screen.elm`, `elm/Rich.elm`: clients and shared rich-content semantics.
- `elm/User.elm`: user-owned state and event hook; retained across framework updates.
- `host/*.mjs`: transport, storage, tools and terminal adapters.

`npm test` compiles all three Elm programs and exercises the compiled backend, terminal and process sandbox. `node test/ui-polish-check.mjs`, `node test/workspace-browser-check.mjs`, `node test/session-browser-check.mjs`, and `node test/runner-browser-check.mjs` start isolated fixture servers to check navigation, state inspection, workspaces, permissions, usage, compaction, fork/reference controls and external jobs. Provider and CLI fixtures make no external model requests. With a test server on port 8788, `node test/browser-check.mjs` checks rich rendering and viewport behavior. Set `HARNESS_URL` to use another address. Browser checks require Chromium at `/usr/bin/chromium`.
