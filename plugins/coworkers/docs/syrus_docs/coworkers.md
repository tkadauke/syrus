# Coworkers

## Mentions in ordinary chats

Adding a coworker to an ordinary chat makes that coworker addressable without
changing the chat's repository or workspace. Mentioning a rostered coworker
delegates the message to a reusable hidden coworker-owned working session; the
ordinary chat never becomes a coworker workspace. The coworker's final reply is
delivered back as a colored, attributed bubble with a link to that working
session. If several coworkers are mentioned in one message, only the first
rostered mention answers in this version. Removing the coworker revokes access
to the source chat.

## Automated review contributions

When Coworkers is enabled and healthy, it contributes an opaque reviewer
target, protected review context, post-verdict memory persistence, and the
provider-rule, evidence, audit, and settings UI for coworker reviewers. Core
stores only the target reference, safe display/context snapshots, and an
opaque persistence receipt. Disabling the plugin removes live resolution and
UI contributions without deleting historical review evidence; retained
snapshots continue to render through the generic fallback. Restricted prompt
text is never included in the Job payload, is bounded before execution, and is
framed as untrusted evidence in the reviewer prompt. Coworker review-memory
tools are exposed only when core grants the run's `submit_coworker_review`
workflow capability.

Workspace pushes that fail because of a transient remote or network problem are retried during the turn and then by a background job. Until saving succeeds, Syrus preserves the local checkout and shows one updating warning in the chat and on the coworker's Workspace tab. The owner can use **Retry save now** there; permanent authorization, protected-ref, and conflict failures require attention and are not retried automatically.

Coworker tool dispatch is enforced by the unified permission evaluator. Capability
descriptors supply the recommended defaults, while operator rules and temporary
leases can narrow or extend those defaults within each descriptor's ceiling.
Existing coworker grants are translated idempotently into exact-agent
`PermissionRule` rows with the legacy row ID in provenance. Any preserved old
rows remain immutable audit and rollback evidence, but creation, editing, discovery,
prompts, execution, and surrender read only canonical rules and leases.
The cutover never replaces an active canonical rule: it reports that row as a
conflict, logs per-row parity or translation errors, and continues with other
rows. Rollback revokes only rules carrying migration provenance.

## Default policies for coworker tools

A coworker tool defaults to `allow` only when every classified invocation is low
risk and confined to local reads, isolated workspace writes, or a declared benign
internal write: bounded read-only repository context (`attach_repository`,
`detach_repository`, within the owner's accessible repositories and the grant's
repository scope), owner-directed interaction, reducing the coworker's own
authority, or creating a non-executing draft proposal (`propose_job`,
`propose_epic_with_jobs`) that an operator must still confirm. Cross-chat reads,
operational telemetry and logs, database and Kubernetes access, credential use,
messaging other coworkers, side-chat creation, schedules, and any consequential,
privilege-changing, destructive, or irreversible effect stay `ask` or `deny`.
Explicit operator rules, denies, and ceilings always override these defaults, and
an invocation whose own classification is not benign is downgraded to `ask`.
Registration fails when a coworker descriptor defaults to `allow` without meeting
this rule, and `Coworkers::ToolDefaultPolicyReport` fails when an advertised grant
default disagrees with the effective descriptor default. Run
`bin/rails syrus:coworker_tool_defaults` to print every coworker tool grouped into
allow, ask, and deny with the reason.

## Background jobs

The Activity tab presents one entry per coworker Job, links its canonical Job
reference and title to Job details, and summarizes the requested goal, outcome,
timing, spend, and tool usage. Expand a Job's attempts to inspect its Workflows
and Runs. Filters cover outcome, date, schedule or trigger source, failures,
and title or goal text; filter state remains in the URL.

