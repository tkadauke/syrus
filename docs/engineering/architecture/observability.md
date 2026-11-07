# Observability architecture


Syrus uses structured event streams for operational/debug data that needs to be
queried after the fact. New streams should use `Observability::EventStream` and
`Observability::EventSink` instead of writing bespoke inline event-table code.

## How writes are paced

Every process runs its own flusher thread, so the sink's cost in database
statements is (processes x kinds x flushes). Two settings bound it:

| Setting | Default | Effect |
|---|---|---|
| `SYRUS_OBSERVABILITY_FLUSH_THRESHOLD` | 200 | Flush as soon as a buffer holds this many events |
| `SYRUS_OBSERVABILITY_FLUSH_INTERVAL_SECONDS` | 60 | Longest an event waits before being written |
| `SYRUS_OBSERVABILITY_FLUSH_TICK_SECONDS` | 5 | How often the flusher checks whether either applies |
| `SYRUS_OBSERVABILITY_RATE_LIMIT_PER_MINUTE` | 600 | Events accepted per kind per minute, per process |

A busy kind flushes on size, so bursts arrive as large `insert_all` batches. A
quiet kind costs one statement per interval rather than one per tick. The
interval measures the age of the *oldest buffered event*, not time since the
last flush, so it is a real bound on how long an event can wait.

Production ran at a 15-second interval with no size trigger and wrote 9-row
batches: the batching existed but the buffers never filled. Lower the interval
only if you are prepared to pay for it in statements.

### Rate limiting and the feedback loop

Thresholds for what counts as "slow" are absolute, so a degraded instance
crosses them constantly: a slower database produces more `slow_sql` and
`slow_phase` events, whose writes make it slower still. The per-kind ceiling
breaks that loop — past it, events are counted in `EventSink.stats[:dropped]`
rather than written, so the signal degrades to a sample instead of amplifying
the incident it is describing.

Durable kinds are never rate limited. They are spooled to disk precisely
because losing one is not acceptable.

### Writing through

`Observability::EventSink.flush!(kinds: [...])` forces a write. Readers do this
before querying (see `Admin::OperationalLogsPayload`,
`Admin::WorkflowActivityPayload`, `Admin::ReconcilerActivityPayload`) so recent
events are visible. Do NOT flush on the write path to make a row immediately
readable — that is a one-row INSERT per event, and it is what made reconciler
activity the largest source of single-row writes in the system.


Browser error events include the signed-in user, app revision, fingerprint,
error name/message, JavaScript stack, React component stack, URL/path, viewport,
feature flags, recent API requests, recent browser errors, and bounded metadata.
Payloads are sanitized and size-capped in `BrowserErrorEvent` before storage so
large stacks or recent-error blobs cannot create a second incident while being
reported.

The SPA shell also installs a very early startup diagnostic hook before the
Vite module entrypoint loads. During startup it captures global `error` and
`unhandledrejection` events, including failed script/stylesheet loads, and
reports them to this same browser-error stream as `StartupWindowError`,
`StartupUnhandledRejection`, or `StartupResourceError`. If React never marks its
first committed render after the short startup timeout, the shell reports
`StartupWatchdog`. These startup payloads include bounded launch context:
current path, app revision, asset revision, user-agent family,
`navigator.standalone`, `display-mode: standalone`, visibility state, recent
startup milestones, and resource paths for same-origin failed assets. They do
not include arbitrary promise rejection payloads or cross-origin resource URLs.

The Vite production build emits JavaScript source maps so captured stack frames
can be mapped back to frontend source while debugging. Source maps are generated
with the normal SPA assets, so this is appropriate for Syrus' internal admin
deployment model; public deployments should make an explicit choice about
whether source maps are acceptable to serve.


Unlike the high-volume observability streams, browser errors are inserted
synchronously instead of through `Observability::EventSink` because the browser
fallback needs the persisted event ID immediately. The row is still append-only
and pruned by `FlushObservabilityEventsJob`. Browser error events retain 14 days
of data.


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

### Frontend performance markers

