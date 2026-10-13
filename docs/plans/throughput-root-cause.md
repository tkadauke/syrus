# Throughput Root Cause: Where The Time Actually Goes

Syrus's promise is that it saves the operator time, tokens, and attention. As
measured on 2026-10-13 it does none of those. An `initial` workflow — one
labeled issue to one open PR — takes **60 to 129 minutes**. An interactive
agent does the same work in a fraction of that, and the operator who stops
watching Syrus pays for it later in failed trains and re-grades.

This document measures where the time goes, root-causes each component, and
proposes an ordered plan. Everything here is measured from production on
2026-10-13, not inferred.

## The headline timeline

`WF-50680`, trigger `initial`, 140 steps, **129 minutes** wall clock. `t+` is
minutes from the first run starting. `cpu_min` is summed run time across all
runs in that group; `span_min` is wall time from first start to last finish.

| t+ | Step | n | cpu_min | span_min |
|---|---|---|---|---|
| 0.0 | prepare | 1 | 4.0 | 4.0 |
| 4.0 | **implement** (iter 1) | 1 | **16.5** | 16.5 |
| 20.5 | adversarial_review | 1 | 2.4 | 2.4 |
| 29.7 | implement (iter 2) | 2 | 7.9 | **44.7** |
| 34.1 | visual_review + format | 2 | 0.6 | 0.6 |
| 34.7 | grader_fanout (iter 1) | 1 | **8.5** | 8.5 |
| 43.3 | **grader (iter 1)** | **63** | 242.3 | 27.3 |
| 70.7 | grader_collect (iter 1) | 1 | 0.2 | 0.2 |
| **98.4** | format (iter 2) | 1 | 5.0 | 5.0 |
| 103.4 | grader_fanout (iter 2) | 1 | 6.1 | 6.1 |
| 109.6 | **grader (iter 2)** | **61** | 120.5 | 15.8 |
| 125.4 | grader_collect (iter 2) | 1 | 0.9 | 0.9 |
| 126.4–128.3 | coverage_analyze, dependency_audit, summarize, test_plan, pr_open, post_implementation_review | 6 | 1.9 | 1.9 |

**The actual implementation work is 16.5 minutes.** The other 112 minutes are
overhead. Three things stand out and each is root-caused below:

- a **27.7-minute hole** between `grader_collect` finishing at t+70.9 and
  `format` iter 2 starting at t+98.4, during which nothing ran;
- **iteration 2 re-ran 61 of the 63 graders**, costing 120 cpu-minutes to
  re-confirm results it already had;
- `grader_fanout`, which only materializes Step rows, took **8.5 and 6.1
  minutes**.

## Root cause 1 — Queue latency, not compute (the largest single cost)

Across `WF-50680`'s 144 runs, **815.9 run-minutes were spent queued**, waiting
between the run being created and the run starting. The worst offenders:

| Run created at | Step | Queued for |
|---|---|---|
| t+74.4 | format (iter 2) | **24.0 min** |
| t+43.4 … t+45.3 | grader (iter 1), top 9 of 63 | **15.7 – 17.7 min each** |

This reframes the whole timeline. The grader iteration-1 "span" of 27.3
minutes is mostly **waiting**, not executing — the graders were created at
t+43.4 and most did not start until t+60 or later. And the 27.7-minute hole
is simply `format` iter 2 sitting in a queue for 24 minutes.

Meanwhile, measured over the same window, live compute workers ran at **156%,
119%, 108%, 102%, 84% and 66%** utilization, with a seventh pod at 4%. Work
was waiting while capacity was idle. That is a scheduling failure, not a
capacity failure, and it is the single biggest lever in this document.

The delays are hard-coded constants, none of them adaptive and none exposed to
operators:

- `RunHostAdmission::RETRY_DELAY = 30.seconds`, with
  `RunJob::PINNED_HOST_ADMISSION_DEFERRAL_BUDGET = 40` — up to ~20 minutes of
  deferral on a pinned host before falling back.
- `WorkflowAdmissionBudget::SOFT_DELAY = 10.minutes`.
- `StepDispatcher::START_BLOCKED_BACKOFF = 5.minutes` and
  `PHASE_ADMISSION_RECHECK_DELAY = 10.minutes`.

A run deferred one second before capacity frees still waits the full fixed
interval. With 63 graders fanned out at once, those intervals compound into
the 15–18 minute startup latency measured above. Solid Queue itself is not the
problem — the `runs` queue polls at 0.1s.