When the optional Calendar plugin is enabled, Coworkers contributes planned
occurrences for schedules attached to a coworker. These occurrences show the
coworker's identity and avatar, schedule and main-chat destinations,
`after_run` policy, system-schedule identity, and the resulting background
Workflow's actual start, finish, duration, and outcome. Work waiting for the
coworker's main chat or serialization lock is shown as waiting or delayed,
rather than as though it started at the planned time. Scheduled Tasks excludes
this same subset, so an occurrence appears only once. Disabling Calendar does
not disable Coworkers or remove its schedules.

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
Workspace changes merge into the home branch through the same retrying merge
path as chat turns; conflicts preserve the run branch and appear in the main
chat for resolution. Failed scheduled runs post the same kind of block, count
toward consecutive-failure auto-pause, and close their infrastructure Jobs so
completed attempts do not accumulate.

## Protected repository-review memory

Named coworker review Runs, including coworkers selected for configured
adversarial and security review rounds, use the normal read-only workflow checkout for the
repository under review and a separate checkout of that coworker's home branch
for durable learning. The reviewer receives only its identity, applicable
repository criteria, and explicitly selected published repository-scoped
memories for the Run. Normal evidence stores hashes, revisions, and byte counts; the exact
selected text is encrypted and is available only through the audited
owner/admin restricted-evidence endpoint.

The reviewer can update only `memory/*.md` through its dedicated memory tool.
Submitting a verdict also writes a deterministic `reviews/journal/evidence-<id>.md`
entry with the reviewed revision and evidence reference, then rebases and
pushes the isolated checkout. The Run cannot succeed until that push succeeds.
Repeated submission for the same Run reuses its journal and verdict rather
than duplicating either. Failed persistence retains the isolated checkout and
reports `coworker_memory_persistence_failed` for recovery. Tombstoning removes
the validated run-owned checkout, encrypted text, and checkout pointer while
retaining the safe manifest and lineage. Cleanup refuses unrelated or symlinked
paths. The central retention-policy registry applies that tombstone after 30
days by default, aligned with detailed Run evidence retention.

Adversarial and security review keep their existing criteria, project scope,
rounds, structured verdict tool, repair loop, and narrow reviewer role. A
provider rule may replace only the reviewer identity with one coworker or a
panel. Every new Run resolves that coworker's current repository permission
again; pausing or revoking a coworker prevents a retry or later round but does
not interrupt a provider process that has already started. These automated
verdicts are review evidence only and never count as a human Job approval.

Background runs use the same unified permission policy as interactive turns.
They never receive the interactive-only tool surface. Operations whose effective
policy is `ask`
appear on that coworker's Approvals tab with their originating run and tool
input. Approval issues one fingerprint-bound invocation; atomic claiming prevents
duplicate dispatch in its original run context. Rejecting posts
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

Every active coworker also has one undeletable **System** schedule named
Journaling. Syrus creates it during provisioning and reconciles it periodically
if it is missing or damaged. It runs shortly after midnight in the owner's
approval-delivery time zone (UTC when none is configured), processing the local
day that just ended. Owners may pause or resume it and change its run time; its
prompt, kind, identity, and delivery behavior are owned by Syrus. A paused
journaling schedule remains visibly paused on the coworker page.

Journaling does not invoke an agent on dormant days. It records the day as
`skipped: dormant`, advances the last-journaled date, and creates no Job, chat
card, wake turn, or unread state. Active and missed days are processed within a
seven-day catch-up bound. Older dates are recorded as
`skipped: out_of_catch_up_window` so gaps stay visible. A failed nightly fire
is retried at most once per hour and stops after three attempts until the next
daily window. System schedules stay scheduled rather than being auto-paused. Fire errors
are retained with their exception reason, and journaling is called out as
overdue only when it is more than one day behind.

The Schedule tab presents one latest-result summary per schedule rather than
inline result history. It links the exact scheduled Job when one exists and
offers **View all runs**, which opens the Jobs dashboard filtered by the
schedule's `scheduled_task_id`. A skipped Journaling occurrence explicitly
states that no Job was needed; a schedule with no result is shown as never run.

