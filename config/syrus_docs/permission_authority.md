# Permission authority lifetimes

Syrus represents permanent agent authority as an audited `PermissionRule` and
temporary authority as a `PermissionLease`. Temporary leases support one exact
invocation, the current chat session, or the current Job. Workflow and Run ids
may identify where a request originated, but they are not authority lifetimes.

Exact-invocation leases bind to a canonical SHA-256 fingerprint of the
descriptor-normalized arguments and have exactly one use. Chat leases stop
matching when their chat is deleted. Job leases stop matching when their Job
reaches a terminal state, including across retries and follow-up Workflows.
Every lease can additionally have an expiry or use limit and can be revoked.

`Permissions::AuthorityGrant` validates the requested duration against the
capability descriptor and evaluates the proposed authority against current
non-delegable policy ceilings before persisting it. `Permissions::LeaseAuthorizer`
locks candidate leases, rechecks subject, scope, fingerprint, lifecycle,
expiry, revocation, use count, and the complete current policy chain, then
consumes the decisive lease in the same transaction. An existing or newly
introduced deny therefore prevents a queued lease from authorizing a call.

This is authorization substrate. Capability integrations must call the
authorizer immediately before dispatch; merely creating a lease never executes
an operation or bypasses the capability's ordinary application authorization.

## Permissions Hub

Each signed-in user has a Permissions Hub at `/settings/permissions`. It keeps
durable delegation separate from operational approvals: the hub lists editable
user-owned rules and read-only inherited capability defaults, identifies policy
ownership, and explains which default is decisive when no more specific
permitted rule applies. Revoking a rule preserves its audit history.
The agent matrix compares evaluator-derived allow, ask, and deny states by
subject and capability, and marks states that vary by resource instead of
collapsing them into one policy. The resource view groups active rules by
provider-supplied typed scope labels. Editing creates an audited replacement.
Bulk changes require a complete server-normalized preview with a signed digest,
then apply the exact previewed set in one transaction or fail as stale.
Active-lease and history views expose temporary authority lifecycle, origin,
expiry, and use counts alongside requests, decisions, repeated-request
escalations, dismissals, non-actionable reasons, policy changes, revocations,
and execution outcomes. Results are scoped to the signed-in user and stored
argument or audit evidence is redacted before display.

Operational requests live at `/permissions/inbox` and in the compact global
Approvals drawer. Both surfaces, plus inline Job origin cards, read the same
durable authorization request. Each card shows the named subject and origin,
normalized resource, redacted arguments, effects, agent-supplied purpose,
available authority durations, and the decisive policy explanation. Multiple
requests can be selected and decided atomically when their items share a duration. Resolved and non-actionable requests
remain available as history; dismissing an obsolete request does not create a
deny rule.

Coworker authorization cards (in chat and in the inbox) default to three
decisions: Allow once, an adaptive action, and Deny. The adaptive action is
derived from the capability descriptor and the canonical rule draft, never from
a tool name: "Always allow similar" is offered only as a permanent rule for the
exact requesting coworker and normalized scope when the descriptor and every
higher-layer ceiling permit it; otherwise "Allow for this job" or "Allow for this
chat" is offered as the strongest safe duration. Invocation-only capabilities,
explicit denies and ceilings leave just Allow once and Deny. Choosing the
adaptive action opens an inline preview naming the coworker, operation,
repository, scope, duration and exclusions, with Confirm, Back and Customize.
Confirm creates the rule or lease and authorizes the waiting invocation in one
transaction, so a stale preview or ceiling creates neither; the approved item
links to its auditable, revocable rule, and a duplicate decision is refused.

**Customize** opens the one fine-grained rule editor, prefilled from the exact
pending call. The same editor backs the Permissions Hub (**New rule** and
**Edit**) and the readable preview on confirmed `grant_permission`,
`deny_permission` and `create_permission_lease` cards, so a rule is authored,
validated, audited and revoked identically from every surface. The editor offers
only what the capability descriptor supports: an exact coworker or supported
role subject, capability and operation, repository, the provider-declared
resource-scope fields, safe argument constraints (bounded allow authority only),
a supported duration, allow, ask or deny, and a rationale. Resource-scope inputs
come from the provider's scope schema (`options.fields`), never a raw JSON box.
Nothing is saved without a server preview showing the effective rule, its
exclusions, the ceilings that cap it, and representative matches and
non-matches; saving applies the preview's digest, so a changed ceiling or rule
set refuses the stale preview. Editing a rule applies the replacement and revokes
the original in one transaction, keeping the audit trail. Cards deep-link to the
Hub with `?request=<id>&item=<id>` (editor prefilled from the request) or
`?rule=<id>` (rule highlighted).

