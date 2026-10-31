# Coworkers

## Background runs

The plugin contributes an infrastructure workflow for unattended coworker
tasks. Each task uses the coworker's registered workspace repository and
checks out its `coworkers/<handle>` home branch before running. Tasks for one
coworker are serialized, and an agent step waits while that coworker's main
chat has a turn in flight. Results are posted back to the main chat as a
background-run card with the agent's final Markdown result above its duration
and cost; long results are collapsible. Posting is keyed to the Workflow, so a
retry after partial completion cannot duplicate either a success or failure
card. The card also reports whether workspace changes merged, conflicted, or
were unavailable. Background Git operations use a short timeout so delivery
cannot spend multiple default Git timeout windows finalizing the workspace.
Workspace changes merge into the home branch through
the same retrying merge path as chat turns; conflicts preserve the run branch
and appear in the main chat for resolution. Failed scheduled runs post the same
kind of block, count toward consecutive-failure auto-pause, and close their
infrastructure Jobs so completed attempts do not accumulate.

Background runs use the coworker's capability grants. They never receive the
interactive-only tool surface, and a grant configured for live confirmation
uses the queued approval policy during an unattended run. Queued mutations
appear on that coworker's Approvals tab with their originating run and tool
input. Approving replays the tool in its original run context; rejecting posts
the outcome to the coworker's main chat.

The Schedule tab creates recurring or one-shot tasks on the coworker's
workspace Repository and lists their current state. Owners can pause, resume,
or run a task immediately there. The shared cadence parser enforces a minimum
one-hour recurring interval. Every fire rechecks that the owner still has
write access to the workspace Repository; a missing grant auto-pauses the
task. Coworkers with the `schedule.manage_self` grant can manage only their own
schedules through `manage_coworker_schedule`; the grant requires confirmation
by default. Coworker schedules do not use PR pile-up or PR auto-approval
policies, and their results are posted to the coworker's main chat. Schedules
default to `after_run: wake`: after the collapsed result card is posted, an
idle-boundary system message starts a normal coworker chat turn with the run
summary, ID, duration, cost, schedule name, and original instructions. The
coworker follows up in its own voice with its normal chat grants and approval
policies, without repeating the card. Because this is an unattended system
turn, interactive owner questions use the queued-message behavior. If another
turn is active, the follow-up waits in the chat queue, and a run can enqueue at
most one wake. Choose `after_run: quiet` for card-only delivery. A follow-up
never fires another scheduled run.

Coworkers is an experimental, instance-local capability for persistent named
agents. It is disabled by default and requires beta mode before an administrator
can enable it.

The initial foundation stores user-owned coworker identities, globally unique
handles, model preferences, workspace remotes, appearance, explicit capability
grants, and main or side chat links. Existing chats remain Syrus chats unless a
coworker chat link explicitly assigns them to a coworker.

Coworker creation validates and tests the GitHub remote before creating any
records. It registers a previously unknown remote with polling and PR
automations disabled, then seeds an isolated `coworkers/<handle>` home branch.
Existing repository registrations are reused without changing their settings.
The coworker's owner receives write membership when a shared registration is
reused, so workspace Jobs remain authorized for every coworker owner.
The remote's default branch is never modified.

Planner and ordinary Syrus chats can use `propose_coworker` to stage the same
fields as the creation form, including About text and requested grants. The
tool runs the handle, branch, model, grant, and remote checks without creating
records or branches, then shows a pending-action confirmation. Confirmation
rechecks the proposal and passes exactly the displayed fields to the normal
creation service; rejection or withdrawal creates nothing. Coworker chats do
not receive this tool. Adding capabilities to an existing coworker uses the
separate `propose_coworker_grants` pending action; grants are unchanged until
the owner confirms that escalation.

The complete owner-facing coworker tool inventory is `list_coworkers`,
`read_coworker`, `propose_coworker`, and `propose_coworker_grants`. The list
and read tools are read-only and strictly owner-scoped; they accept bounded
discovery filters and an ID or handle respectively. Grant proposals likewise
accept either owner-scoped identifier. These deferred tools are available to
planner and ordinary Syrus chats, never to coworker chats.

The coworker-facing inventory is `message_coworker`, `reply_in_chat_thread`,
`manage_coworker_schedule`, `spawn_coworker_chat`, and the bounded `write_coworker_file`,
`edit_coworker_file`, `move_coworker_file`, and `delete_coworker_file` tools.
Those essential tools remain governed by the coworker's grants and workspace
boundary; coworkers do not receive owner control-plane tools.

