# User guide

Elm Harness provides browser and terminal interfaces to the same saved conversations. Use the native OpenRouter agent for coding with approved tools, or launch a read-only Codex or Claude job for inspection and review.

## Start the app

From the repository directory, install dependencies once:

```sh
npm install
```

For the native chat agent, put your OpenRouter key in a file named `.env` in that directory:

```dotenv
OPENROUTER_API_KEY=your-openrouter-key
```

Start the browser app:

```sh
npm start
```

Open **http://127.0.0.1:8787**. The default native model is `deepseek/deepseek-v4-flash`. The gear button in the chat header opens **Chat settings** for the model, permissions, context budget and effective system prompt.

For the terminal interface, run:

```sh
npm run tui
```

It connects to an existing backend or starts one automatically. A backend started by the TUI stops when you quit; a separately started backend keeps running. Both commands compile Elm before starting. They do not watch source files: after backend changes, restart it; after browser-only changes, run `npm run build` and refresh. Restart after changing `.env` or workspace prompt files.

## Choose a workspace and start a chat

The sidebar **Workspace** button chooses a project folder. Its folder name, such as `elm-harness`, identifies the directory; it is not an agent profile.

- **Open workspace** returns to that folder's most recently active chat, or creates one if necessary.
- **New chat in workspace** starts an empty chat in the chosen folder.
- **+ New chat** starts an empty chat in the current folder.

Existing chats keep their original workspace. Conversations appear newest first by recorded activity, with local dates. Selecting a chat focuses the composer and restores its unsent draft. The page remains fixed while the conversation scrolls.

The same actions are available as commands. Quote paths containing spaces:

```text
/workspace "/path/to/project"
/new A fresh investigation
/new --workspace "/path/to/other project" Review changes
/rename Better chat title
/workspaces
/chats
```

To launch the TUI into a different folder and start a fresh chat:

```sh
npm run tui -- --workspace "/path/to/project" --new
```

Changing folders uses an existing directory. It does not create an isolated Git worktree.

## Use the native coding agent

Type a prompt and send it. In the browser, Enter sends and Shift+Enter inserts a line break. In the TUI, Enter sends and Alt+Enter inserts a line break; multiline paste stays in the composer until you send.

The native agent has three tools: **read**, **write** and **bash**. Defaults allow reading and ask before each write or shell call. Review requested arguments, then choose **Allow once** or **Deny**. Use **Stop**, `/stop`, or Ctrl+X in the TUI to stop the native run. Use **Run** or `/resume` to start another native turn.

Change per-chat permissions in **Chat settings**, or use:

```text
/permissions read-only
/permissions ask
/permissions bash deny
/permissions write ask
```

The native read-only preset denies both write and bash. Native bash runs without network access in a sandbox whose project directory is `/workspace`; this sandbox path differs from your host directory.

## Use Codex or Claude