Background authorization requests are also routed through the operator's
notification settings. Normal and low-urgency requests share a configurable
batch window; urgent requests skip that window. All external delivery respects
the operator's UTC or named-zone quiet hours. Disabling or delaying external
delivery never hides the global Approvals badge, the blocked-agent indicator,
the central inbox entry, or the request at its origin.

The global Approvals shield sits beside notifications and always shows the
pending total. When an agent is stopped at an authorization checkpoint, the
shield uses an amber waiting halo until the request is resolved and announces
newly blocked agents to assistive technology. Reduced-motion preferences replace
the animated halo with a static ring. On mobile widths the shield opens the
shared full-screen Activity shell (`ActivityProvider`) on its Approvals tab
instead of the side drawer; notifications and approvals stay separate data
models and every decision keeps the same audit path. Infrastructure and security banners remain
the higher-priority alert surface.

## Plugin-provided AI approval

Approval plugins register an `approval_provider`; registration and plugin
enablement do not grant it authority. A user must create an explicit delegation
for one provider, capability, resource type, and typed resource scope. The
delegation can narrow the provider further with excluded effects and can be
revoked immediately.

An AI provider receives the role-labelled transcript, exact tool call, current
policy chain, and immutable invocation fingerprint. It returns structured
`allow`, `deny`, or `escalate` data with rationale, policy factors, confidence,
and evidence that core redacts before returning or storing it. Its authority
never extends beyond that exact invocation: it cannot create rules, leases,
grants, or other delegations.
Permission management, privilege changes, and financial effects remain
human-only. Core evaluates non-delegable plugin, instance, resource, and user
ceilings from the effective policy chain before calling the provider. Missing
providers, invalid output, confidence below `0.8`, and provider-owned cost or
rate outcomes escalate the existing request to a human.

The classifier envelope orders core non-overridable guidance, the provider's
default guidance, and repository guidance supplied by the authorization
context.

Transcript entries retain their explicit roles. The envelope labels transcript,
tool-call, and repository content as untrusted evidence; only the effective
policy chain is authoritative. Providers must disclose where this evidence is
processed and retained. The provider receives the complete evidence needed for
the decision, while the durable audit artifact redacts secrets from the
transcript, tool arguments, repository guidance, provider evidence, and decision.

### AI decision lifecycle

An AI decision attaches to the request that is already pending; it never opens
a second one. Only a request with a single operation item is delegable.
`allow` approves that item for the invocation duration and issues the
exact-invocation authority in one transaction, so a failure leaves the request
pending for a human. `deny` rejects only the current attempt: it creates no
rule or lease and does not start the denial cooldown, so a later identical
resubmission is evaluated again. Escalation, provider failure, and low
confidence leave the request in the human inbox without a new notification.
Each evaluation is recorded on the request's transition history with the
redacted audit artifact. An identical resubmission is re-evaluated only when
its transcript evidence differs from the last evaluation.

### Delegation and audit management

The Permissions Hub's AI approvals view (`/api/v1/app/approval_delegations`)
shows providers with their disclosure and default guidance, the owner's
delegations (provider, capability, resource type, bounded scope, status),
the core human-only exclusions, and the owner's `ai_approval_evaluated`
history. It reports `enabled: false` until a provider plugin is registered.
Creating a delegation requires a registered provider, a known capability, and a
non-empty scope; revocation is immediate and attributed to the human. Requests
carrying a workflow invocation credential are rejected so an AI principal cannot
delegate to itself.

## Agent-facing management APIs

Chat agents can inspect the signed-in operator's effective store with
`list_permissions` and explain a specific invocation with
`explain_permission`. Changes use `grant_permission`, `deny_permission`,
`revoke_permission`, `create_permission_lease`, `revoke_permission_lease`,
`apply_permission_preset`, and `cancel_authorization_request`.

Every management mutation creates a human-readable pending action. The
requested change is not applied until the operator confirms it, including
revocations and cancellations. Confirmation resolves the target again within
the confirming user's permission store and then rechecks the capability's
duration and delegation ceilings. A management request can therefore never
use the permission it is attempting to create to authorize itself. Durable
rules keep append-only audit events, and revoking either a rule or lease also
invalidates its unclaimed authorized invocations.

## Coworker self-service: requests, surrender, and revocation requests

Coworkers get three ungated tools that only ever act for the calling coworker.
None of them takes a subject parameter, and none exposes the management tools
above (`grant_permission`, `deny_permission`, `revoke_permission`, rule editing
and the rest of the permission store stay chat-only).