Grant policy is enforced for every gated call, including read-only core tools
and plugin-defined tools. `auto` runs immediately; `confirm` creates an
in-chat approval during an interactive turn and joins the approval inbox for
an unattended run; `queue` always joins the approval inbox. Confirming replays
the stored tool name and arguments exactly once through the owning provider.
Tools explicitly classified as `ungated` bypass this policy because they stay
within the coworker's workspace or current chat, expose no additional owner
data, and incur no external cost. The workspace file tools, read-only memory
tools, `reply_in_chat_thread`, and the in-turn question/suggestion helpers use
that classification. `message_coworker` remains gated by `coworker.message`
and defaults to confirmation.

`spawn_coworker_chat(prompt, handle?, title?)` creates only a side chat of the
calling coworker. It cannot create a Syrus chat or select another coworker.
The `coworker.spawn_chat` grant defaults to confirmation, and unattended
background runs convert that policy to the approvals queue. Every request is
therefore represented by the standard coworker pending action. The capability
cannot be configured for automatic execution. The default limits are three requests
per turn or background run and ten per calendar day across all of that
coworker's chats. Owners can set positive `max_spawns_per_run` and
`max_spawns_per_day` grant constraints. Pending requests reserve capacity so a
burst cannot bypass either limit. The spawned chat inherits the coworker's
identity, grants, tool surface, model configuration, and per-chat workspace
branch through its normal `Coworkers::Chat` side-chat link.

`reply_in_chat_thread` is an ungated exception to grant approval: it needs no
per-reply confirmation when the coworker's owner opened
the bridge thread and both the coworker's chat and an ordinary, non-coworker
chat belonging to that owner are its members. It can only reply to that
existing thread; it cannot open a thread or target an arbitrary chat. The
bridge hop limit and automatic closure still apply. A coworker must call the
tool to deliver its answer; plain text left in the coworker's own chat is not
relayed.

Coworker chats use a separate, deny-by-default MCP surface. Administrator
ownership does not add administrator or repair tools. Every core tool on the
surface names the coworker grant required to advertise it, and interactive
question/suggestion tools are present only while handling an owner-authored
turn. Those two helpers run immediately even when the `chat.message_owner`
grant otherwise requires confirmation: asking within the active turn or
putting a hint in its composer is not an outbound message to an absent owner.
Plugin chat tools are excluded unless their tool set and definitions
explicitly opt into coworker use. The Agent Memory plugin opts in only its
read, search, and list tools, without requiring a grant. Those tools expose
the owner's user/global, repository, and instance memories plus published
memories from every repository the owner can access. Team-scoped memories,
another user's private memory, and all memory mutation or publishing tools
remain unavailable. Shared-chat reads are restricted to the
coworker's own chats and chats explicitly shared with that coworker, even
when its owner is an administrator.

The MySQL DB Browser plugin declares the scoped `mysql.read` capability. An
owner can grant one agentic-access-enabled MySQL connection; the coworker then
receives connection discovery, schema inspection, and query tools for only
that connection. Queries are always read-only for coworkers, including on a
connection whose operator UI allows writes. For production investigations,
`browser_error_events` answers browser-failure questions,
`backend_exception_events` records backend exceptions, and
`performance_log_events` contains backend timing diagnostics.

The `syrus.propose_job` grant exposes both `propose_job` and
`propose_epic_with_jobs`. They create the same pending proposal cards as an
ordinary Syrus Chat, retain the originating coworker as audit provenance, and
show that coworker's name and handle on the proposal card. They still require
an operator to confirm before any Job or Epic exists. Proposal
placement and repository-write checks are unchanged: every child declares
explicit planned execution capabilities, and a coworker cannot target a
repository its owner cannot write. A missing grant keeps the tools absent;
an invalid target is returned as an authorization or validation error.

Grant approval policies are enforced at invocation: `auto` executes directly,
while `confirm` and `queue` create the standard pending-action card for owner
approval. The card and the coworker's Approvals inbox identify the coworker,
show the actual tool and readable redacted arguments, and collapse long values
behind an expansion control. Revoking either workspace grant also changes the
provider-native tool boundary. Claude can deny file and shell tools
independently; providers without that separation fail closed rather than
starting with permissions they cannot enforce.

Owners edit these grants on the coworker's Capabilities tab. Every registered
capability appears with its description, unlocked tools, scope (when the grant
owner declares one), and an `auto`, `confirm`, `queue`, or `off`
policy. Moving to a more permissive policy, or turning on a new capability,
requires a separate confirmation; reductions apply directly. File grants can
record paths such as `SOUL.md` and `AGENTS.md` that always require confirmation.
Integration tiles are visible but disabled until those integrations ship.
Capabilities that affect anything outside the workspace default to `confirm`
or `queue`; messaging the owner defaults to `confirm`. Removing a protected
file path is also an escalation and requires confirmation.

