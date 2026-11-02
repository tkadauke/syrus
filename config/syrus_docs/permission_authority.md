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