- `request_permission` asks the owner for authority for the coworker itself:
  exact capability and operation, normalized resource scope, descriptor-supported
  constraints, a purpose and the narrowest suitable duration. The request is
  validated through the same `RuleDraft` preview the Permissions Hub applies, so
  only durations the descriptor autonomy ceiling and the owner's policy accept
  are offered. Creating it grants nothing: it creates (or reuses) the same
  durable authorization request shown in chats and the approval inbox. The
  owner's adaptive approval never exceeds the duration the coworker asked for,
  and approving without choosing a duration is refused. Equivalent requests are
  deduplicated; a coworker may have at most three waiting requests and six per
  hour, and cannot re-ask for an hour after a denial.
- `surrender_permission_lease` immediately revokes an active lease whose exact
  subject is the calling coworker. Reducing its own authority needs no owner
  confirmation. Leases of other coworkers, role-wide leases and other owners'
  leases are reported as not found.
- `request_permission_revocation` asks the owner to revoke a durable rule whose
  exact subject is the calling coworker. It creates an owner-confirmed pending
  action; the rule is neither revoked nor edited until the owner confirms, and
  the subject is checked again at confirmation.

Authority is never transferable: when coworker A asks coworker B to do
something, B is evaluated only against B's own rules and leases.

Requests, deduplications, rate limits, denials, grants, surrenders, revocation
requests and final revocations are recorded as append-only admin actions named
`coworker_permission_*`; rule creation and revocation also keep their
`PermissionRuleAuditEvent` rows.

## Coworker enforcement

A gated coworker invocation runs through the common evaluator. Descriptor
defaults are active authority; legacy coworker grants neither advertise a tool
nor bypass its decision. An `allow` decision dispatches immediately, `deny`
fails closed, and `ask` creates one exact-operation request containing a
redacted argument snapshot and stable invocation fingerprint. Equivalent active
requests deduplicate.

Approval creates an invocation-only lease and an `AuthorizedInvocation` before
enqueueing execution. The worker atomically claims that record, re-evaluates the
current rule and lease chain under the claim lock, and dispatches only for a new
claim with an exact fingerprint. A revoked or newly denied authority therefore
invalidates queued work, and retries cannot replay an already claimed call.
Only tools explicitly classified as safe, ungated local operations bypass this
flow. Other runtime roles continue to use shadow comparison rather than this
enforcement cutover.

## Job and Epic lifecycle capabilities

Core Job and Epic lifecycle tools use stable, explicit capabilities instead of compatibility descriptors:

- `syrus.jobs@v1`: `create`, `approve`, `unapprove`, `cancel`, `retry`, `retry_base_refresh`, `poll_feedback`, `rebase`, `reopen`, `close`, `check_mergeability`, `unland`.
- `syrus.epics@v1`: `start`, `move_to_backlog`, `archive`, `unland`.
- `syrus.landing_queue@v1`: `pause`, `resume`, `wake`, `force_recheck`, `override_blocker_once`.

A single-Job call and a bulk call (`job_id` versus `job_ids`) share one operation and are classified and fingerprinted identically, so approving one Job or many evaluates the same way. Proposals (`propose_job`, `propose_epic`, `propose_epic_with_jobs`) remain a separate lifecycle and are not part of these capabilities. All of these default to `ask`.

## Admin repair, operations, and delivery capabilities

Consequential admin repair, operational, and delivery chat tools also use explicit capabilities:

- `syrus.admin_repair@v1`: state repair such as `force_fail_job`, `reconcile_job_state`, `force_state_transition`, `cancel_stale_work`, `retire_terminal_work_unit`, `reenqueue_work`, `repair_queue_affinity`, `retry_step`, `cleanup_workspace`, `reap_stale_runs`, `kill_process`, `manual_agentic_run`, `force_rebase`, `restack_epic`, PR-branch adoption/replacement, CI repair, and provider-circuit repair.
- `syrus.operations@v1`: `maintenance_tasks`, polling/run/user-scheduling pause and unpause, `clear_github_cache`, `refresh_installations`.
- `syrus.delivery@v1`: `select_track`, `dispatch_ref_movement`, `emergency_land`.

The evaluator decides whether the invocation may proceed. It does not replace the tool-specific checks: preconditions, before/after repair snapshots, and fresh validation of the live record at execution time stay in the tools and their pending-action executors. Every operation is capped at exact-invocation authority (no chat-session, Job, or permanent lease) and defaults to `ask`. `emergency_land` is classified critical, destructive, and irreversible.

## Schedule, communication, document, and artifact capabilities

Core chat tools whose effects persist or leave the conversation use explicit capabilities:

- `syrus.schedules@v1`: `schedule_wakeup` (persistent autonomy, `ask`) and `cancel_wakeup` (own pending wakeup, `allow`).
- `syrus.communication@v1`: `send_chat_message` (`ask`, up to chat-session authority) and `spawn_chats` (`ask`, exact invocation only).
- `syrus.documents@v1`: `create` (`ask`) and `delete` (destructive, `ask`, exact invocation only) for repository documents.
- `syrus.artifacts@v1`: `submit`, a low-risk edit of an artifact the caller owns, which stays automatic (`allow`).