Operator chat exposes the same aggregated catalog through
`list_coworker_grants`. `propose_coworker_grants` accepts one or more desired
capability, policy, and optional scope changes; `off` removes a grant and lower
policies reduce it. The proposal remains inert until its pending-action card is
confirmed. Coworker prompts list held and missing catalog grants with their
unlocked tool names so a coworker can request the specific missing grant.

Each coworker chat runs in its own disposable checkout and immutable-id branch,
`coworkers/chat/<coworker-id>-<chat-id>`, cut from the coworker's
`coworkers/<handle>` home branch. At turn end Syrus commits with the coworker's
git identity, pushes the chat branch, and merges it into the home branch. Clean
and file-disjoint changes merge automatically; append-oriented files under
`memory/` use Git's union merge driver. A conflict keeps both refs and the
conflicted local checkout intact and posts the affected file links into the
chat. A missing local checkout is re-cloned from the canonical remote.

Changing a coworker's handle moves its home branch in the same locked
operation. Deleting a coworker preserves the home branch under
`coworkers/archived/<handle>-<date>` (with a numeric suffix when that name is
already occupied) and releases the handle for reuse. Syrus guards coworker
pushes so an individual coworker can target only its own home branch, immutable
chat branches, and archive branches. This keeps an agent from straying into
unrelated refs; repository permissions, not this convenience guard, remain the
security boundary.

`SOUL.md`, `AGENTS.md`, and
`USER.md`, today's and yesterday's daily memory, participant and sender people
files, and the attached repository's memory file are loaded into every fresh
or resumed turn. Each file is capped at 64 KiB and the combined content at
128 KiB, with visible truncation markers. Older daily files and memory banks
remain available on demand through the workspace file tools under the same
per-file cap. On every turn the system prompt tells coworkers to save durable
facts, preferences, decisions, commitments, opinions, lessons, and project
context before replying, without asking permission. It directs updates to the
daily, people, repository, and memory-bank files or to `USER.md`, `SOUL.md`,
and `AGENTS.md` as appropriate; entries stay short, factual, append-oriented,
and free of credentials, tokens, and secrets. A coworker reports a saved update
only after the workspace tool succeeds and plainly reports anything it could
not save. Every new coworker starts its main chat itself. Without About
text, its kickoff asks the owner about its role, personality, working
preferences, and boundaries. With About text, the identity is already written
to `SOUL.md`; its distinct kickoff tells the coworker to greet the owner in its
own voice, briefly explain its understanding of the role, and ask only a few
concrete questions about anything unclear or missing. If nothing needs
clarification, it asks what to work on first. The initial identity files and
kickoff include the coworker's configured name and the owner's display name,
so it does not ask for either name. The agent process receives neither the
ordinary chat CLI invocation token nor a Git askpass token, so the owner's
repository credentials and integration credentials are not exposed to its
shell. Newly seeded `AGENTS.md` files repeat the memory habit, while existing
coworker workspaces retain their previously seeded copy and receive the current
expectation from the system prompt.

Coworker chats are modeless: they do not show the Planning/Coding selector.
Every turn receives create/replace, exact-edit,
move, and delete tools rooted at that coworker's current checkout. Absolute
paths, traversal, symbolic links, `.git`, attached product repositories, and
other coworker workspaces are outside that boundary. The tools only mutate the
working tree; branch commits, merges, pushes, and conflict recovery remain part
of the orchestrated coworker branch lifecycle.

When enabled, the plugin adds a Coworkers page and a badge counting pending
approvals across the signed-in owner's coworkers. Syrus is
pinned first as the built-in engineer; custom coworkers show their configured
color and avatar. The creation form collects the workspace remote, appearance,
model, grants, and optional About text. Uploaded avatars are size-limited and
resized before Active Storage saves them. Coworker chats are grouped separately
in the chat sidebar, and assistant messages use the coworker's avatar and color.
Coworker chats carry a named badge in global search, chat search, and the
agent-facing chat search tool. The shared chat filter offers each of the
current user's coworkers plus Syrus, where Syrus means a chat without a
coworker link.

Chat owners can share a chat read-only with one of their own coworkers from
the normal share dialog. A coworker with the `chats.read_shared` grant can
list, search, and read its own chats plus those shares; revoking a share
removes access immediately. Coworkers are never offered the arbitrary
`send_chat_message` tool.

Background Jobs attributed to a coworker are private to that coworker's owner,
even when the workspace repository is shared. Other repository members and
repository administrators cannot list, search, count, or read those Jobs.
Instance administrators retain their normal instance-wide visibility. This
restriction is registered before the coworker background-Job kind can be
introduced, so future scheduling cannot accidentally inherit repository-wide
visibility.