The periodically sampled `syrus_coworkers_journaling_unhealthy_total` metric counts active coworkers
older than 25 hours without a fire or recorded dormant skip inside that window.
Successful journaling is also completely
silent: the only output is the persisted workspace update and
`memory/diary/YYYY-MM-DD.md`. Failures post the normal failure card and wake the
main chat once for that date.

The journal organizes durable daily notes into the normal people, repository,
and memory-bank files and writes a first-person diary. Memory is never deleted.
An obsolete entry uses `~~original text~~ (superseded YYYY-MM-DD by <reference>:
<reason>)`; it remains readable in Memory while standing prompt context omits
the superseded line. Diary entries appear newest first in the read-only Memory
tab.

Coworkers is an experimental, instance-local capability for persistent named
agents. It is disabled by default and requires beta mode before an administrator
can enable it.

The initial foundation stores user-owned coworker identities, globally unique
handles, model preferences, workspace remotes, appearance, explicit capability
grants, and main or side chat links. Existing chats remain Syrus chats unless a
coworker chat link explicitly assigns them to a coworker.

The Chat tab keeps the main chat pinned above a paginated side-chat index. Its
shared FilterBar searches titles and indexed message contents and filters by
active or archived state, unread state, active work, creation date, and last
activity. The URL preserves filters and sorting. Results include bounded
message previews or highlighted search excerpts, match counts, activity and
unread indicators, and standard rename, archive or restore, and delete actions.
Hidden mention working sessions are excluded. New side chats receive a normal
generated title after their first substantive message, while explicit renames
remain authoritative.

Coworker creation validates and tests the GitHub remote before creating any
records. It registers a previously unknown remote with polling and PR
automations disabled, then seeds an isolated `coworkers/<handle>` home branch.
Existing repository registrations are reused without changing their settings.
The coworker's owner receives write membership when a shared registration is
reused, so workspace Jobs remain authorized for every coworker owner.
Dedicated coworker workspace registrations created during provisioning are
omitted from that owner's general Repositories list
while the plugin is enabled. A normal repository reused by a coworker stays in
the list. Dedicated workspaces remain available to the coworker, its chats and
schedules, and direct authorized repository requests.
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
`manage_coworker_schedule`, `spawn_coworker_chat`, `spawn_syrus_chat`, and the bounded `write_coworker_file`,
`edit_coworker_file`, `move_coworker_file`, and `delete_coworker_file` tools.
Those essential tools remain governed by the coworker's grants and workspace
boundary; coworkers do not receive owner control-plane tools.

Unified permission policy is enforced for every gated call, including read-only
core tools and plugin-defined tools. `allow` runs immediately, `ask` creates an
approval request, and `deny` fails closed. Confirming authorizes the stored tool
name and fingerprinted arguments exactly once through the owning provider; the
evaluator is rerun while the invocation is atomically claimed. A coworker's
rules are its own, separate from chat and from other coworkers, but its
essentials are the same as a chat's: reading Jobs, Epics, docs and the
repositories its grants select, writing private memories, drafting proposals,
asking you questions, and managing its own chat are evaluated and audited but
can never be denied. Coworker-only essentials are `reply_in_chat_thread`,
capability discovery, and permission requests and surrender. The workspace
file tools are allowed by default but stay deniable, because you can protect
paths in the coworker workspace. `message_coworker` remains gated by `coworker.message`
and defaults to confirmation.

Tools marked `approval_effect` still evaluate capability policy and fail on an
explicit deny, but they do not create a generic tool-call approval when their
only mutation is creating the owner's real confirmation card. Job/Epic
proposal tools and both chat-spawn tools use this marker, preventing a second
approval without weakening deny rules.
A plugin tool's marker counts only when the plugin registers the confirmation
card the tool creates as a pending action under the tool's name, as both
chat-spawn tools do; otherwise the tool asks through the generic approval like
any other.

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