Repository-document create and delete keep their pending-action lifecycle and re-validate the live record when the approved action runs; bridge threads keep their hop limits. The evaluator only decides whether the invocation may proceed.

## Local Mode capabilities

`run_command` and `write_file` in Local Mode use `syrus.local_mode@v1` (`run_command`, `write_file`), defaulting to `ask` for the `chat:local` role with invocation or chat-session authority at most. The resource scope is the workspace the daemon is attached to: the repository plus the normalized absolute checkout root the CLI reports at connect time, so two checkouts of one repository never share authority (a daemon that reports no root is scoped to its connection); the fingerprint and lease constraints use the normalized command, or the root-relative path plus the content digest. The classifier adds `network_read`, `external_write`, `credential_use`, `destructive`, or `privilege_change` from the arguments. Leases only cover plain `operator_host_access`, so those calls ask every time. The daemon keeps enforcing the repository-root sandbox.

## Input ingestion, attachment, confidential-read, and binding capabilities

Chat tools that bring outside content in, materialize attachments, read confidential records, or bind a chat to a repository use explicit capabilities:

- `syrus.ingestion@v1`: `pull_request` (`ingest_pull_request`, creates a Job, `ask` up to chat-session authority), and the `network_read` observations `read_pull_request`, `list_open_issues`, `list_open_prs` (`allow`).
- `syrus.attachments@v1`: `materialize_chat_media` (`allow`) and `read_artifact` (`confidential_read`, `ask`).
- `syrus.confidential_reads@v1`: `read_run_transcript`, `read_job_diff`, and `read_chat_messages` (`ask`, up to chat-session authority); `search_chats` (`allow`).
- `syrus.resource_bindings@v1`: `attach_repository` (`ask`, scoped to a repository slug) and `detach_repository` (`allow`, it only narrows access).

Scopes are visibility-safe: the repository scope is the slug alone and is never resolved through a lookup, so a rule label or comparison cannot reveal whether a repository exists. Redacted arguments keep identifiers but replace free text (`query`, `body`, `content`, `text`, `prompt`) with a short digest, and carry a `provenance` of `external_untrusted` (GitHub content) or `syrus_internal`. Provenance is not part of the fingerprint. Tools keep their own visibility filtering and answer unknown and invisible records identically.

## Host and container execution (deny-only enforcement)

Processes Syrus starts through `Execution::Router` are evaluated by `Permissions::ExecutionGate` under `syrus.execution@v1` (`host_process` on the worker, `container_process` in a confined backend). The classifier derives `network_read`, `external_write`, `credential_use`, `destructive`, and `privilege_change` from the command line (sharing the Local Mode patterns) and the network profile. Injected environment variables are not treated as credential use. Plain work keeps its `allow` default; sensitive effects that were allowed only by default become `ask`.

**What is enforced today:** a `deny` stops the process before it starts, whether it comes from the owner's durable rules or from a ceiling. Rules are created through the normal permission tools and the Permissions Hub (the execution operations are in the catalog) and match a process by subject selector: the chat role (`interactive_chat`, `coding_chat`, `local_chat`), `workflow_role`, `repository_role`, `agent`, or `eligible_roles`. When several apply, the strictest result wins. The only default ceiling is `FailClosedHost`, which denies host execution under a fail-closed workload policy. `NetworkProfile` and provider `ProviderLimits` ceilings exist but are opt-in. Ceilings only lower a decision; no rule or lease raises one, and existing confinement (the grader network profile, container backends) is unchanged.

**What is not enforced yet:** an `ask` is logged with a redacted subject (executable and command digest) but does not block, because Syrus-launched processes have no interactive approval route. `Router.new(enforce_ask: true)` refuses them. Provider-native actions (a provider's own shell and file tools) run inside the provider CLI and are not intercepted; `ExecutionActions.subject_for_provider_action` and `ProviderLimits` are groundwork for that path.

## Fresh authentication and budget metadata

A capability descriptor may declare `fresh_authentication_window`. When the approver's authentication is older than that window (or unknown), an `allow` is lowered to `ask`; like the execution ceilings it can never raise a decision, and a `deny` stays a `deny`. Dropping the window or lengthening it in a capability successor is reported as semantic widening.

A descriptor may also declare `budget_dimensions` (`model_tokens`, `compute_time`, `network_egress`, `external_spend`, `storage`). This is effect metadata only: `Permissions::EffectMetadata` hands observers the classified effects, risk, and dimensions of a non-denied decision. Budgets are not permission grants — observer return values are ignored and a failing observer never changes the decision.
