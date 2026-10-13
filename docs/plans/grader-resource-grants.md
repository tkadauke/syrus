# Grader Resource Grants

A grader has to choose its own parallelism before it starts. `parallel_rspec`
needs `-n <k>` on the command line; there is nothing to measure yet. Syrus
currently answers that question with a guess, and separately enforces a memory
ceiling derived from a different calculation. This plan replaces the guess with
a declared request and a resolved grant, and makes the enforcement layer read
the same grant the grader read.

## The problem

`RunProcessParallelism#call` is the whole of the current answer:

```ruby
[ cpu_budget / reserved_grader_slots, 1 ].max
# reserved_grader_slots = [ concurrent_grader_count, configured_job_concurrency ].max
# configured_job_concurrency = ENV["JOB_CONCURRENCY"] || 3
```

On a 10-CPU worker running a single rspec grader this yields `8 / 3 = 2`. The
divisor is a *presumed* worker width, not an observed one: the suite runs at
parallelism 2 whether or not two other graders exist. That single constant is
why the rspec suite takes about an hour on this repository instead of the ~8
minutes its shard count allows.

The reservation is not arbitrary — several grader Runs can be claimed by one
threaded Solid Queue worker before any of them registers a `SpawnedProcess`,
and without the reservation each would claim the full host. The defect is the
remedy, not the concern: it pays the worst case unconditionally.

Meanwhile `SpawnedProcessCgroupBudget` computes a memory ceiling from its own
fair-share model (`reservable_memory_bytes / concurrent_slots * admission_units`),
with `admission_units` a per-policy constant — `Agentic` 2, `Grader` 1. So the
number the grader uses to size itself and the ceiling it runs under come from
two unrelated calculations over the same host. Two allocators, one resource.

## The model

Four roles, and only one of them allocates.

**Request** — what a grader declares, ahead of time, in `.syrus.yml`. "I can
productively use 8 cores and I need 6 GB at that width." A request is a claim
about the work, authored next to the command, and it is *not* a reservation.

**Grant** — what the worker actually hands out at spawn, resolving the request
against host capacity and what live spawns already hold. The grant is the sole
allocator. It is deterministic given (run, host state), so every reader
computes the same number rather than threading an object through the spawn path.

**Enforcement** — the per-spawn cgroup makes the grant true even for a process
that ignores it. `SpawnedProcessCgroup` already does this for memory; CPU is
the gap.

**Feedback** — `cpu.stat` (`usage_usec`, `nr_throttled`, `throttled_usec`) and
`memory.peak` are already sampled at exit. Compared against the grant they say
whether a request was mis-sized: throttled for most of its wall clock means
under-granted, 1.4 cores used of 6 means over-granted. Feedback tunes default
requests. **It never decides admission.**

That last line is the load-bearing one. Admitting work on observed headroom
(PSI, load average, free memory) while also handing out grants gives two
allocators with incompatible models: headroom admission implicitly permits
overcommit and assumes it can react, grant admission forbids it up front. They
will disagree, and the disagreement is not resolvable at runtime. Measurement
gets exactly one veto, and it is not allocation: refuse new admissions while
the host is already in distress. That is a safety valve for the case where the
accounting is wrong, which it periodically will be.

## Two invariants

**A resource request must not enter the grader fingerprint.**
`GraderConclusionCache.fingerprint_for_graders` hashes name, command, phases,
required, timeout, `when_files_changed`, deps, `junit_output`, `failures` and
`metadata`. A resource request changes how fast a grader runs, never what it
asserts, so hashing it would invalidate every cached landing validation on a
parallelism tweak and discard green grades for no reason. Hence a dedicated
`GradeStep#resources` field, deliberately excluded from the fingerprint —
*not* a `metadata` key, which is hashed.

**The grant must reach the command through the environment, never the command
string.** The command text is fingerprinted. `parallel_process_setup` already
reads `${SYRUS_PROCESS_PARALLELISM}` at runtime and clamps it, so a grant that
varies by host leaves the command byte-identical. Baking `-n 8` into the
command would make the fingerprint host-dependent and break carry-forward
across workers of different sizes.

## Increment 1 — declare, grant, consume

1. `resources:` on a grade step parses to a `GraderResourceRequest` value
   object: `cpu` (max useful parallelism), `memory` (working set at that
   width), `cpu_min` (below which the grader would rather wait). All optional;
   an absent key means "no opinion" and keeps today's behavior.
2. The request rides `SyrusYml::GradeStep#resources` →
   `RepoGradePlan::Grader#resources` → `Steps::GraderFanout#grader_details`
   → `step.details["resources"]`, the same path `capabilities` takes. Snapshot
   at materialize time, immutable for the Step.
3. `GraderResourceGrant.for(run:, request:)` resolves `cpu_cores` and
   `memory_max_bytes` against host capacity minus live claims. Live claims are
   summed from what concurrent spawns were *granted*, not counted as slots —
   that is the fix for the divisor.
4. `Steps::Grader#env` exports the grant's `cpu_cores` as
   `SYRUS_PROCESS_PARALLELISM` in place of `RunProcessParallelism.for`.
   `RunProcessParallelism` stays as the host-capacity probe it also serves for
   `RunHostAdmission` and the cgroup budget; only the per-run divisor path goes.
5. `Ruby::RspecGraderType` declares a default request so the repository benefits
   without editing `.syrus.yml` per grader.

## Increment 2 — enforcement, and one allocator

Memory is done: `SpawnedProcessCgroupBudget` prefers a declared
`resources.memory` over its own fair-share estimate, capped by the same pod
fraction, and reports `source: "declared"`. A grader that has said what it
needs is no longer second-guessed by an estimate — the memory half of the
two-allocator problem, closed. The budget keeps its `Policy` registry, which
becomes the source of *default requests* for spawn kinds with no `.syrus.yml`
to declare one (agentic steps, chat agents) rather than a parallel allocator.
All of it sits behind `per_spawn_resource_limits`, which defaults off:
enforcement is wired but not enabled.

CPU, still outstanding, and blocked on infrastructure rather than code:
`SpawnedProcessCgroup` writes no `cpu.max` at all today. Worker pods also
declare no CPU quota, so `RunProcessParallelism.cgroup_v2_cpu_count` finds
`cpu.max == "max"` and falls through to `Etc.nprocessors`, which reports the
node's CPUs rather than the pod's share. Enforcing a per-spawn `cpu.max`
against a budget derived from node CPUs would hand out more than the pod can
deliver, so the pod manifests need `resources.limits.cpu` before the grant's
`cpu_cores` can become a real ceiling. Until then the CPU grant is advisory:
a cooperating grader honors it through `SYRUS_PROCESS_PARALLELISM`, and one
that ignores it is unconstrained.

## Increment 3 — feedback

Record grant-vs-actual per spawn and surface requests that are consistently
wrong: throttled share of wall clock, peak memory as a fraction of the ceiling,
granted cores versus cores actually used. Operator-facing, advisory. A later
pass may propose request edits; nothing here changes admission.