Install and authenticate the CLI you want to use. The harness checks installed CLI capabilities and Bubblewrap at startup. An unavailable runner displays its reason in **Agents**. CLI authentication is separate from the OpenRouter key. Executable overrides and authentication options are listed in the [README](../README.md#codex-and-claude-jobs).

Open **Agents** in the chat header, or enter `/agent` with no arguments. Select **codex** or **claude**, choose a model from the dropdown, enter a request and click **Start read-only job**.

The model dropdown offers:

- **CLI default**, which lets the CLI choose its model.
- Visible models from the local Codex catalog, or Claude's Sonnet, Opus and Haiku aliases.
- **Custom model…**, where you can enter an exact model ID.

Changing runners resets the selection. If the Codex catalog is missing, CLI default and custom entry still work. Restart the harness after refreshing the CLI's local catalog. These choices are separate from the native chat's OpenRouter model. An account or CLI can reject a model it cannot access.

You can also launch directly from either composer:

```text
/agent codex Review this implementation and identify missing tests
/agent claude Explain how the state and views are connected
/agent codex --model MODEL_ID Review the error handling
```

A job captures the current conversation and workspace. **Sending…** appears immediately, followed by queued or running progress. Output appears directly in chat as the CLI emits it, and the full response remains visible after completion. The chat header also indicates active agent work. Open **Agents**, `/agents`, or **F7** in the TUI for additional job details, observations and usage.

Both external runners currently use a **read-only workspace**. Codex can inspect through its read-only tool environment; Claude is limited to Read/Glob/Grep. Changing the native chat's tool policy does not enable external writes. For editing, use the native coding agent with approved tools.

### Send another message to the same agent

After a job finishes, click **Continue session** beside its response or in **Agents**. Enter a follow-up and send it. You can also use its job ID:

```text
/agent resume j1 Explain your findings and suggest the next steps
```

This resumes that job's recorded native session, preserving its conversation history, workspace and configured model. It creates another attempt on the same job. Previous responses remain visible. Wait for the active attempt to finish, or cancel it before resuming. A new `/agent codex …` or `/agent claude …` command creates a fresh session instead.

To cancel an external job, choose **Cancel agent** in chat, **Cancel job** in the drawer, or:

```text
/agent cancel j1
```

The native `/stop` command controls the native run; use the job's cancel action for an external runner.

### Give the result to the native agent

Reading an external response does not automatically add it to the next native model request. Choose **Use result as context** beside a completed response, or **Send result to chat** in the drawer. Commands also support the current or another chat:

```text
/agent report j1
/agent report j1 t2
```

Delivery captures the completed result. A busy recipient queues it until a turn boundary. Reporting does not itself start a model request; ask a follow-up or use **Run** when ready. Cancelled and failed results cannot be reported as completed findings.

## Fork history and share references

Open **Graph & details**, select a history node, optionally name the branch, and choose **Fork from here**. The new chat shares history up to that node. Forking alone does not run a model or resume a Codex/Claude session. Conversation forks currently share their source workspace.

To send selected context to another chat, choose a **Reference recipient**, optionally add a note and click **Send reference**. The recipient gets captured content and a graph reference. An empty note uses a default message.

## Manage prompts, context and usage

Each workspace can provide `SYSTEM.md`, `APPEND_SYSTEM.md` and `AGENTS.md`. `SYSTEM.md` replaces the default preamble, `APPEND_SYSTEM.md` adds instructions, and `AGENTS.md` supplies project context. View the effective native prompt in **Chat settings** or `/prompt`. Restart to reload changed prompt files.

The chat meter shows an estimated input size and budget. `/context` opens details, `/usage` shows reported native usage, and `/budget TOKENS` changes the input budget. The estimate is not an exact model tokenizer. Runner usage appears separately with its job; missing usage is shown as unknown.

When context becomes large, click **Compact context** or enter `/compact`. Review and edit the generated summary, then explicitly apply it. Original history is retained. `/compact discard` keeps the existing context; `/compact apply` accepts a ready summary. You can also supply a summary directly with `/compact YOUR SUMMARY`.

## Inspect application state

The **{}** button opens a read-only JSON explorer. Expand or collapse branches, search, refresh its captured snapshot, or copy the JSON. The popup stays stable while you explore it. Escape or the close button returns focus to the opener.

The session plugin's sidebar controls manage its reply counter. In the TUI use **F6**, then **1** to toggle, **2** to reset or **3** to start a chat. The counter belongs to that sample plugin; it is separate from each chat's message count.

## Terminal shortcuts

| Key | Action |
| --- | --- |
| Tab | Switch panes |
| F2 / F3 / F4 | Chats / history / composer |
| F5, then y / n | Review and allow or deny a native tool call |
| F6 | Session plugin controls |
| F7 | External agent jobs |
| Enter in history | Inspect the selected message or tool output |
| PageUp / PageDown | Scroll |
| Esc | Return to the conversation and composer |
| Ctrl+N | New chat |
| Ctrl+R / Ctrl+X | Run or stop the native agent |
| Ctrl+C / Ctrl+Q | Quit the TUI |

Enter `/help` for the complete command list.

## Recovery and troubleshooting

| What you see | What to do |
| --- | --- |
| Agent job is queued | Wait for an execution slot or cancel another job. Native and external jobs share `HARNESS_CONCURRENCY`, which defaults to four. |
| Runner is unavailable | Read its reason in Agents, check the CLI installation and Bubblewrap, then restart. Use executable overrides when necessary. |
| Authentication or model error | Check that runner's own login and selected model. The OpenRouter key only serves the native agent. |
| Interrupted job after restart | Resume it explicitly if a native session was recorded, or start a new job. The harness never automatically replays it. |
| No session available to resume | Start a new job. Startup may have failed before the CLI reported a session, or its private session storage may be missing. |
| Timeout or output-limit error | Narrow the request and start or resume explicitly. Partial responses remain visible; a failed attempt is not presented as a completed result. |
| Changed code or prompt files are not reflected | Rebuild/refresh the browser or restart the backend as appropriate. There is no automatic watch mode. |
| Workspace action fails | Check that the directory exists and quote paths containing spaces. Existing chats retain their workspace. |

Chats and graph history are saved in `workspace.json` by default, with a backup. External CLI sessions live in a separate private runner directory; keep it to resume those sessions. Configuration paths, environment options and process limits are documented in the [README](../README.md#state-and-configuration) and its [runner section](../README.md#codex-and-claude-jobs).

For architecture and planned features, see the [runner design](../PLUGIN_RUNNER_DESIGN.md) and [remaining work](../DESIGN_STATUS.md).