**Fix direction.** Admission deferral must be event-driven, not timer-driven:
when a run completes and frees capacity, wake the deferred queue immediately
rather than letting deferred runs re-poll on a 30-second-to-10-minute
schedule. Failing that, the intervals must at minimum back off from a much
smaller floor and be operator-tunable. Expect this alone to remove tens of
minutes from a typical workflow.

## Root cause 2 — Iteration 2 re-runs graders that already passed

`SyrusYml` defaults `rerun_only_failed` to **`false`**
(`app/services/syrus_yml.rb:497,505`), and there is no `AppSetting` override —
unlike `grade_max_iterations`, which has one. Syrus's own `.syrus.yml` does not
set it, so Syrus runs with the default.

`Steps::GraderFanout#call` only carries a passing grader forward when
`plan.rerun_only_failed? || retrying_transient_only_failure? ||
retrying_no_change_repair?`. After an ordinary repair that changed code, none
of those hold, so **every grader re-runs**.

Measured across 24 hours of production:

- 1543 grader steps, of which **305 (19.8%) were iteration ≥ 2**, reaching
  iteration 4.
- Of 62 grader loops, 11 went past iteration 1.
- In those loops, **151 already-passing graders re-ran on iteration 2 against
  only 47 genuinely-failed ones** — 76% of iteration-2 grader work was
  redundant.

`WF-50680` is the concrete case: 63 graders in iteration 1, 61 in iteration 2,
120 cpu-minutes spent re-confirming.

Two further carry-forward gaps compound this:

- Optional (non-`required`) graders are **never** carried forward, even with
  `rerun_only_failed: true`
  (`Steps::GraderFanout#partition_rerun_only_failed_graders`).
- A `TargetHealthReuse` miss forces a re-run of an otherwise eligible grader,
  so any incidental fingerprint drift defeats carry-forward.

**Fix direction.** Default `rerun_only_failed` to `true`, add an `AppSetting`
for it, extend carry-forward to optional graders, and make a
`TargetHealthReuse` miss log *why* it missed so drift is diagnosable rather
than silent. A grader that passed against an identical target fingerprint must
not run twice.

## Root cause 3 — The suite is slow, and it runs more than once

24 hours of grader time, split by repository:

| Repo | Runs | Total grader hours |
|---|---|---|
| syrus | 1186 | **36.1** |
| raytracer | 70 | 11.8 |
| homeassistant | 7 | ~0 |

Syrus's worst graders by total cost:

| Grader | n | avg | total |
|---|---|---|---|
| `rspec` | 24 | **26.8 min** | 10.7 h |
| `rspec-ci` | 9 | **42.0 min** | 6.3 h |
| `work-engine-simulations` | 19 | 17.8 min | 5.6 h |
| `react-tests` | 13 | 10.9 min | 2.4 h |
| `e2e` | 7 | 10.4 min | 1.2 h |

`rspec` + `rspec-ci` is **17 of 36.1 hours — 47% of all Syrus grader time**.
Against the standard that rspec over five minutes is defeat, a 26.8-minute
average is five times over, and `rspec-ci` at 42 minutes is eight times over.

An earlier draft of this document claimed the suite runs two or three times
per landing. That was wrong and is retracted: across 107 grader loops, **zero**
ran both `rspec` and `rspec-ci`. 22 ran only `rspec`, 1 only `rspec-ci`. The
phase split works — `rspec` serves landing/promotion, `rspec-ci` serves the CI
phase, and a grader type materializes one way per loop. The 17 hours is many
different workflows, not one workflow paying repeatedly. What survives is
simply that the suite is five to eight times over the five-minute bar.

**Already landed and unverified.** Two fixes shipped in the last 72 hours:
shard balancing by recorded runtime (`9bb8e5c20`, `3f0c6a4ee`) and the
per-grader CPU grant (`62329bcc8`), which raised rspec's parallelism from 2 to
a measured 7 of 11 cores. Post-deploy there is exactly **one** rspec sample
(57.2 min) and one `rspec-ci` sample (4.7 min) — **n=1 each, which proves
nothing in either direction.** The first task in the plan below is to measure
this properly rather than assume today's work fixed it.

**Still open.** CPU grants are advisory: `SpawnedProcessCgroup` writes no
`cpu.max`, and worker pods declare no `resources.limits.cpu`, so
`RunProcessParallelism` divides up node CPUs rather than the pod's share. The
hosts observed reporting 8, 11 and 16 CPUs are reporting the node, not
themselves.

## Root cause 4 — Uneven worker utilization

Measured over the 2.88-hour window since all pods restarted together:

