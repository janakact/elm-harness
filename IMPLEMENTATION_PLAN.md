# v0.3 implementation

The v0.3 document supersedes the previous Rust-host plan. Elm owns the canonical backend model, agent state machine, context construction, prompt composition, tool definitions/validation, approval decisions, migrations and projections. Node performs transport, secret injection, physical storage, sandboxed tool execution and terminal I/O. The browser has only local view/input state and receives projections. Rust is removed.

Implemented:

- Elm backend worker and versioned action/event ports; browser and terminal Elm clients.
- Canonical immutable parent graph, forked threads, explicit captured deliveries and durable inboxes.
- OpenRouter streaming with fragmented tool-call assembly in Elm, correlation IDs, cancellation, sequential tool continuation and a configurable concurrency limit (default four).
- Exactly read/write/bash schemas, argument checks, audited approvals, bounded output/time, containment and sensitive-path restrictions. Linux bash uses Bubblewrap, fails closed if unavailable, hides the root .env and credential directories, has no network, and removes secrets from its environment. Mutating tools are serialized.
- Elm prompt v3 with SYSTEM.md replacement, APPEND_SYSTEM.md additions and AGENTS.md project context. Each model call records effective prompt provenance as an activity.
- Explicit summary nodes for context compaction, a context-size guard and a 25-tool-turn budget.
- Separate core/user schemas, additive user migration, invalid-version rejection, graph checks, atomic serialized saves/backups and interrupted-tool recovery without automatic replay.
- Fixed viewport browser shell with scrolling chat, anchored composer, responsive sidebar, graph/detail panel, approvals, model settings, run/stop, branching and reference delivery.
- Elm Markdown/math tokenization, safe Markdown, tables, highlighted copyable code, local KaTeX leaf adapter, and terminal LaTeX fallback.
- Full-screen Elm TUI with responsive chat/history panes, fixed editable composer, message inspection, scrolling, safe paste, permission review, keyboard shortcuts, and backend auto-start/cleanup. Terminal host handles raw keys, resize, ANSI writes and transport; Elm owns all interaction and layout semantics.

Verification: npm test covers the actual compiled Elm worker, complete tool loop, approvals, cancellation, inbox recovery, namespace migration, concurrent scheduling, containment and atomic storage. A browser fixture checks Markdown/math/code and fixed viewport at desktop/mobile sizes. A live DeepSeek V4 Flash request read package.json through the real host and completed its answer.

Scope: no fourth tool, external CLI runner, distributed hosting or dynamic plugin loading. Shell execution requires Linux Bubblewrap. Parallel mutations are serialized rather than giving agents unrestricted concurrent checkout writes. Explicit compaction summaries are user-supplied, preserving every original node.