`app/frontend/lib/performanceMarkers.ts` is a generic marker API frontend code
uses to place named timing spans -- the browser-side counterpart to
`PerformanceLogging.phase`. It deliberately reuses the existing browser trace
ingestion path (`POST /api/v1/app/performance_events` ->
`PerformanceLogging.record_browser_trace` -> `performance_log_events`) instead
of a parallel stream, so marker events show up in the same
`grouped_browser_traces` summaries the passive `PerformanceObserver`-driven
traces (`browser.long_task`, `browser.slow_input`, `browser.event_loop_lag`)
already use.

Event-loop rows describe timer delivery, not a direct measurement of CPU work.
Each row retains the route at sample time plus a stable `page_session_id`,
monotonic `callback_sequence`, `actual_interval_ms`, `expected_interval_ms`,
`quantized_cadence_run`, focus and display-mode state, a coarse user-agent
family, and only the latest lifecycle transition type/age. This bounded
context lets one page session be followed through SPA navigation without
retaining a lifecycle history or a high-cardinality user-agent string.

To reproduce the sampler's classification from a stored row, compare
`actual_interval_ms` with integer multiples of `expected_interval_ms`. A
callback within the larger of 20 ms or 2% of a multiple increments
`quantized_cadence_run`; any other callback resets it. The run count includes
callbacks omitted by the ten-second report limiter, so it is the bounded
aggregate needed to explain a retained row even when preceding callbacks were
not retained, and it saturates at three because larger values do not change
the classification. Counts below three are `plausible_main_thread_stall`; a
count of three is `ambiguous_quantized_cadence`. Focus, display mode, and the
latest lifecycle transition remain context only: none proves why a visible
timer arrived late, because periodic main-thread work can produce the same
shape. No isolated plausible stall is suppressed. Samples while hidden, the
interval spanning a visibility transition, and lags above the configured
plausibility ceiling are omitted and re-baselined. Correlate nearby long-task
and slow-input rows before claiming either blocking or browser throttling.

SPA startup milestones use the same browser trace ingestion path with
`startup.*` names. To keep volume bounded, normal Safari tabs keep milestones
in memory only; milestones are posted when the launch appears to be an iOS/Home
Screen standalone session (`navigator.standalone` or `display-mode:
standalone`) or when an operator explicitly opens a URL with
`startup_diagnostics=1`. The milestone metadata mirrors the browser-error
startup context so operators can compare `startup.shell_loaded`,
`startup.react_module_evaluated`, `startup.react_commit`, and
`startup.react_post_paint` for standalone launches without filing browser-error
jobs for successful starts. The definitions are deliberately non-cumulative:

- **transfer** is the Navigation Timing request/response interval plus up to 40
  same-origin `script` Resource Timing entries observed when the entry module
  finishes evaluation. Each entry contains request start, response start/end,
  transfer/encoded/decoded sizes, inferred cache status, delivery type, and
  connection protocol where the browser exposes them. Asset identifiers are
  pathnames only; origins and query strings are discarded. Zero and missing
  values are retained because browsers commonly suppress these fields.
- **evaluation** ends at `startup.react_module_evaluated`, immediately after
  the initial static module graph has evaluated. Subtract the latest relevant
  resource `response_end_ms` from this milestone's `duration_ms`; do not call
  the entire shell-to-module interval evaluation time.
- **commit** is `startup.react_commit`, emitted from React's layout-effect
  boundary after the first commit. It satisfies the existing startup watchdog
  and hides the loading shell.
- **paint** is `startup.react_post_paint`, emitted after two animation frames
  requested from that layout effect, so at least one paint opportunity has
  passed. Every milestone records `visibility_state`, `document_ready_state`,
  and the latest lifecycle state; hidden launches must not be interpreted as
  visible paint latency.

Reproduce a launch from a normal tab by adding `?startup_diagnostics=1`, then
query the Rails console (within the 24-hour retention window):