Background-run branches are recovery refs only while their work is unmerged.
They are removed after a successful home-branch merge; a bounded daily sweep
removes older merged refs left by transient failures. Conflict and recovery
refs remain until their conflict is resolved. The Workspace tab reports home,
chat, and run branch counts so unexpected growth is visible.
Chat branches remain while their chat exists and are compare-and-deleted when
the chat or coworker is deleted. A branch with unsaved work or an unresolved
conflict is retained as the durable recovery copy.

`spawn_syrus_chat(repository_id, prompt, title?)` is the distinct path for
engineering and planning work. The `syrus.spawn_chat` grant is off until the
owner enables it, defaults to confirmation, and is scoped to selected
repositories (or all repositories the owner can read). Its confirmation is
the action's real approval card, so it bypasses the generic coworker mutation
gate and never asks twice. Approval creates an ordinary owner-owned planning
chat in the normal chat list, records the originating coworker in chat
provenance and the audit log, and opens a cross-chat bridge carrying the
initial message. The coworker reads replies delivered over that bridge and
uses `reply_in_chat_thread` for follow-ups; it gains no access to unrelated
chats. Separate positive `max_spawns_per_run` and `max_spawns_per_day`
constraints default to three and ten.

`reply_in_chat_thread` is an essential exception to grant approval: it needs no
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
an operator to confirm before any Job or Epic exists. Registration is shared
with ordinary chat tools, so a missing permission does not hide these tools;
canonical policy decides whether an invocation runs, asks, or is denied. Proposal
placement and repository-write checks are unchanged: every child declares
explicit planned execution capabilities, and a coworker cannot target a
repository its owner cannot write. An invalid target is returned as an
authorization or validation error.

Coworkers receive the ordinary chat-agent Job lifecycle tools, including
`cancel_job` and `submit_chat_feedback`. Canonical `syrus.jobs` policy decides
whether each invocation runs, asks for confirmation, or is denied; sharing the
tool registration does not bypass its Job-state or authorization checks.
Cancellation requires a reason, and duplicate cancellations may link a
canonical replacement Job in the same repository. The state history records
the coworker, chat, prior and resulting states, reason, time, and replacement.
Jobs with landing or deployment evidence are refused.

Feedback submission uses the same permission policy, Job-state checks, and
operator confirmation as a normal chat submission. Confirmed feedback records
the coworker, originating chat, and provider separately in Job history before
starting the normal feedback workflow. Workflow review verdict tools remain
limited to their corresponding review steps.

Owners may separately grant five repository-scoped autonomy capabilities:
filing a Job, approving it, submitting feedback, cancelling it, and retrying
it. Each capability is off by default and has no effect until a repository is
selected. Except for filing, it applies only to Jobs filed by that same
coworker. Every newly granted capability starts in `shadow` mode. It evaluates
the normal budgets and guardrails but does not execute; the ordinary pending
action continues to the operator. The recorded would-file, would-approve,
would-send-feedback, would-cancel, or would-retry decision includes its evidence
and each guardrail outcome. Ordinary chats cannot use these coworker grants.
Autonomous actions retain the normal state, review, landing, and retry checks
and record the coworker, permission rule, Job, repository, and action in the
audit trail. The Capabilities tab pairs completed shadow decisions with the
operator's later approval or rejection and shows agreement totals and
disagreement cases per action. Switching an action to `enabled` requires
confirmation; switching back to `shadow` takes effect directly.

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

Database, Kubernetes, log, and third-party integration grants are privileged.
They are assignable and advertised only while a live worker reports verified
`confined_coworker` execution and the Credential Store broker authorization
path is enabled. The Capabilities tab explains which prerequisite is missing.
If worker capability or broker health is lost, stored grants remain visible
for audit and easy recovery but disappear from the coworker's runtime tool
context until the gate is healthy again. Credentials stay inside broker
services; grant state, tool metadata, workspaces, mounts, and logs contain only
credential identifiers and redacted lease provenance, never secret material.

Coworkers inherit every ordinary core and enabled-plugin chat tool unless its
registration is admin-only, tied to Coding or Local Mode, tied to a workflow
submission role, or centrally excluded because it has no coherent coworker
semantics. Shared registration preserves the handler, input/output contract,
permission descriptor, resource checks, pending-action behavior, and audit
model. It grants no authority by itself.

