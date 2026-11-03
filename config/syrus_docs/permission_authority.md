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
the animated halo with a static ring. Infrastructure and security banners remain
the higher-priority alert surface.

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
