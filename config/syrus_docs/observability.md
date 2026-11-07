# Observability

## System Alert Delivery

`SystemAlerts` still renders authenticated in-app banners, and
`SystemAlertDeliveryJob` evaluates the same alert sources every minute so
alarm-severity alerts can be sent even when no operator has a browser open.
Configure either or both of:

- `SYRUS_ALERT_WEBHOOK_URL` — POSTs a JSON payload for each alarm;
- `SYRUS_ALERT_EMAIL_TO` — comma-separated mail recipients.

System-alert email has no user recipient record from which to select a locale,
so its fixed subject and labels always use the application's configured default
locale. Alert titles, messages, action steps, and CTA text are operational
payload text and are delivered verbatim; they are not treated as translation
keys.

Delivery is deduplicated by the alert's `dismissal_key` in
`system_alert_notifications`, so repeated scheduler ticks or multiple operators
seeing the same banner do not flood the sink. Only `:alarm` alerts are delivered
outbound; warning and info banners remain UI-only. Failed deliveries stay
eligible for the recurring job and are retried with bounded backoff. When the
retry bound is exhausted, the notification is marked with `dead_lettered_at`;
the readiness probe reports that as an alert-delivery failure until an operator
fixes the sink and clears or redelivers the affected row.

The shared sink provides:

- a per-process in-memory ring for very recent events;
- optional JSONL spooling for durable streams;
- a lazy background flusher plus `FlushObservabilityEventsJob` as a scheduled
  backstop;
- model-specific row builders via `from_event_hash`;
- consistent timestamp parsing and JSON normalization through
  `ObservabilityEventRecord`.

Use durable streams for lifecycle or incident evidence that should survive a
worker restart before the next database flush. Avoid using durable streams for
high-cardinality debug noise unless the event is actionable and retention is
bounded.

## Workflow Activity

The `workflow_activity_events` stream is the broad Syrus activity timeline. It
records lifecycle events that explain what Syrus is doing and where time is
being spent:

- `workflow_created`
- `workflow_started`
- `workflow_finished`
- `run_started`
- `run_finished`
- `landing_queue_changed`
- `landing_workflow_dispatched`

Events include references where available: repository, Epic, Job, Workflow,
Step, Run, trigger kind, state, reason key, duration, source, message, and
structured metadata. Landing queue snapshots are recorded only when the cached
queue state materially changes; recurring queue ticks with the same blocker and
position do not create another row.

The admin UI exposes this stream at **Admin -> Activity** (`/admin/activity`).
The app API endpoint is `GET /api/v1/app/admin/activity`; the token admin API
endpoint is `GET /api/v1/admin/activity`. Both are paginated newest-first and
accept `event_type`, `job_id`, `workflow_id`, `run_id`, `trigger_kind`, and
`reason_key` filters.

`workflow_activity_events` retain 14 days of data. This is intentionally longer
than performance and operational logs so operators and agents can reconstruct
landing queue stalls and delayed retries across deploys.

## Browser Errors

The `browser_error_events` table records React error-boundary crashes from the
browser. Route-level and app-level error boundaries automatically post a
structured event to `POST /api/v1/app/browser_errors`; when the operator clicks
**Send error report** in the fallback banner, Syrus files from that persisted
event instead of rebuilding a partial report from the visible stack. The
fallback UI shows the captured browser error ID so an operator can correlate a
visible crash with the admin event stream.

The admin UI exposes this stream at **Admin -> Browser Errors**
(`/admin/browser_errors`). The app API endpoint is
`GET /api/v1/app/admin/browser_errors`; the token admin API endpoint is
`GET /api/v1/admin/browser_errors`. Both are paginated newest-first and accept
`query`, `since`, `until`, `fingerprint`, `path`, and `revision_scope` filters.
Rows can advertise event actions. Browser error rows expose **File Job**, which
routes through `POST /api/v1/app/event_actions/file_job` with
`event_type=browser_error` and includes the full stored log entry in the created
Job prompt.

The default-off `browser_error_auto_reports` feature can turn captured browser
errors into normal Syrus bug-report jobs. When enabled, every new browser error
enqueues `BrowserErrorAutoReportJob`; the job claims a separate
`browser_error_auto_reports` row keyed by fingerprint and app revision, then
routes one bug report through the standard `BugReports::Router`. Duplicate
events with the same fingerprint on the same revision do not create more jobs.
The captured `BrowserErrorEvent` remains append-only evidence independent of
whether bug-report routing succeeds.

## Existing Streams

Admins in regular chat and coworkers with the `ops.read_logs` grant share one
read-only diagnostics tool family. In addition to the operational-log,
worker-health, backend-exception, browser-error, and performance-event queries,
it composes the existing Metrics Dashboard history, Worker Timeline occupancy
and Workflow queries, resource-admission diagnostics, and per-Run queue
diagnosis. Timeline and admission results are restricted to Jobs and
repositories visible to the caller, including a coworker chat's attached
repository scope; live worker slots outside that scope are omitted. Global
fleet results require the same operational authority. Timeline ranges are
limited to seven days. Responses identify their source and freshness, enforce
fixed result caps, redact secrets, and never include mutation actions. The
grant defaults to confirmation and may be raised to automatic access; it never
adds repair, retry, pause, process-control, or event-filing actions. Metrics and
timeline tools report a disabled-plugin error instead of creating a parallel
data path when their owning plugin is off.

`performance_log_events` contain slow request, slow SQL, slow phase, and browser
trace diagnostics. They retain 24 hours and are surfaced by Admin -> Performance
when the `performance_logging` feature is enabled. Phase SQL counts are
inclusive of nested work, but phase SQL fingerprint drilldowns are exclusive:
each query is attributed to the deepest active phase so the same statement does
not appear under multiple nested phases.

## Page engagement telemetry

Syrus can collect opt-in estimates of an operator's active time on Job,
PR-review, and chat pages. Enable **Page engagement telemetry** in App Settings
(`AppSetting.ui_engagement_telemetry_enabled`). It is off by default; while it
is off the browser does not send samples and the API discards any that arrive.

Each page visit records only the signed-in user, an allowlisted route identifier,
the Job or chat ID, start/end timestamps, visible-tab time, and active time.
Active time stops after 60 seconds without pointer, keyboard, or scroll input.
It resumes with new input and never includes hidden-tab time. Samples are sent
when the page is hidden or left and are deleted after 90 days. Core exposes no
cross-user read endpoint for these samples.
