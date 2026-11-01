# Permission shadow evaluation

Syrus evaluates registered MCP capability descriptors alongside the existing
role, feature, grant, and Step dispatch filters. Shadow evaluation is
observational: its result never adds or removes a tool from the current tool
set.

When current dispatch differs from the descriptor's north-star policy, Syrus
records an operational event from `permissions.shadow_evaluator`. Evaluation
failures are recorded separately. Descriptors whose effects contain only
`local_read`, `isolated_workspace_write`, or `isolated_execution` are
explicitly identified as safe local operations; current dispatch remains
available if evaluator or diagnostic infrastructure fails.

Admins can inspect recent mismatches and failures through
`GET /api/v1/app/admin/permission_parity` or the token-authenticated
`GET /api/v1/admin/permission_parity`. The payload includes summary counts,
capability and role groupings, and recent redacted events. `limit` defaults to
100 and is capped at 500.

Parity fixtures under `spec/fixtures/permission_parity.yml` pin representative
legacy and north-star decisions. Add a fixture when migrating a distinct role
gate or consequence class so dispatch changes remain intentional and reviewed.
