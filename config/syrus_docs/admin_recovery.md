# Admin Recovery

Syrus exposes narrow admin-only recovery actions for Jobs that are open but
stuck outside the normal workflow state propagation path.

## Force Fail Job

`POST /api/v1/admin/jobs/:id/force_fail` moves a non-closed, non-failed Job to
`failed` and returns the updated admin Job JSON. This is intended for recovery
cases such as a Job left `running` after its Workflow was cancelled or otherwise
stopped without propagating failure back to the Job.

The action is deliberately not a generic force-state endpoint. It only targets
`failed`, which keeps the Job open and lets operators use the normal Retry
workflow afterward. Closed Jobs return `422 validation_failed`.

The React admin stuck page surfaces a `Force fail` button for stuck Jobs in
`running`, `queued`, `implemented`, `approved`, or `landing`. Chat agents can
request the same recovery through the admin-only `force_fail_job` MCP tool; the
tool creates a pending action and does not mutate the Job until the operator
confirms it.
