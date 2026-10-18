# Home worker episodic memory spike

## Conclusion

The strongest code-level explanation is throughput snapshot diff sampling, not
archive handling or `ProcessRunner`'s standard capture path.

`Throughput::MetricContract#output_diffs_by_run_id` asks MySQL for both
`runs.step_agent_diff` and `runs.agent_diff` for 25 Runs, then applies its
256 KiB-per-diff and 2 MiB-total limits in Ruby. Both columns are 16 MiB
`MEDIUMTEXT` columns. One refresh can therefore transfer and materialize close
to 800 MiB of diff text before retaining at most 2 MiB. The refresh lock is per
repository, while the polling callback enqueues one refresh per active
repository, so concurrent refreshes can multiply that transient allocation
past a 16 GiB worker limit. This mechanism fits an episodic cliff, the refresh
job's repeated presence at each worker death, and recovery after the particular
queue burst ended. The correlation does not prove that every failed refresh
was the allocating job, but this is the only audited path that combines large
database blobs, ineffective post-load bounds, and repository-level fan-out.

The contained follow-up is to make the database query enforce the bound before
the values cross the adapter boundary. Select only the preferred diff
(`step_agent_diff` when present, otherwise `agent_diff`), reject it with
`OCTET_LENGTH` when it exceeds 256 KiB, and return at most the existing 25
samples. Preserve the 2 MiB aggregate guard in Ruby. A regression spec should
inspect the query/result boundary and prove that an oversized preferred diff is
not materialized while fallback and aggregate-limit semantics remain intact.

## Candidate audit

### Throughput repository snapshots: plausible at 16 GiB under fan-out

The refresh job itself is serialized only by repository. A cache miss calls
`MetricContract#call` under a four-minute timeout; a timeout limits duration,
not memory.

The contract intentionally materializes several result sets with `to_a` and
reuses them across its five windows:

- jobs, PR-open Steps, landed Jobs, landing/rebase Workflows (including Steps),
  merge trains and members, review comments, feedback Workflows, approvals,
  and output Runs are loaded for the union of the metric windows;
- each window then creates filtered arrays, grouped hashes, latency arrays, and
  output summaries in Ruby;
- the wide output-Run query correctly selects only four narrow columns, so the
  ordinary cardinality cost is proportional to recent records rather than Run
  transcript/diff width;
- diff sampling defeats that care: `pluck(:id, :step_agent_diff, :agent_diff)`
  loads both full text values for 25 IDs and checks `bytesize` afterward.

The ordinary collections are unbounded by row count, but constrained by one
repository and normally seven days. They can produce hundreds of megabytes on
an exceptionally busy repository, especially because Active Record objects
and included associations cost more than their wire representation. They do
not independently offer a convincing route to 16 GiB in the observed workload.
The diff query does: its schema ceiling is about 800 MiB per refresh before
adapter and Ruby copies, and refreshes for different repositories can overlap.

`last_active` can widen the SQL interval earlier than seven days. It uses the
minimum start and maximum end of all windows rather than two disjoint ranges.
For an idle repository the gap should contain few relevant records because the
anchor is the latest of several activity timestamps, but it is not a strict
guarantee: approvals and some addressed-comment timestamps are not part of the
anchor. This is a secondary cardinality risk, not the most credible 16 GiB
mechanism.

### Prepared archives and immutable checkouts: disk-heavy, heap-bounded

Prepared archive publication runs `tar | gzip` (or `pigz`) through a pipe.
`StreamingSource` reads 1 MiB chunks, updates digests incrementally, and aborts
above a 1 GiB compressed-byte limit. S3 uses multipart streaming; other Active
Storage services receive the same IO object. Backpressure bounds the pipe.
The subprocess callback writes each chunk to the pipe and does not retain an
archive-sized Ruby string.

Restore downloads Active Storage chunks into a temporary file and invokes
`tar -xzf` through bounded `ProcessRunner#capture`. The expanded tree can be
large on disk, but Ruby never reads the archive or expanded files as one blob.
The host-level prepared layer cache has a 10 GiB default *disk* budget and an
eviction grace period; it is not an in-memory cache.

The largest Ruby collection in this area is `PreparedLayerCache.measure_bytes`,
whose `Dir.glob` materializes every path before summing file sizes. The code's
own expected tree is roughly 69,000 entries, making this a path-string/listing
cost in the tens of megabytes, not gigabytes. It should eventually be changed
to streaming traversal for robustness, but it does not fit the 16 GiB event.
Marker and lockfile JSON reads are small metadata files.

Archive stderr is written to a temporary file and read only on failure. It has
no explicit byte cap, so a pathological `tar`/compressor failure could make
that one read large; normal archive diagnostics are tiny and this is not a
credible explanation for repeated successful archive subprocesses.

