# Chat

The browser bootstrap payload carries user-level chat capabilities such as
speech-to-text availability and the Coding/Local Mode feature gates. Individual
chat polling responses contain only session-specific state, so these static
capabilities are not recomputed and retransmitted on every poll.

Syrus Chat supports Claude, Codex, and enabled plugin-provided providers. A new
chat pins a concrete provider from the user's chat-provider setting, then the
default agent provider, then Claude. The new-chat repository selector prefers
the most recently used accessible repository, then the first active accessible
repository; operators may explicitly choose no repository. Existing chats do
not change provider when defaults change. If every provider is unavailable,
the transcript warns that provider capacity is exhausted instead of silently
switching the conversation.

## People, mentions, and group chats

Typing `@` suggests chat participants, rostered agents, the owner's available
coworkers, and Syrus. Handles are instance-wide, lowercase, and may contain
letters, numbers, underscores, or hyphens. In group chats, turns run only when
Syrus or a coworker is mentioned; human participants otherwise converse
without waking an agent. Shared read-only chats do not let recipients post.

**Chat about this** starts a chat from supported Job, Workflow, Run, review,
and admin surfaces with the relevant context attached. Slash commands expose
the supported chat and Coding Mode shortcuts in the composer.

## Pending actions and recovery tools

Actions that require confirmation remain inert until an operator confirms
them. Rejecting or withdrawing one does not execute it. The agent may call
`withdraw_pending_action` for an erroneous pending action; grouped actions are
decided together. Plural-id repair tools create one grouped confirmation and
preflight every target.

`retry_job` supports `auto`, `failed_step`, `implementation`, and
`refresh_base`. `failed_step` retains the immutable source snapshot;
`implementation` is an explicit fresh implementation attempt; and
`refresh_base` requires a reason and reapplies a published checkpoint to the
current effective base. `cancel_stale_work` accepts up to 100 distinct
`targets`, each with a `job_id` and optional Workflow and Run selections.

`approve_job` is blocked while mutating implementation, feedback, repair,
landing, deployment, investigation, or unknown/plugin runtime work is active.
Non-mutating rebase and visual-review work does not by itself block approval.

## Reading and organizing chats

Chat-reading MCP tools list and read accessible chats and messages. Pinning and
bookmarking keep important chats and messages available in their corresponding
sidebar views. Chat access always respects participation and explicit shares.

## Scheduling

Use `schedule_wakeup` for one future wakeup and `schedule_recurring` for a
repeated schedule. A recurring schedule is not a chain of one-shot wakeups.

## Repository files and Coding Mode workspaces

With a repository attached, the Files tab is read-only outside Coding Mode.
Coding Mode prepares a writable checkout and exposes its status in the
environment snapshot. To take over an existing Job, attach it to the chat,
enter Coding Mode, inspect its current branch and instructions, make and test
the changes, then call `submit_coding_changes`. Do not push directly from
Coding Mode. Accepted submissions are committed and handed to a workflow; the
next submission stacks on the prior handoff. `reset_workspace` is the explicit
fresh-default-branch escape hatch and requires confirmation before discarding
work.

`!` runs a one-shot shell command in Coding or Local Mode. Commands are scoped
to the workspace, stream their output into chat, and may be cancelled.

## Media attachments

Chats accept supported images, audio, video, and documents. Attachments remain
associated with the message and are made available to capable providers and
proposal tools; unsupported or oversized media is rejected explicitly.

## Proposals and updates

Proposal tools accept `media`, `for_active_goal`, `route_to_backlog`,
`investigation`, `provider`, `priority`, and `planned_execution` where the
proposal type supports them. Planned execution requirements must be explicit,
not inferred from prose. `update_job` only edits fields that remain mutable in
the Job's current state.

Dependencies may use `satisfaction_mode` to distinguish the supported
completion condition. Same-turn proposal dependencies use proposal slugs;
existing Jobs use their Job IDs.

## Cross-chat coordination

`spawn_chats` creates bounded child chats for delegated work.
`send_chat_message` sends a message to an accessible target chat and can open a
thread there. These tools do not bypass chat access or mention gating.

Implementation details live in
[`docs/engineering/architecture/chat.md`](../../docs/engineering/architecture/chat.md).
