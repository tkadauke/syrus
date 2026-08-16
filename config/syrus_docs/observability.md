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
