# Observability

## Alarm delivery

Alarm-severity system alerts can be delivered without an open browser. Set
`SYRUS_ALERT_WEBHOOK_URL` for JSON webhook delivery and/or
`SYRUS_ALERT_EMAIL_TO` for comma-separated email recipients. Warning and info
alerts remain in-app only.

## Workflow Activity

Admin → Activity records `workflow_created`, `workflow_started`,
`workflow_finished`, `run_started`, `run_finished`,
`landing_queue_changed`, and `landing_workflow_dispatched`. Events include the
available repository, Job, Workflow, Step, Run, state, reason, duration, and
metadata references and are retained for 14 days.

## Browser errors

Browser crashes are retained for 14 days and appear under Admin → Browser
Errors. **File Job** creates a normal bug-report Job from the stored event. The
default-off `browser_error_auto_reports` flag automatically routes one report
per fingerprint and application revision while enabled.

## Chat diagnostics

Admins and coworkers granted `ops.read_logs` share read-only tools for
operational logs, worker health, backend and browser exceptions, performance,
metrics history, worker timelines, admission, and Run queue diagnosis. Results
are visibility-scoped, capped, secret-redacted, and contain no mutation
actions.

## Page engagement and retention

The page-engagement telemetry setting controls collection of page visibility
and engagement events. Operational streams have bounded retention: Workflow
Activity and browser errors retain 14 days; performance events retain 24 hours.

Event storage, exception schemas, source maps, performance phases, startup
milestones, and latency instrumentation are documented in
[`docs/engineering/architecture/observability.md`](../../docs/engineering/architecture/observability.md).
