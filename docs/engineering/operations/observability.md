# Observability operations

### On-demand process diagnostics (SIGUSR2)

Some questions can only be answered from inside a running process: what is on
its heap, why its memory grows, what it is holding. Syrus answers those with a
signal, not an endpoint.

**Why a signal.** The processes worth inspecting are Solid Queue workers, and
an HTTP endpoint executes in the web pod -- it would inspect the wrong process.
A pod also runs several Ruby processes (supervisor, runs worker, merges worker,
dispatcher), so the trigger has to address exactly one: several simultaneous
whole-heap walks are how you OOM a pod that is already near its memory limit.
A signal names a single pid, and sending one requires a shell in the container.
That is the access gate -- there is no port, no listener and no token.

**Usage.** Write a request file naming the diagnostic, then signal the pid:

```bash
kubectl exec -it <pod> -c syrus-worker -- sh
ps -eo pid,rss,args --sort=-rss | head        # pick the process
mkdir -p "$SYRUS_DATA_ROOT/diagnostics"
echo '{"kind":"heap_histogram","top_n":50}' > "$SYRUS_DATA_ROOT/diagnostics/request.json"
kill -USR2 <pid>
ls "$SYRUS_DATA_ROOT/diagnostics"/           # <kind>-<pid>-<timestamp>.<ext>
```

The signal says "go"; the file says what to do, because a signal carries no
arguments. The file is optional in the sense that a malformed or missing one
is not an error -- but it must name a `kind`, or the process logs the known
kinds and does nothing. One diagnostic runs at a time: a second signal while
one is in flight is ignored rather than stacking another heap walk.

Output is written next to the request and the path is logged. Retrieve it with
`kubectl cp`. Nothing is written to the database and nothing is exposed over
HTTP.

**Available kinds**, cheapest first:

| `kind` | Cost | Answers |
|---|---|---|
| `process_overview` | free | Something is wrong and I do not know what |
| `thread_backtraces` | free | What is this process doing right now? |
| `db_pool` | free | Are we starved of database connections? |
| `fd_table` | free | Are we leaking file descriptors? |
| `gc_stat` | free | Is this retention or heap bloat? |
| `heap_histogram` | seconds of pause | What is being retained? |
| `allocation_trace` | ~2x memory for a window | Which line allocates the leak? |
| `heap_dump` | expensive, risky | What is holding the references? |

Start with `process_overview`. It combines GC counters, shallow thread
backtraces, pool stats and a descriptor count in one capture, so triage does
not cost three signals; reach for the specific kinds once it points somewhere.

`thread_backtraces` answers the question behind every wedged worker and
stalled Run. It costs microseconds and pauses nothing, so take it twice a few
seconds apart: a thread stuck at the same frame is blocked, one that moved is
merely busy. `depth` defaults to 40, max 200. Note `status` is reported
verbatim because its encoding matters -- `"run"`/`"sleep"` are alive, `false`
means the thread finished normally, `nil` means it died on an exception.

`db_pool` exists because connection starvation and slow queries look identical
from the outside: requests take seconds while the database sits idle. The
difference is `waiting`. If threads are queued for a connection, no query
optimisation will help and the pool size or thread count is the thing to
change.

`fd_table` classifies `/proc/self/fd` by socket, pipe, anon_inode, device and
file, and lists the most repeated targets. Descriptor leaks cause mysterious
intermittent failures long before the limit is hit, and nothing else reports
them. Linux only; on other platforms it reports `available: false` rather
than guessing.

`allocation_trace` turns "we are retaining String" into a source location. It
records an allocation site on every object allocated while tracing is on, runs
for `seconds` (default 30, max 300), then reports the sites whose objects
*survived* the window -- which is what a leak looks like. It roughly doubles
memory while active, so it carries the same refusal threshold as `heap_dump`
and always stops, including on error.

`gc_stat` reads counters only. Rising `heap_live_slots` alongside rising RSS
means objects are still reachable -- a leak. High RSS with flat live slots
means the heap simply is not being returned to the OS, which is a different
problem with a different fix.

`heap_histogram` walks every live object once, reporting per-class counts and
retained sizes (`top_n`, default 50, max 500). It includes the `gc_stat`
counters, so one capture answers both questions.

`heap_dump` writes the full object graph via `ObjectSpace.dump_all`. It is
**refused above 75% of the cgroup memory limit**: the dump allocates while it
writes, so taking it on a nearly-full pod kills the process holding the
evidence. Restart the worker to make room, or override with
`{"kind":"heap_dump","force":true}` when you have deliberately made space. The
output is several times the size of the heap and is written raw then
compressed, so the volume needs room for both.

**Adding a diagnostic.** Register a block with
`Diagnostics::SignalTrigger.register("my_kind") { |request| ... }` and return
either a Hash (written as pretty JSON) or a path you wrote yourself. The
request exposes `options` (the parsed file), `path_for(extension)`, and
`fetch_integer`. New diagnostics need no new signal -- that is why there is
only one.
