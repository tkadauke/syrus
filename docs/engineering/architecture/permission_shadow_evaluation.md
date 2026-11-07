# Effective permission diagnostics

Syrus records the canonical permission decision that actually governs an
agent invocation. The evaluator is the sole authority path; diagnostics are
observational and can never add authority or change a decision.

Each decision records a redacted operational event from
`permissions.policy_evaluator`, including the actor type and id, runtime role,
capability and operation, effective policy, decisive rule, and stable
invocation fingerprint. Argument values are never included.

Diagnostic persistence fails open because it is not an authorization input.
The evaluator itself fails closed at each dispatch boundary. Execution
ceilings are reported as the effective policy, so an evaluator `allow` lowered
to `ask` or `deny` is visible without being mistaken for executable authority.

Admins can inspect recent effective decisions through the compatibility API
`GET /api/v1/app/admin/permission_parity` or the token-authenticated
`GET /api/v1/admin/permission_parity`. The payload groups the limited recent
window by effective policy, actor, invocation fingerprint, capability, and
role, and includes recent redacted events. `limit` defaults to 100 and is
capped at 500.