Operator chat exposes the same aggregated catalog through
`list_coworker_grants`. `propose_coworker_grants` accepts one or more desired
capability, policy, and optional scope changes; `off` removes a grant and lower
policies reduce it. The proposal remains inert until its pending-action card is
confirmed. Ordinary coworker prompts and tool lists advertise contextually
meaningful tools even when policy will require a request. Deferred discovery
adds `discover_coworker_capabilities`, a read-only,
ungated lookup for eligible but locked capability families. Each result names
the required resource scope, effective policy, and lock reason without granting
authority. Explicit discovery keeps `available`, `requestable`, `prohibited`,
`plugin_disabled`, `resource_unconfigured`, and `unavailable` as separate
states so an absent tool is never presented as an implicit denial or grant.
Known capabilities such as `mysql.read` stay in the catalog when a privileged
grant is missing, the confinement probe is unavailable, no eligible resource is
configured, or the provider plugin is disabled. Every entry also carries a
`blocker`, its `prerequisites`, the `permitted_scope`, and a `next_action`.
When permission is the only blocker the action is a ready `request_permission`
payload (one request per operation, with `scope_choices`). When infrastructure,
a resource, or the plugin is the blocker the action is an `owner_remediation`
that says granting permission alone will not make execution safe. A
`not_authorized` refusal for a blocked tool carries the same state and action,
and each action lists the tools and the discovery query to rerun after
remediation so the original intent can resume.

Each coworker chat runs in its own disposable checkout and immutable-id branch,
`coworkers/chat/<coworker-id>-<chat-id>`, cut from the coworker's
`coworkers/<handle>` home branch. At turn end Syrus commits with the coworker's
git identity, pushes the chat branch, and merges it into the home branch. Clean
and file-disjoint changes merge automatically; append-oriented files under
`memory/` use Git's union merge driver. A conflict first gets a bounded private
resolution attempt that preserves compatible updates from both parents. Syrus
validates the final merged tree even when Git reports success: the index must
be merged, changed text files must contain no conflict markers, structured
files must still parse, and `git diff --check` must succeed before the home
branch advances. If safe automatic resolution is not possible, Syrus keeps the
clean home and source parents on recovery refs and the conflicted local checkout
intact without committing the invalid attempted tree. It then gives the
coworker a bounded opportunity to reconcile both sides on a later turn.
Unchanged turns do not spend a retry. Only exhausted retries, a one-hour
resolution deadline, failed validation, or inaccessible recovery data produce
one owner-facing warning. The Workspace
Browser lists pending and failed-but-unresolved conflicts and drops them as
soon as resolution succeeds. A missing local checkout is re-cloned from the
canonical remote.

Background runs use the same lifecycle before their agent step can succeed:
Syrus captures modified, added, moved, deleted, and untracked files in a commit
authored with the coworker's Git identity, then merges that immutable run ref
into the home branch. Agents leave changes uncommitted. A conflict first
preserves the immutable run ref and enters the same silent recovery path as a
chat turn. A terminal conflict or push failure posts one actionable result to
the main chat before the anchor Job closes.

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
Every turn with an active `workspace.files` grant receives create/replace,
exact-edit, move, and delete tools rooted at that coworker's current checkout;
revoking the grant removes them from the provider's effective inventory. Absolute
paths, traversal, symbolic links, `.git`, attached product repositories, and
other coworker workspaces are outside that boundary. The tools only mutate the
working tree; branch commits, merges, pushes, and conflict recovery remain part
of the orchestrated coworker branch lifecycle. Paths listed in `confirm_paths`
still require owner confirmation when the grant's general policy is `auto`.
During a scheduled background run, these tools and the agent's shell share the
workflow checkout that Syrus commits and merges. If the final result explicitly
claims a workspace or memory path that is absent from the persisted run tree,
Syrus reports a persistence warning and fails the run instead of posting a false
success. Runs that claim no paths and runs that make no changes are unaffected.

