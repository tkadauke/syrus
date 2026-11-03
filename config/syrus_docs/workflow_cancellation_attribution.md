# Workflow cancellation attribution

Every Workflow cancellation records *why* it happened, separately from the
cleanup mechanics (`cancelled_by: terminal_workflow_cleanup`).

## Where it is stored

- **Workflow**: `artifacts["cancellation"]`, written before terminal cleanup
  starts. Fields: `event_id`, `root_event_id`, `parent_event_id`, `cascade_id`,
  `root_workflow_id`, `parent_workflow_id`, `occurred_at`, `kind`,
  `initiator_class`, `initiator_id`, `control_path`, `reason`, `source`,
  `attributed`.
- **Step**: `details["cancellation_attribution"]`, a reference to the
  Workflow's event (immediate parent is the Workflow).
- **Run**: derived from its Step (immediate parent is the Step).

A Workflow cancelled while another Workflow's terminal propagation is running
shares that cascade: same `cascade_id`, `root_event_id` and `root_workflow_id`,
with `parent_workflow_id` pointing at the Workflow that was propagating. Each
Workflow still has its own `event_id`.

Cause kinds: `direct_cancellation`, `supersession`, `dependency_invalidation`,
`stack_topology_repair`, `operator_cancellation`, `provider_rerouting`,
`automatic_recovery`, `infrastructure_shutdown`, and `unattributed`.
`source` keeps only identifier-shaped keys (`*_id`, `*_ids`, `*_slug`,
`*_number`); strings are credential-redacted. For supersession,
`source.replacement_workflow_id` is filled in when the replacement Workflow is
created later. Recording never overwrites an existing attribution.

Records created before this feature report `attribution_available: false`.

## Where it is exposed

The Job detail workflow and run payloads (`cancellation`), `read_workflow`
(including `descendants` and `replacement_workflow_ids` on the root), and the
`read_job` workflow index and `latest_workflow`.

## Unattributed cancellations

A cancellation reaching terminal cleanup with no cause and no parent cascade is
an invariant violation: it is stored with `kind: unattributed`, logged as
`unattributed_workflow_cancellation` at error level, and counted in
`syrus_workflow_cancellations_unattributed_total{kind}`.
`syrus_workflow_cancellations_total{kind}` counts every recorded event. Callers
should pass `cause:` to `WorkUnits::WorkflowCancellation.cancel!`.
