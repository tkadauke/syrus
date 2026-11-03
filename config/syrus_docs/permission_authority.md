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