When enabled, the plugin adds a Coworkers page and a badge counting pending
approvals across the signed-in owner's coworkers. Syrus is
pinned first as the built-in engineer; custom coworkers show their configured
color and avatar. The creation form collects the workspace remote, appearance,
model, grants, and optional About text. Uploaded avatars are size-limited and
resized before Active Storage saves them. Coworker chats are grouped separately
in the chat sidebar. Each coworker's main chat acts as a collapsed folder for
its side chats; expanding it shows the configured number of chats at first,
with controls to show more or fewer. Assistant messages use the coworker's
avatar and color.
Coworker chats carry a named badge in global search, chat search, and the
agent-facing chat search tool. The shared chat filter offers each of the
current user's coworkers plus Syrus, where Syrus means a chat without a
coworker link. Main and side coworker chats keep their workspace repository
attachment, but they do not make that workspace the automatic repository
default for a new ordinary chat. The workspace remains available for explicit
selection wherever the owner is otherwise authorized to use it.

Chat owners can share a chat read-only with one of their own coworkers from
the normal share dialog. A coworker with the `chats.read_shared` grant can
list, search, and read every active chat the signed-in owner can access: the
owner's ordinary Syrus chats, every owned coworker chat, participant chats,
and chats shared with the owner. This delegates the owner's normal chat
relation, not instance-administrator visibility, so another user's private
chat remains inaccessible even when its ID or message text is known. Normal
soft-delete, hidden-participant, repository, pagination, and sharing rules
still apply. In `search_chats`, `coworker_id` filters that same relation by
the coworker linked to each chat; `syrus` means no coworker link. The filter
has identical meaning in owner and coworker turns. Coworkers are never offered
the arbitrary `send_chat_message` tool.

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

Chat owners add their coworkers to a chat's agent roster by choosing an
autocomplete result marked "Add to chat."
Rostered coworkers become addressable by every participant in that chat. An
exact structured mention delegates the message to a reusable hidden coworker
session for that source chat; the coworker's final answer returns automatically
as a named, colored coworker message, and the planner does not answer the
mention. Proposals, structured questions, permission requests, spawn requests,
and confirmation cards created during the hidden turn appear directly in the
source chat. Answering or confirming there resumes the hidden session; queued
approval policies keep using their normal unattended behavior. Each roster row
has an `after_reply` policy. The default `wake` starts one source-chat planner
turn after a delivered reply, subject to the coworker hop cap and rate limit;
`quiet` delivers the reply without waking the planner. A turn that only created
an owner-facing item still awaiting a decision does not wake the planner. When
one message names several rostered coworkers, only the first one
answers. A coworker is also implicitly addressable in its own main and side
chats without a roster entry. Coworkers that are neither the chat's implicit
coworker nor on its roster remain plain text and do not start a turn. Rostered
coworkers can be removed by the chat owner, and coworkers owned by anyone else
cannot be added. The roster is shown beside the chat heading. Removing a
coworker also revokes its read-only share of that source chat.

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

Workspace is the single read-only browser for the coworker's identity, memory,
and other files on its home branch through the same cached repository-content
providers. Its collapsible folder tree, breadcrumbs, Memory and `SOUL.md`
shortcuts, and server-side filename/content filters keep large workspaces
navigable without downloading every file. Search results, bounded history, and
truncated content say explicitly when they are incomplete. Old Profile and
Memory links open the corresponding Workspace scope. Workspace also shows the
remote and branch, available commit history, and chat branches with unresolved
merge conflicts. The only remote action is **Test push access**,
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

Coworker turns are contained exactly when the instance opts in through
`AppSetting#contained_chat_execution`, on the same switch and with the same
behavior as every other chat agent — being a coworker is not itself a reason to
containerize. See `container_execution.md` for the three modes.