| Host | grader spawns | busy minutes | utilization |
|---|---|---|---|
| compute-4gpwt | 29 | 268.6 | **156%** |
| compute-x2tkw | 32 | 206.0 | 119% |
| compute-fvsl2 | 80 | 185.7 | 108% |
| compute-p59xh | 75 | 176.8 | 102% |
| compute-h5pq7 | 27 | 145.0 | 84% |
| compute-kptt5 | 42 | 114.3 | **66%** |
| compute-cszrm | 1 | 6.2 | **4%** |

(Over 100% means concurrent graders on one host.) A **2.4× spread** across
live workers, with runs queueing 15–18 minutes at the same time. Note also
that spawn count and busy time are badly correlated — 29 spawns produced more
busy time than 80 — so whatever placement is happening is not accounting for
job weight.

## Root cause 5 — `grader_fanout` costs 6–8 minutes

`grader_fanout` materializes Step rows and computes fingerprints. It took 8.5
and 6.1 minutes in `WF-50680`, which is 11% of the workflow's wall clock spent
on bookkeeping. This needs profiling before proposing a fix; the candidates
are target-graph compilation, fingerprinting across 63 targets, and the
workspace/overlay setup it performs. Unmeasured as yet — do not guess.

## Root cause 0 — The fixes are built and switched off

This outranks everything above, and it was found last.

Measured in production on 2026-10-13, while the work was marked complete:

| Switch | State | Status of the work |
|---|---|---|
| `grader_fanout_overlay` | off | Epic #408, done 1/1 |
| `per_spawn_resource_limits` | off | Epic #405, done 2/2 |
| `landing_validation_prefetch` | off | shipped |
| `grade.rerun_only_failed` | `false` default, no AppSetting | shipped, tested, inert |
| `user_daily_spend_budget_usd` | `0` = no cap | `Admission::SpendBudget` shipped |

Commit `34dcf1445` is the same shape in code rather than config: it added
grader carry-forward across iterations and gated it on
`!code_changing_repair_for_this_iteration?`, so it cannot fire after a repair
that changed code — which is every repair that did anything. Built, merged,
dead.

**Syrus's definition of done stops at "merged".** Nothing reconciles "we built
X" against "X is enabled in production", so an Epic closes 5/5 with its
feature dark. Every throughput complaint above is downstream of this: the
overlay that would stop per-grader copying, the cgroup limits, the
carry-forward and the prefetch were all off.

### And enabling them is not sufficient

All three flags were turned on during this investigation. Two still do
nothing, for the same reason:

```
grader_fanout_overlay      -> "overlay mount failed: must be superuser to use mount."
per_spawn_resource_limits  -> "worker cgroup is not delegated for child cgroup creation"
                              cgroup states: unavailable=265, applied=0
```

The worker container runs unprivileged as UID 1000. It cannot call `mount(2)`
and cannot create child cgroups. Both features detect this, record the reason
and fall back correctly — the code is fine and cannot work in this pod spec.

So one change to the worker pod manifest, outside this repository, unblocks
three separate pieces of already-built work: mount capability for the overlay
(Epic #408), cgroup delegation for the memory limits (Epic #405 and the
declared-working-set commit), and `resources.limits.cpu` so CPU grants divide
the pod's share rather than the node's. That manifest change is currently the
highest-leverage item in this entire investigation.

**The lesson for process, not code:** a feature flag that has been off since
it shipped is not a safe default, it is unfinished work with no owner. An Epic
should not close while its flag is off, and any change landing behind a
disabled switch must say so in the delivery report, not only the commit body.

## Cross-check against work already in flight

This plan deliberately does not restate work that is already moving.

