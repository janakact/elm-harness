# Remaining work against design v0.3

This is a source review, not a claim that every acceptance criterion is complete.

**12 November scope update:** [PLUGIN_RUNNER_DESIGN.md](PLUGIN_RUNNER_DESIGN.md) recommends typed Elm state/view plugins, a provider/runner boundary, and Codex/Claude process adapters. It includes the system architecture SVG. The user's new runner/backend request supersedes the older v0.3 deferral; read-only Codex/Claude jobs are now implemented; write workspaces and delegated task workflows remain planned.

## Current baseline

The project has the Elm backend worker and Elm browser/TUI clients, streamed OpenRouter turns, read/write/bash, audited approvals, per-chat workspace roots and prompt sources, a canonical parent graph, independent chats and forks, explicit captured cross-chat deliveries, durable inboxes, concurrency limits, versioned core/user persistence, recovery tests, and browser Markdown/code/math rendering. The browser focuses the composer on chat navigation, keeps drafts separate, and offers a read-only JSON state explorer.

Priority 1's first increment is implemented: typed persisted per-chat allow/ask/deny policies, filtered schemas and host enforcement, a configurable estimated input budget, persisted provider-reported usage/cost, and model-assisted compaction with an editable preview and explicit source-checked acceptance. Browser and TUI expose the same actions. Original graph nodes remain immutable; failed/cancelled summaries do not change effective context. Tool approvals/results are scoped to their owning chat/run, including reused provider call IDs. Fork/reference controls have browser coverage, including empty notes and unfinished-tool branches.

## Next implementation priorities

| Priority | Design requirement | Present behavior | Next concrete increment |
| --- | --- | --- | --- |
| 1 | Per-thread permissions and context budgets (§6.4, milestone 3) | First increment complete: persisted policies, input-budget guard, per-request usage/cost, context meter and reviewed model-assisted compaction. The 25-tool-round guard remains. | Model-specific tokenizer/context metadata could improve the local estimate. Provider usage/cost can be absent and is shown as unknown/partial. No automatic unreviewed compaction. |
| 2 | Isolated workspaces, diff comparison and controlled merging (§5.4, milestone 3) | Chats can use different existing directories. All mutating tools are serialized. Worktrees are not created or merged by the harness. | Create a Git worktree for a coding branch, capture changed paths/diffs, and add review/apply/merge actions with recorded decisions. |
| 3 | Delegation and request/reply/join workflows (milestone 3) | Manual forks and explicit sends work. There is no typed task lifecycle, waiting-cycle detection, join, or automatic report-to-parent operation. | Add task/request identities, status and timeout transitions, report-result actions and a parent task view. Keep the model-facing tool set at three unless the design is explicitly changed. |
| 4 | Stable shared view and public extension APIs (§7.1, §7.3, §9) | Browser/TUI now use a public projection, typed run statuses and shared plugin views. The existing user plugin receives typed committed events and requests typed core actions. | First small public API and plugin example are implemented. Add more actions/slots only as actual plugins require them; wider extension APIs remain incomplete. |
| 5 | Rich renderer completeness and performance (§7.2) | Markdown/math/code work for tested cases. The TUI mostly preserves readable Markdown/LaTeX source; parsing/rendering is not cached by node revision. | Test mixed math inside tables/lists, incomplete streaming delimiters and large outputs; cache rich documents and improve terminal Markdown styling. |

The requested current-chat-only graph is retained. Advanced minimaps, semantic search, other native model providers and distributed hosting remain deferred. The expanded scope now includes read-only external CLI jobs.

## Cleanup completed; next task

The native foundation cleanup is implemented: provider-neutral context/OpenRouter codec separation, a dedicated public client projection, typed run statuses, save acknowledgment before model/tool effects, correlated action results, and a small state/view plugin with independent recovery. The architecture SVG is now a high-level overview. See [the design and source map](PLUGIN_RUNNER_DESIGN.md).

Read-only external jobs are implemented: Codex/Claude process adapters, typed Elm lifecycle and event normalization, session/attempt ownership, shared concurrency, durable launches, read-only process mounts, output/time limits, cancellation/recovery, explicit result reporting, usage scopes, capability probes and browser/TUI controls. Automated tests use fake processes; installed CLI help/version checks passed, but paid authenticated model smoke checks have not been run.

Next: isolated Git worktrees and diff review/apply actions, followed by core-owned delegated task/report/join workflows. Additional native providers, opaque domain ID types, and a generalized plugin framework remain future work. Current conversation forks still share their source workspace.
