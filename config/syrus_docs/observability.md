# Observability Event Streams

Syrus uses structured event streams for operational/debug data that needs to be
queried after the fact. New streams should use `Observability::EventStream` and
`Observability::EventSink` instead of writing bespoke inline event-table code.

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

Browser error events include the signed-in user, app revision, fingerprint,
error name/message, JavaScript stack, React component stack, URL/path, viewport,
feature flags, recent API requests, recent browser errors, and bounded metadata.
Payloads are sanitized and size-capped in `BrowserErrorEvent` before storage so
large stacks or recent-error blobs cannot create a second incident while being
reported.

The Vite production build emits JavaScript source maps so captured stack frames
can be mapped back to frontend source while debugging. Source maps are generated
with the normal SPA assets, so this is appropriate for Syrus' internal admin
deployment model; public deployments should make an explicit choice about
whether source maps are acceptable to serve.

The admin UI exposes this stream at **Admin -> Browser Errors**
(`/admin/browser_errors`). The app API endpoint is
`GET /api/v1/app/admin/browser_errors`; the token admin API endpoint is
`GET /api/v1/admin/browser_errors`. Both are paginated newest-first and accept
`query`, `since`, `until`, `fingerprint`, `path`, and `revision_scope` filters.
Rows can advertise event actions. Browser error rows expose **File Job**, which
routes through `POST /api/v1/app/event_actions/file_job` with
`event_type=browser_error` and includes the full stored log entry in the created
Job prompt.

Unlike the high-volume observability streams, browser errors are inserted
synchronously instead of through `Observability::EventSink` because the browser
fallback needs the persisted event ID immediately. The row is still append-only
and pruned by `FlushObservabilityEventsJob`. Browser error events retain 14 days
of data.

The default-off `browser_error_auto_reports` feature can turn captured browser
errors into normal Syrus bug-report jobs. When enabled, every new browser error
enqueues `BrowserErrorAutoReportJob`; the job claims a separate
`browser_error_auto_reports` row keyed by fingerprint and app revision, then
routes one bug report through the standard `BugReports::Router`. Duplicate
events with the same fingerprint on the same revision do not create more jobs.
The captured `BrowserErrorEvent` remains append-only evidence independent of
whether bug-report routing succeeds.

## Backend Exceptions

The `backend_exception_events` table records Rails request and Active Job
exceptions from the same ActiveSupport notification hooks used by operational
logging. It is not gated by `operational_log_indexing`, so production exception
history still exists when full operational log indexing is disabled.

Backend exception events include the app revision, fingerprint, source
(`action_controller` or `active_job`), exception class/message/backtrace,
request context, job/run context, process role, hostname, pid, and bounded
metadata. They are append-only and pruned by `FlushObservabilityEventsJob`.

The admin UI exposes this stream at **Admin -> Backend Exceptions**
(`/admin/backend_exceptions`). The app API endpoint is
`GET /api/v1/app/admin/backend_exceptions`; the token admin API endpoint is
`GET /api/v1/admin/backend_exceptions`. Both are paginated newest-first and
accept `query`, `since`, `until`, `fingerprint`, `source`, `exception_class`,
`path`, and `revision_scope` filters. Backend exception events retain 14 days
of data. Backend exception rows expose the same generic **File Job** event
action, but only admins may use it. The created Job prompt includes the full
stored exception entry.

## Existing Streams

`performance_log_events` contain slow request, slow SQL, slow phase, and browser
trace diagnostics. They retain 24 hours and are surfaced by Admin -> Performance
when the `performance_logging` feature is enabled. Phase SQL counts are
inclusive of nested work, but phase SQL fingerprint drilldowns are exclusive:
each query is attributed to the deepest active phase so the same statement does
not appear under multiple nested phases.

`operational_log_events` contain structured process/request/job logs. They
retain 6 hours and can be indexed for full-text search when
`operational_log_indexing` is enabled.

`work_engine_reconciler_activity_events` contain detailed reconciler issue,
plan, and repair execution rows. They retain 7 days and are surfaced by
Admin -> Reconciler Activity.