**Already landed, needs verification not repetition:** RSpec shard balancing by
runtime (`9bb8e5c20`, `3f0c6a4ee`, closing #4904), the overlay-backed grader
fanout that stopped copying `vendor/bundle` per grader (Epic #408), per-spawn
cgroup memory limits (Epic #405), and the CPU/memory grant work
(`62329bcc8`, `1b8d17270`, `docs/plans/grader-resource-grants.md`).

**Open and directly on-topic — build on these, do not duplicate:**

- **#85 "Polling tier has no rate-limit budget or backoff"** — names the
  5-minute latency floor operators experience as "Syrus is slow". Adjacent to
  root cause 1 but about the polling plane rather than run admission.
- **#4649** — `main_grader` for one repo re-firing every 5 minutes after a
  non-retryable failure, 9,822 rows of `SolidQueue::FailedExecution`. A live,
  unfixed retry loop.
- **#93** — per-user fairness; partially addressed by `Admission::FairShare`
  and `Admission::SpendBudget` (both default off). Check whether this should be
  closed rather than restated.
- **#4926** — per-repository merge-train escalation ladder: today a failed
  train tears down and fully regrades every member, discarding every fix the
  attempt produced.
- **#972** — classify retryability and pause operator-required blockers.
- **#90** — full Rails boot per Run to expose one MCP tool, on the hot path.
- **`docs/plans/production-performance-load.md` M1–M6** — web/worker CPU
  isolation, queue-role pod splitting, Action Cable fix, poller churn
  reduction. No matching recent commits; still largely open and the closest
  existing plan to root causes 1 and 4.
- **`docs/plans/workflow-engine-v3.md`** — names "no backpressure, only
  concurrency limits" as blind spot #4 and "cost is observed, never enforced"
  as #5.

**New, filed today:** #5029, incremental polling permanently missing issues
labeled during an ingestion gap.

## The plan, in order of measured return

**P-1 — Give the worker pods the privileges their features need.** Mount
capability, cgroup delegation, and `resources.limits.cpu` on the worker pod
manifest. No Syrus code involved; unblocks three pieces of shipped work. Do
this first because everything else competes with it for the same wall clock.

**P0 — Stop re-running passing graders.** `rerun_only_failed` now defaults to
`true`. Note that this needs a deploy to take effect, and that a repository
whose `.syrus.yml` uses the bare-array form of `grade:` cannot set the key at
all — the array branch has no slot for it — so such a repository depends
entirely on the default.

Two deliberate restrictions remain, each a decision rather than a bug:

- Optional graders are never carried forward. `26d85b06b` scoped carry-forward
  to required targets and its message does not say why; the reuse gate itself
  does not distinguish required from optional, and
  `spec/services/steps/grader_fanout_spec.rb` pins the exclusion explicitly.
  If the exclusion was conservatism rather than correctness, lifting it
  removes another slice of per-iteration waste. Decide it deliberately.
- `34dcf1445`'s `!code_changing_repair_for_this_iteration?` guard still
  disables reuse after any code-changing repair. The right replacement is to
  re-run only graders whose *target fingerprint* changed — machinery that
  already exists in `TargetGraph::Fingerprints.for_target` — rather than all
  of them.

Acceptance: on a loop reaching iteration 2, the graders run equal those that
failed in iteration 1 plus any whose target fingerprint genuinely changed,
asserted by a spec and verified in production on the next multi-iteration
loop.

**P1 — Make admission event-driven.** A completing run must wake deferred runs
immediately instead of leaving them on a 30-second-to-10-minute timer. Expose
the intervals as settings. Acceptance: median run queue latency under 30
seconds; no run waits more than 2 minutes while any worker is below 80%
utilization. Measure before and after with the query used for this document.

**P2 — Verify, then finish, the rspec work.** Collect at least 10 post-grant
rspec samples and state the real number. If the suite is still over five
minutes, the next steps are already identified: pod `resources.limits.cpu` so
grants mean something, `cpu.max` enforcement in `SpawnedProcessCgroup`, and a
decision about whether `rspec-ci` and `work-engine-simulations` need to be
separate full-suite executions at all. Acceptance: landing-phase rspec under
five minutes, or a written explanation of the specific physical limit that
prevents it.

**P3 — Weight-aware placement.** Placement currently ignores job weight; 29
spawns outworked 80. Use the resource grant already attached to each grader as
the placement weight. Acceptance: utilization spread across live workers under
1.3×, no worker below 50% while any run is queued.

**P4 — Profile `grader_fanout`.** Six to eight minutes of bookkeeping per
iteration is 11% of a workflow. Measure first, then fix. Acceptance: under 30
seconds.

**P5 — Treat every hiccup as a bug.** The standing policy from here: a second
grader-loop iteration is a defect to investigate, not normal operation. That
requires the iteration to be *attributable* — `GraderLoopProgress` already
records the failing set, so surface "why did this loop iterate" as a
first-class, queryable field, and alarm on iteration ≥ 2 rather than only on
no-progress. Today 19.8% of grader steps are iteration ≥ 2 and nothing
reports it.

## How to re-measure

Every number in this document came from `bin/rails runner` against the
production web pod. The useful ones, for re-running after each change:

- grader cost by name and repo: group `Step.where(kind: "grader")` by
  `details["name"]` and the owning repository, summing `details["duration_s"]`.
- loop waste: group grader steps by `loop_id`, compare the set of graders that
  succeeded in iteration 1 against the set run in iteration 2.
- queue latency: for a workflow's runs, `started_at - created_at`.
- worker utilization: `SpawnedProcess` grouped by `hostname`, summing
  `finished_at - started_at`, over a window where all pods have equal uptime.

Note when querying: the column is `issue_number`, not `github_issue_number`;
app telemetry floods stdout, so mark output with a prefix and `grep -a` for it.