Coworkers with the `coworker.message` grant can use
`message_coworker(handle, text)` to contact another active coworker owned by
the same user. Delivery is queued on the chat queue. The sender's main chat
records an outgoing block, while the receiver's main chat gets a
"message from @handle" block that waits behind any turn already in flight.
The chat UI presents these blocks with the other coworker's name, avatar, and
accent color; incoming message bodies omit the stored transport prefix. If the
other coworker was deleted, the saved handle remains visible in a neutral style.
Paused and archived coworkers, Syrus, the sender itself, and handles outside
the owner's coworker list are refused. Deliveries carry their origin turn and
hop count; a chain cannot continue beyond three hops. Each pair of coworkers
can queue at most ten messages in a ten-minute window, regardless of direction.
Hop-limit refusals and rate-limited attempts are recorded in the sender's main
chat and listed in the sender's Activity tab.

An incoming coworker message starts a turn whose final assistant text is
automatically sent back to the coworker who wrote it. The prompt identifies
that coworker, explains that delivery is automatic, and reports how many
exchanges remain. The reply uses the same active-coworker checks, pair rate
limit, origin turn, and three-hop cap as `message_coworker`; a refusal is
recorded in the replier's main chat. A coworker can end the exchange without
sending or displaying an answer by replying with only `NO_REPLY`.

Chat owners can also add their coworkers to a chat's agent roster from the
coworker page or by choosing an autocomplete result marked "Add to chat."
Rostered coworkers become addressable by every participant in that chat and
an exact structured mention starts a coworker turn using the chat owner's
settings. A coworker is also implicitly addressable in its own main and side
chats without a roster entry. Coworkers that are neither the chat's implicit
coworker nor on its roster remain plain text and do not start a turn. Rostered
coworkers can be removed by the chat owner, and coworkers owned by anyone else
cannot be added. The roster is shown beside the chat heading. Coworker turns
share the chat's serialization lane, so two turns in one chat do not run at the
same time.

Profile pages render `SOUL.md` read-only. The Memory tab reads the coworker's
home branch through the cached repository-content providers and presents daily,
people, repository, and bank Markdown files without any editing controls. It
supports full-text search across paths and contents, links to the owner's Syrus
memories, distinguishes an empty memory tree from an unreachable remote, and
shows recent daily files first. Provider-truncated or exceptionally large trees
return their available files with a partial-results notice; searches also warn
when capped file contents mean the result set cannot be complete. The Activity
tab reports total uncapped spend, sent and received coworker-message traffic for
the last 30 days, plus recent refused and rate-limited deliveries.
The Schedule tab uses the shared scheduled-task cadence and lifecycle controls.
Capabilities remain a coming-later placeholder where its full surface has not
shipped yet.

The Workspace tab is a read-only view of the coworker's home branch through
the same cached repository-content providers. It shows the remote and branch,
the file tree with plain-text or Markdown previews, available commit history,
and chat branches with unresolved merge conflicts. Partial trees and capped
files are marked explicitly. The only remote action is **Test push access**,
which creates and immediately deletes a randomized throwaway ref beneath
`coworkers/`; file edits and arbitrary pushes are not exposed in the UI.

Coworker creation records a durable provisioning attempt before it seeds the
home branch. A failed database transaction either removes the exact seeded ref
immediately or reports cleanup as pending and retries on the cleanup queue.
Cleanup rechecks the recorded remote, handle, ownership, and seeded commit SHA;
it never scans the remote for branches to remove. The Coworkers page lists
non-completed attempts and lets the owner retry pending cleanup or acknowledge
a terminal safety refusal. Persisted and displayed errors are credential-redacted.

## Process confinement

Custom-coworker provider turns require the enabled and configured Container
Execution plugin. They fail closed when no container backend is available;
Syrus never silently runs them on the worker. The per-turn container can write
only the coworker's chat checkout and that chat/provider's agent home, while
the existing turn finalizer commits and merges checkout changes into the home
branch. Temporary files and the container itself are discarded after the turn.

## Read-only repository access

Coworkers start without product-code access. Owners can grant `code.read` for
an explicit set of accessible repositories or for all repositories the owner
can read. Its only policy is `auto`: once the owner confirms the grant and its
scope, the coworker can attach or detach product repositories in chats, list
files, read capped and secret-redacted files, search code, and inspect pull
request or Job diffs. Background runs receive the navigation and diff tools;
attaching and detaching checkouts remain interactive-chat actions.

Attached product checkouts are recursively stripped of write bits, including
Git metadata. The `workspace.files` and `workspace.shell` grants continue to
apply only to the coworker's own workspace repository, which remains the
chat's primary repository regardless of product attachment order. Product
repositories remain secondary attachments for code-reading context and never
become persistence targets. This blocks ordinary native-shell writes and Git
persistence. Until the agent sandbox supplies a true read-only mount, a hostile
process running as the checkout owner could restore its own mode bits; that
remaining gap belongs to sandbox enforcement.