```ruby
events = PerformanceLogEvent.where(
  event_name: PerformanceLogging::BROWSER_TRACE_EVENT,
  name: %w[startup.shell_loaded startup.react_module_evaluated startup.react_commit startup.react_post_paint]
).where("occurred_at >= ?", 30.minutes.ago).order(:trace_id)

events.pluck(:trace_id, :name, :duration_ms, :path)
evaluated = events.find_by(name: "startup.react_module_evaluated")
evaluated&.payload&.dig("metadata", "startup_timings")
```

Helpers: `measureSync`/`measureAsync` (time a block, sync or async),
`startMarker`/`endMarker` (an explicit span that doesn't fit one function
call), `recordCount` (count-based context with no timing), and the
`useMarkedRender` React hook (a component's render/commit or render/paint
boundary, via a double `requestAnimationFrame` for the paint phase). Every
call produces one `BrowserTracePayload` sharing the same stable envelope as
the passive traces: `trace_id`, `name`, `path`, `duration_ms`,
`visibility_state`, `metadata`, plus optional `parent_id`/`interaction_id` for
correlating several markers under one enclosing operation or user
interaction. `app_revision` is stamped server-side in `base_event`, not sent
by the client.

Each call accepts `thresholdMs` (drop samples faster than this instead of
sending a zero-value row), `sampleRate` (probabilistic keep, 0..1), and
`maxPerSession` (a hard cap on how many events a given marker `name` may send
per page session) -- a marker placed in per-scroll-frame or per-keystroke code
needs all three to stay bounded. Events queue in memory and flush together
(debounced by size/time, or immediately via `navigator.sendBeacon` on
`visibilitychange`/`pagehide`) rather than opening one request per marker;
`postBrowserTraces` in `performanceTrace.ts` is the shared batched sender
underneath both the marker queue and this doc's passive observers. A beacon
request cannot carry the `X-CSRF-Token` header, so the CSRF token also travels
as an `authenticity_token` field in the JSON body, which Rails accepts from
either place; `PerformanceEventsController#create` accepts a single
`performance_event` (the passive observers' shape) or a batched
`performance_events` array.

The diff review surface (`ReviewWorkspace`/`ReviewableDiff`) is the first
consumer: `diff_review.fetch_source_diff`, `diff_review.parse_diff`,
`diff_review.initial_render`, `diff_review.syntax_highlight`,
`diff_review.viewport_render`, `diff_review.comment_threads_render`,
`diff_review.files_menu_open`, and `diff_review.anchor_scroll`, each carrying
metadata relevant to that phase (file/row counts, hunk counts, syntax token
span counts, thread counts, virtualization mode). Query them the same way as
any other browser trace: the `syrus_dev` plugin's `SyrusDev::PerformancePayload`
groups `grouped_browser_traces` by `[name, path]`, or filter
`PerformanceLogEvent.where(event_name: PerformanceLogging::BROWSER_TRACE_EVENT,
name: "diff_review.parse_diff")` directly.

### Per-job memory attribution (`job_memory_summary`)

Every job records a memory summary on completion, written straight to
`performance_log_events` (and, unlike most events, never to the log -- look
for it through `GET /api/v1/admin/performance?event_name=syrus.performance.job_memory_summary`,
not in `kubectl logs`). Each row carries `job_class` alongside start, end and
peak figures for RSS, cgroup memory and **heap live slots**.

Live slots are what make this a leak detector rather than a usage report. RSS
that grew while live slots stayed flat is a heap that was not returned to the
OS -- bloat, and largely harmless. Growth in both means objects are still
reachable, which is a leak, and the `end - start` difference per `job_class`
says which jobs are responsible. Note `start_*` is captured at the job's first
sample rather than at enqueue.

That identifies the *job*. To find the objects and then the allocating line,
take a `heap_histogram` and then an `allocation_trace` on an affected worker --
see below. Monitoring and hunting are deliberately separate: the summary is
always on and costs nothing, the diagnostics are opt-in and some of them are
expensive.

### WebSocket connect latency (`cable.connect`)

A slow live-updates connection is invisible in request timing. The HTTP
upgrade to `/cable` is pure network and completes in tens of milliseconds;
everything that can actually be slow happens after it, where no controller
timing reaches. Two complementary measurements cover it, both landing in
`performance_log_events` rather than anywhere new:

- **Server**: `ApplicationCable::Connection#connect` is wrapped in a
  `cable.connect` phase, with the session/`api_token` lookup separately
  wrapped as `cable.connect.identify`. The nested phase means a slow auth
  query is attributable on its own instead of being inferred from the
  difference between the two. Both obey the usual
  `slow_phase_threshold_ms`, so an ordinary fast connect writes nothing.
- **Browser**: the shared consumer records a `cable.connect` browser trace on
  each `connected` callback, measuring from socket creation to the
  subscription being confirmed -- the interval the user actually waits
  through. `metadata.reconnect` distinguishes the cold first connect from a
  later recovery, because a reconnect storm and a slow initial connect look
  identical from the outside and have different causes. The clock restarts on
  each connect, so a reconnect reports its own gap rather than the time since
  the page opened.

Note that cable lives in its own database but on the same server as the
primary, so it shares one buffer pool: connect latency can degrade because
unrelated large tables have evicted cable's pages, not because of anything in
the cable path itself. The server phase and the browser trace diverging --
fast `cable.connect`, slow browser trace -- points outward to the network or
the client instead.

### Chat startup latency (`chat_startup.*` phases)

The filesystem-dependent stages that run before a chat turn's agent process
actually starts working -- workspace/agent-home creation, the per-turn MCP
config write, provider session/transcript restore, and process spawn -- are
each wrapped in `PerformanceLogging.phase`/`.report_duration` under the
`chat_startup.<stage>` phase namespace, so they land in the same
`performance_log_events` stream (`event_name: "syrus.performance.slow_phase"`)
as every other phase, gated by the same `slow_phase_threshold_ms` (default
250ms) and the `performance_logging` feature. Stages: `workspace_ensure`
(`ChatWorkspace#ensure_root!`), `mcp_config_write` (`ChatTurnJob#with_chat_mcp_config`'s
tempfile write), `session_restore` (`ChatProviders::Claude#ensure_provider_session_on_disk!`;
for Codex, `codex_home_prepare`/`config_write`/`transcript_restore`/
`auth_refresh_lock`/`auth_prepare`/`auth_persist` from `CodexInvocation::StartupTiming`,
see `codex_agent.md`), and `process_spawn` (`ProcessRunner`, shared by both
providers, gated on a `chat_session` being attributed to the spawn so
workflow/grader spawns are unaffected).

Each of these phases opts into `capture_host_pressure: true`, so a slow
stage's `metadata` additionally carries `io_pressure_some`/`io_pressure_full`
(the "some"/"full" `avg10` values from the worker's cgroup v2 `io.pressure`
file, falling back to `/proc/pressure/io` when the cgroup file is absent),
`io_pressure_source`, and
`data_root_used_percent`/`data_root_filesystem`/`data_root_mounted_on` (from
`WorkerHostHealthSampler.io_pressure_snapshot`, a lightweight on-demand
snapshot -- it skips the periodic sampler's blocking CPU-delta read and
doesn't persist a `WorkerHostHealthSample` row). That snapshot is only taken
when the phase actually crossed the threshold, so a normal-speed turn never
pays for a pressure or data-root read. Deliberately excluded from
`chat_startup.*`:
first-agent-event/MCP-startup/usage-probe markers, which measure waiting on
the provider or a network call rather than local storage -- folding those in
would blur the provider-vs-storage-latency distinction this instrumentation
exists to draw. Database latency for a given stage is visible the normal way,
via that phase event's `sql_count`/`sql_duration_ms` fields (from `phase`;
`report_duration` calls -- used where a stage's timer is external to a
`phase` block, e.g. Codex's own stage timer -- don't carry SQL counts since
there's no block to instrument).

`operational_log_events` contain structured process/request/job logs. They
retain 6 hours and can be indexed for full-text search when
`operational_log_indexing` is enabled.

`work_engine_reconciler_activity_events` contain detailed reconciler issue,
plan, and repair execution rows. They retain 7 days and are surfaced by
Admin -> Reconciler Events.