### ProcessRunner and git output: standard capture bounded; one git wrapper is not

`ProcessRunner#capture` drains stdout and stderr concurrently in 16 KiB chunks
and retains independent prefixes, 1 MiB each by default. Continued child output
is discarded after the prefix while the pipes keep draining. A completed
invocation releases those buffers, so hundreds of sequential invocations do
not accumulate their captured output in a process-global collection.

`ProcessRunner#run` itself streams and retains no output unless a caller's
callback does. Most grader/prepare callers either write chunks to `JobLog` or
keep an explicitly capped tail. Archive publishing writes chunks into a pipe.

`GitRunner#run` is the relevant exception: its `on_output_line` callback appends
every line to an unbounded local `output` string so it can return command output
or build an error. The string lives for one git invocation, not all 885, and
ordinary git status/fetch/rev-parse output is small. It could reach gigabytes
only if one git command itself emitted gigabytes. The subprocess count and
completion status do not support that, and the failure correlation points
elsewhere. Still, this wrapper should use a bounded tail for errors and require
callers needing large successful output to opt into an explicit limit.

Two specialized CI-repair callers explicitly request a 1 GiB capture limit,
and a few focused-retry helpers append subprocess chunks without a bound.
Those are genuine high ceilings or unbounded callbacks, but they run inside
specific Run/grader paths rather than the frequent home-node git/archive work.
They could amplify a noisy command; they do not explain a burst dominated by
repository snapshot refreshes.

### Search indexing: bounded batches, unbounded bytes per source row

The normal index writers are small by count:

- one chat message, Job, Epic, or design document per job;
- one browser error in the normal enqueue path;
- an operational-log ID batch sourced from an observability flush (normally at
  most 250), then inserted in slices of 50;
- 500 chat messages per backfill batch and 1,000 operational events per rebuild
  batch.

Those count bounds are not byte bounds. Chat content, design-doc content,
browser error stacks/metadata, and operational log message/context fields are
loaded as complete values and passed to SQLite FTS. A manually oversized batch
argument can also bypass the normal enqueue sizes. Thus indexing can allocate
in proportion to persisted source text and, in theory, reach gigabytes if the
database already contains gigabytes in the selected rows. Reaching 16 GiB
would require hundreds of unusually huge records in one batch or one enormous
document/message plus SQLite copies. There is no evidence of that input shape,
and only isolated indexing failures occurred rather than the exact repeated
refresh pattern. Indexing remains a defensive-hardening target, not the leading
cause.

## Instrumentation that would make the next spike attributable

Existing performance logging already wraps every `ApplicationJob`, records the
job class/queue and Run/Workflow/repository IDs where applicable, and can attach
host pressure to slow phases. Its current pressure option is captured only
after a slow phase and contains IO PSI/filesystem context, not process memory.
An OOM-killed job never reaches the `around_job` ensure far enough to durably
describe its peak, and the in-memory performance-event buffer can die with the
worker.

The smallest durable extension is one process-wide memory high-water sampler
owned by `PerformanceLogging`, activated while at least one job context is
registered:

1. Sample process RSS and cgroup `memory.current`/`memory.events` every second.
   Reuse the existing worker-health readers rather than adding another metrics
   interpretation layer.
2. Keep the active job contexts registered by `around_job`. On each new coarse
   high-water bucket (for example every 256 MiB, plus 70/80/90% of the cgroup
   limit), synchronously persist a compact performance event containing RSS,
   cgroup usage/limit, heap live slots and the active job class/queue/entity
   contexts. Persist threshold crossings immediately rather than relying on the
   normal in-memory event flush.
3. Emit a final per-job start/end/peak event on normal completion. Rate-limit by
   bucket so a spike produces a handful of rows, not per-second telemetry.

A worker-wide RSS sample cannot perfectly divide shared heap among concurrent
job threads, so the event should record the complete active-job set and which
jobs started since the previous bucket. That would still have answered this
incident in one look: the last durable event before each kill would show the
memory slope and whether repository refreshes, indexing, or a Run overlapped
the threshold crossings. A targeted `PerformanceLogging.phase` around
`RepositorySnapshot#refresh!` can add finer attribution, but it is supplementary;
instrumenting only that suspect would leave the next unknown job-shaped spike
unexplained.

## Follow-up priority

1. Bound throughput diff selection in SQL. This is an obviously correct,
   contained fix for the only 16 GiB-plausible audited allocation.
2. Add durable performance-memory high-water events so an OOM leaves evidence.
3. Bound `GitRunner#run` output and stream cache-size traversal as defense in
   depth.
4. Add byte ceilings to bulk FTS writers based on real retained-event/document
   size distributions rather than guessing a global content limit.