The reason containment matters here at all is the read-only grant below: strip-
ping write bits cannot stop a process running as the checkout owner from
restoring them, so only a read-only mount actually enforces `code.read`. That
argument applies to any chat agent holding such a grant, and it does not apply
to an interactive coworker chat with no product repositories attached.

When a turn is contained, the per-turn container can write only the coworker's
chat checkout and that chat/provider's agent home, while the existing turn
finalizer commits and merges checkout changes into the home branch. Temporary
files and the container itself are discarded after the turn.

## Read-only repository access

Coworkers start without product-code access. Owners can grant `code.read` for
an explicit set of accessible repositories or for all repositories the owner
can read. Its only policy is `auto`: once the owner confirms the grant and its
scope, the coworker can attach or detach product repositories in chats, list
files, read capped and secret-redacted files, search code, and inspect pull
request or Job diffs. Background runs receive the navigation and diff tools;
attaching and detaching checkouts remain interactive-chat actions.

Repository searches and file listings identify incomplete answers explicitly.
Their payloads include a status, reason, searched paths, coverage figures, and
guidance to narrow the path or retry when a time, file, provider, or result
budget is reached. An empty incomplete search is inconclusive, never a
definitive no-match. Search skips dependency, temporary, log, coverage, and
build-output directories unless the requested path is inside source content.
The chat tool cards show the same warning and coverage to operators.

Attached product checkouts are recursively stripped of write bits, including
Git metadata. The `workspace.files` and `workspace.shell` grants continue to
apply only to the coworker's own workspace repository, which remains the
chat's primary repository regardless of product attachment order. Product
repositories remain secondary attachments for code-reading context and never
become persistence targets. This blocks ordinary native-shell writes and Git
persistence. Until the agent sandbox supplies a true read-only mount, a hostile
process running as the checkout owner could restore its own mode bits; that
remaining gap belongs to sandbox enforcement.

## Job autonomy guardrails

Repository-scoped coworker permissions can allow a coworker to file Jobs and
act on Jobs it filed itself. The permission editor configures maximum open
self-filed Jobs, self-approvals per day, and feedback rounds per Job. Reaching
a limit never discards the action: it creates an operator-confirmation request
whose evidence names the exceeded limit.

Self-approval excludes sensitive diffs by default. A deterministic classifier
recognizes migrations and the schema dump, permission or security code,
default-setting changes, grader configuration in `.syrus.yml`, and top-level
JSON API version changes. Owners may explicitly disable this carve-out for a
coworker's repository permission. Required reviews must still approve the
current implementation HEAD.

Jobs explicitly filed as bug fixes have an additional regression-proof gate.
A newly added regression spec must pass in the implemented branch and fail
when rerun at the base revision. The proof is cached against the exact base and
implementation HEAD; advancing the implementation invalidates it.

## Coworker page payload limits

The coworkers UI loads the lightweight list and identity records first, then
fetches creation options and each detail tab only when needed. Activity
history is returned in pages of at most 50 runs and 50 side chats; **Load
more** follows opaque cursors. Memory and workspace browsers return at most
1,000 files, identify partial results, and cap individual file reads at 256
KiB.

## Health and spend metrics

When the Coworkers plugin is enabled, `/metrics` publishes handle-scoped
Prometheus series for journaling state, last-result age and failures; unsaved
workspace age and retry attempts; workspace push failures; and cumulative chat
and background-run spend. These series never contain chat, message, Job,
Workflow, or Run identifiers or content. Sampling runs on the shared metrics
tick and scrapes only render its cached snapshot.

The Metrics Dashboard includes a **Coworkers** tab grouping journaling age and
state, unsaved-workspace age, and spend rates by coworker handle. The shipped
Prometheus rules warn after 36 hours without a journaling result (excluding an
owner-paused schedule), page after 72 hours or three repeated failures, warn
after one hour of unsaved workspace state, and page after six hours. They also
detect sustained push failures and daily spend above the rule file's anomaly
multiple or absolute cap. Operators can tune these literal thresholds in
`config/prometheus/syrus-alert-rules.yml`.
