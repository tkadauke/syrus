# September 13 Production Bugs

This is a live bug ledger for the September 13 production incident sweep. The
job/workflow IDs are internal operator evidence and should stay in this plan,
not product docs or user-facing copy.

## Open bugs

### Grade loop can advance past an incomplete grader barrier

**Symptom:** JOB-4791 / WF-28197 has a retry workflow where the second grade
loop is not complete, several grader steps have failed, and the
`grader_collect` step is still queued, but later workflow steps already ran.

**Evidence:** In WF-28197, the second fanout created grader steps at positions
11-21. Multiple grader steps failed, and the second `grader_collect` at
position 22 remained queued with no run. Despite that, `coverage_analyze`,
`dependency_audit`, and `summarize` all succeeded, and `test_plan` was queued.

**Expected:** Steps after a grader fanout must wait for the matching
`grader_collect` barrier to finish. A failed or queued collector must prevent
coverage, dependency audit, summarize, test plan, PR opening, and later
publication steps.

**Suspected cause:** The retry-loop advancement path is still treating the
linear step order as sufficient, or a failed individual grader is invoking
normal next-step advancement instead of waiting for the collector. Parallel
grader steps need explicit barrier semantics: only `grader_collect` should
advance the workflow after fanout.

**Fix direction:** Make individual `grader` steps terminal leaves. They should
record their result and wake or enqueue the collector, but never enqueue
post-loop steps directly. Add a regression simulation where parallel graders
include a mix of slow, failed, and succeeded results and prove no later step
starts before collector completion.

**Simulator coverage:** `parallel_grader_retry_blocks_tail.yml` and
`serial_grader_retry_blocks_tail.yml` cover stale dirty retry-until barriers
and assert the post-loop tail does not run.

**Fixed:** Workflow finalization now refuses to mark a workflow succeeded if
the latest required retry-until barrier for any loop is not `succeeded`. This
protects historical leaked-tail shapes where post-loop steps already reached
terminal success before the dirty barrier was noticed. Covered by
`spec/services/step_dispatcher_spec.rb` and
`spec/services/run_completion_reconciler_spec.rb`.

### Retry loop tail steps can succeed while later repair iterations are still failing

**Symptom:** JOB-4790 ran five grader-loop attempts with different grader sets
and different failures each time. The overall job still reached `implemented`
with a PR, even though the final grader loop did not pass.

**Evidence:** JOB-4790 / WF-28182 is `succeeded` and the job is `implemented`
with PR #3706. Inside the same workflow, the first `grader_collect` failed at
position 13, but `coverage_analyze`, `dependency_audit`, `summarize`,
`test_plan`, and `pr_open` at positions 57-61 all eventually succeeded. Later
repair iterations also ran: collectors failed at positions 17, 30, and 43; the
final fanout at position 45 had failures in `migration-lint`, `feature-slugs`,
`plugin-boundaries`, and `production-build-boot`, plus a cancelled
`work-engine-simulations` grader and a cancelled collector. That final failing
barrier did not prevent the workflow from being marked successful.

**Expected:** A retry-until loop has exactly one authoritative terminal result:
the latest collector. The workflow may advance only after a collector succeeds.
If the last collector fails, is queued/running, or is cancelled, the workflow
must remain failed/running and must not mark the job implemented.

**Suspected cause:** The original tail steps remained part of the static
workflow chain and were already reachable after an earlier failed collector,
while subsequent repair iterations were appended later. The dispatcher appears
to allow two futures for the same retry loop: tail continuation and repair
continuation. Once any tail path succeeds, workflow success can mask later loop
failure.

**Fix direction:** Treat retry-until as a structured control-flow block, not a
linear sequence with appended repair steps. A failed collector should enqueue
the repair iteration and explicitly keep the post-loop tail blocked. When a
new repair iteration is created, any previously queued/running/succeeded tail
steps that depended on an uncleared collector should be invalidated or ignored
for workflow completion. Add a simulator scenario with repeated mixed grader
failure sets and assert that `pr_open` cannot run unless the final collector
succeeds.

**Simulator coverage:** `parallel_grader_retry_blocks_tail.yml` covers the
blocked-tail half; `parallel_grader_retry_cleared_barrier_allows_tail.yml`
guards the opposite case, where a later collector succeeds and the tail must
be allowed to continue even if an older collector failed.

**Fixed:** The workflow success path now keys retry-until barrier cleanliness
by `loop_id` and authoritative latest barrier position, so a later successful
collector clears an earlier failed collector, but a latest failed/cancelled
collector prevents workflow success.

### Same grade-loop leak produces inconsistent job outcomes

**Symptom:** JOB-4944 also leaked past repeated grader-loop failures, but its
final outcome differs from JOB-4790: the tail steps all succeeded and opened a
PR, then the workflow and job ended failed.

**Evidence:** JOB-4944 / WF-28156 failed collectors at positions 15, 28, 34,
and 39. Despite those failed collectors, `coverage_analyze`,
`dependency_audit`, `summarize`, `test_plan`, and `pr_open` at positions 43-47
all succeeded, opening PR #3700. A later repair iteration then succeeded its
`implement` step, failed `grader_fanout` at position 41, cancelled
`grader_collect` at position 42, and the workflow/job ended failed. This is the
same underlying control-flow leak as JOB-4790, but the final state is different
because a later loop failure won the terminal race instead of the already-run
tail path. JOB-4941 / WF-28153 shows the same non-unique shape: collectors
failed repeatedly, `coverage_analyze`, `dependency_audit`, `summarize`,
`test_plan`, and `pr_open` still succeeded, then a later `grader_fanout` failed
and its collector was cancelled, leaving the workflow/job failed.

**Expected:** Jobs with the same failed retry-until outcome should converge to
the same state. Tail steps should not run before a successful collector, and a
PR opened from an uncleared grade loop should not be considered a valid
implemented state.

**Suspected cause:** Workflow completion is race-sensitive: whichever branch of
the leaked control flow updates the workflow last can determine whether the
job appears implemented or failed. The static tail path and appended repair
iterations are both live at the same time.

**Fix direction:** In addition to blocking tail advancement, add consistency
checks before workflow success and job implementation: require the latest
required grade-loop collector to be `succeeded`, and fail loudly if a workflow
has successful post-loop steps after a non-success collector. Add a data repair
or admin diagnostic for jobs with PRs opened from dirty grade loops.

**Fixed:** The success finalizer now turns this race into an explicit workflow
failure with `failure_reason = "uncleared_retry_until_barrier_after_success"`
instead of allowing race-sensitive `succeeded` vs `failed` outcomes.

### Merge train can land while grader repair iteration is still running

**Symptom:** JOB-4786 landed through a merge train while the active merge-train
workflow still had running, queued, and failing grader-loop steps.

**Evidence:** JOB-4786 is closed with `closure_reason = pr_merged`, and
WF-28203 is still `running`. In WF-28203, the first merge-train grader
collector failed at position 18 after multiple grader failures. A repair
iteration then created a second fanout at position 20. Its grader steps at
positions 21-29 were still mixed `running`/`queued`, and its collector at
position 30 was still queued with no run. Despite that dirty barrier,
`merge_train_land` at position 31 succeeded and closed the member job.

**Expected:** Publication steps are the strongest barrier consumers in the
system. `merge_train_land`, `auto_merge`, `external_pr_merge`, and push/merge
publication steps must be unreachable until the latest required grader
collector has succeeded. A running/queued/failed/cancelled grader iteration
must block publication.

**Suspected cause:** Same retry-until tail leak as JOB-4790/JOB-4944, now in a
publication workflow where the leaked tail is `merge_train_land`. The static
tail path was not invalidated when the first collector failed and appended the
repair iteration, so landing remained reachable while the repair iteration was
still active.

**Fix direction:** Add a hard publication preflight independent of dispatcher
ordering: before any publication step starts, assert all prior required
barriers for the workflow are clean and that no earlier step in the same
workflow is `queued` or `running` unless it is explicitly non-blocking. Add a
parallel-grader simulation for merge-train landing where the first collector
fails, a repair fanout starts, and `merge_train_land` must not run until the
second collector succeeds.

**Simulator coverage:** `parallel_merge_train_blocks_dirty_publication.yml`
reproduces the dirty merge-train publication wakeup and expects deferred resume
to return `not_ready` instead of starting `merge_train_land`.

**Fixed:** Publication steps are still primarily blocked by dispatcher
readiness. As an additional backstop, a workflow cannot reach `succeeded`
after publication if any latest retry-until barrier remains dirty; the
terminal result becomes an explicit dirty-barrier failure instead.

### Branch-divergence banner can mix job commits with unrelated base commits

**Symptom:** JOB-4943 showed a "PR branch changed before this workflow could
push" banner with a suspiciously large number of commits on the local
"published by replacing" side.

**Evidence:** JOB-4943 / WF-28176 failed `pr_open` with
`Steps::PrOpen::BranchDiverged`. The remote branch was `1763948`; the local
branch was `8caa007`. The divergence artifact correctly showed the remote-only
job commits, but the local-only side included this workflow's job commits plus
unrelated mainline commits such as distributed-grader, main-fix, and work-slot
cleanup changes. The same retry workflow had already leaked past failed
collectors: `grader_collect` failed at positions 17 and 29, later
`coverage_analyze`, `dependency_audit`, `summarize`, and `test_plan` succeeded,
and `pr_open` failed only because the branch had diverged. Some grader steps
were still `running` with cancelled runs after terminal failure.

**Expected:** The stale-output UI should distinguish "new base commits included
by a clean rebase" from "commits this stale workflow would publish." The
operator should not have to infer which commits are unrelated main movement.
Also, `pr_open` should not execute after an uncleared grade-loop collector.

**Suspected cause:** The divergence comparison likely compares
`remote_sha..local_sha` directly after the local workflow branch has been
rebased onto a newer base. That makes base commits look like local workflow
output. The underlying control-flow leak is the same retry-until barrier bug
tracked above.

**Fix direction:** For branch-divergence diagnostics, compute local-only job
output relative to the workflow's original base and/or patch-id, and display
rebased base commits separately. Keep the destructive "replace PR branch"
button focused on actual job output. Add a regression test where a stale
workflow branch is rebased over new main commits before push fails, and assert
the banner does not present those base commits as workflow-owned changes.

**Fixed:** `Steps::PrOpen` now summarizes the "published by replacing" side
against the workflow workspace base ref instead of `remote_sha..local_sha`.
That keeps unrelated base commits brought in by a clean rebase out of the
operator-facing replacement list while retaining the remote-only discarded
commit summary. Covered by `spec/services/steps/pr_open_spec.rb`.

### Checkpoint resume can bypass an uncleared grade loop

**Symptom:** JOB-4947 ended up `implemented` with a PR even though its original
initial workflow never produced a clean grader pass.

**Evidence:** JOB-4947 / WF-28159 failed after multiple grade-loop attempts.
The first collector failed, a repair ran, the second collector failed while one
grader step remained `running` with a cancelled run, and a third
`grader_fanout` was left `running` with a cancelled run while its matching
collector was cancelled. The same workflow then ran `summarize`, failed
`test_plan`, and cancelled `pr_open`. A later checkpoint-resume work unit
created WF-28173, which contained only `test_plan` (skipped) and `pr_open`
(succeeded). The job is now `implemented` without a completed successful grader
barrier.

**Expected:** Checkpoint resume must only resume from a workflow point whose
all prior mandatory gates are conclusively satisfied. A failed, running, or
cancelled grader fanout/collector pair should force a retry from the grade loop
or from the preceding repair step, never from `test_plan` or `pr_open`.

**Suspected cause:** The resume checkpoint selection is looking for the last
failed agentic/tail step and ignoring incomplete barrier groups behind it. Once
`test_plan` failed, the retry path treated `test_plan` as the failed checkpoint
even though the workflow's required grader gate was still dirty.

**Fix direction:** Add a "prior gates clean" invariant to checkpoint resume.
For any candidate resume step, scan earlier required barriers and reject the
checkpoint if a `grader_fanout`, `grader`, or `grader_collect` step is not
cleanly satisfied for the current loop iteration. Add a simulator scenario
where a grade loop is cancelled mid-fanout, a tail step fails, and retry must
return to grading instead of opening a PR.

**Simulator coverage:** `checkpoint_resume_rejects_dirty_grader_barrier.yml`
reproduces a failed tail after an uncleared grader barrier and asserts the
retry path falls back to a full implementation retry rather than checkpoint
resume.

**Fixed:** Checkpoint selection already rejects tail retries across dirty
barriers; workflow finalization now applies the same invariant at terminal
success so a resumed tail cannot silently bless an earlier dirty grade loop.

### Cancelled steps do not show why they were cancelled

**Symptom:** JOB-4946 has cancelled grade-loop/tail steps, but the Job UI does
not explain why those steps were cancelled.

**Evidence:** JOB-4946 / WF-28174 failed `migration-lint`; `grader_collect`
then failed with `required graders failed: migration-lint`. The work-engine
reconciler logged `fail_workflow_from_failed_step`, followed by
`cancel_terminal_workflow_active_descendants`, which cancelled the later
`implement`, `grader_fanout`, `grader_collect`, `coverage_analyze`,
`dependency_audit`, `summarize`, `test_plan`, and `pr_open` steps. The
cancelled Step rows have empty `details`, so the causal link is only visible in
logs, not on the step itself.

**Expected:** Every cancelled step/run should expose a concise cancellation
reason in the UI, for example "workflow failed from STEP-217628
(`migration-lint`)" or "cancelled because parent workflow reached failed".

**Suspected cause:** Cancellation is modeled as a state transition without a
durable cancellation reason on the cancelled descendants. The reconciler logs
the reason globally but does not stamp each cancelled step/run.

**Fix direction:** Add cancellation metadata to Step/Run details when bulk
cancelling descendants, including the actor/service, parent terminal state,
source failed step/run, and short human-readable reason. Render that reason in
the workflow step UI and include it in API payloads. Add a regression test for
`cancel_terminal_workflow_active_descendants` that asserts each cancelled
descendant carries the cause.

**Fixed:** `Workflow#cancel_active_descendants!` now stamps active Step
descendants with a concise cancellation reason and structured cleanup details,
including the terminal workflow state and source failed Step when available.
Run cancellation reason is captured through existing state-transition metadata
from the reconciler repair action. Covered by
`spec/services/work_engine/reconciler_spec.rb`.

### Control-plane steps are blocked by compute host pressure

**Symptom:** Landing and merge-train workflows can stop moving even after all
grader runs are terminal because `grader_collect` is repeatedly deferred by
host-pressure admission.

**Evidence:** WF-28203 had `grader_collect` queued while job logs repeatedly
said host admission deferred the collector due to `local_worker_pressure_critical`.
The collector is cheap Rails control-plane work, but it was classified under
the merge workflow's compute queue.

**Expected:** `grader_collect` and similar orchestration steps should run even
when compute hosts are saturated, unless the database or Rails process itself
is unhealthy.

**Suspected cause:** `RunHostAdmission` classifies by workflow template queue
(`merge_train` => `merges`) instead of the concrete step placement policy.

**Fix direction:** Base host admission on the run's concrete step placement.
`control_plane` steps should bypass compute host pressure and should not need a
pinned workspace host.

**Fixed:** `RunHostAdmission` now admits concrete
`Step::PlacementPolicy::CONTROL_PLANE` steps before applying compute-host
pressure guards. This lets cheap orchestration steps such as `grader_collect`
finish or fail workflows even while hosts are too pressured for agentic or
high-cost grader work. Covered by `spec/services/run_host_admission_spec.rb`.

### Main-branch graders compete with landing graders

**Symptom:** During landing pressure, main-branch health runs consume worker
capacity while the landing queue is stalled.

**Evidence:** Production had a main-grader workflow running
`work-engine-simulations` and `rspec-ci` while the active merge train was
waiting on grader collection and stale distributed graders. One worker host was
near 100% CPU from the main-grader work.

**Expected:** Landing-critical work should have priority over background
main-health grading when the cluster is saturated.

**Fix direction:** Add an admission priority policy: landing publication and
landing collectors first, active landing graders next, main-health and insight
work only when there is spare capacity.

**Fixed:** `RunHostAdmission` now makes background `main_grader`,
`main_branch_repair`, and `agent_insight` runs yield on warning-or-worse hosts
when active landing work exists for the same repository. Control-plane steps
still bypass host pressure, and landing graders do not yield to background main
health. Covered by `spec/services/run_host_admission_spec.rb`.

### Main-branch repair fanout can create duplicate all-grader failures

**Symptom:** JOB-4956, JOB-4955, and JOB-4949 were all main-branch repair jobs.
They consumed grader capacity while the branch was already broadly broken.

**Evidence:** JOB-4949 / WF-28163 failed every preflight grader, then ran
repair iterations that still failed many of the same graders. JOB-4955 and
JOB-4956 started later main-branch repair workflows; each failed some preflight
graders and cancelled many remaining preflight grader runs after the workflow
was already doomed. All three jobs are titled "Fix broken main branch" and all
failed on the same morning.

**Expected:** Main-branch repair should avoid fanning out duplicate expensive
repairs when there is already an active or recently failed repair for the same
base SHA/failure fingerprint. If the branch is catastrophically broken, Syrus
should run one repair owner and make later repair jobs wait, coalesce, or
attach as diagnostics instead of launching another full preflight fanout.

**Suspected cause:** Main-health failure detection creates independent repair
jobs per polling/insight cycle without coalescing by base revision and failure
set. Preflight fanout also does not stop early enough once enough required
graders have already failed to prove the preflight gate failed.

**Fix direction:** Add main-repair dedup/coalescing keyed by repository, base
SHA, and normalized failing test/grader fingerprint. While a repair for that
key is active or cooling down, do not launch another full repair. Add a
preflight cancellation policy that cancels outstanding preflight graders once
the required gate result is already terminal, but records that as intentional
short-circuiting rather than "all graders failed."

**Fixed:** Automatic main-branch repair creation now treats an open failed
repair Job for the current broken SHA as the blocker instead of spawning the
next repair until the default branch advances. Operators can still force a
manual repair, and stale failed repairs for older SHAs do not block a new
repair for the new default-branch tip. Covered by
`spec/services/main_health_changed_service_spec.rb`.

### Formatter-style checks are running as expensive graders

**Symptom:** JOB-4959 hit a grader timeout in a main-branch repair even though
the failing command was formatter-like and quickly fixable.

**Evidence:** JOB-4959 / WF-28188 failed all preflight graders for a Python
repository. After repair, the first post-repair grader loop timed out `usort`
after 5 minutes (`exit 124`) and failed collection on `usort`. The next repair
scoped the `usort` command to concrete Python source paths; the following
grader loop passed and opened the repair PR.

**Expected:** Formatting/order-only checks such as `usort`, `black`, and
similar deterministic tools should usually run as formatters before graders,
commit their changes, and only fail as graders when the repository explicitly
wants check-only behavior. A formatter timeout should be treated differently
from a semantic test failure.

**Suspected cause:** Some repository configs still model deterministic
formatters as required graders. Under immutable workspace preparation and
parallel fanout, that makes inexpensive formatting drift consume full grader
slots and fail/timeout like semantic tests.

**Fix direction:** Extend the grader/config model with clearer command roles:
formatter/autofix, generated, semantic grader, and check-only formatter. Teach
language plugins to synthesize formatter defaults where safe. In UI and
diagnostics, flag graders that look formatter-like and repeatedly fail with
autofixable output. Consider auto-suggesting config changes when a repair only
narrows or applies formatter output.

### Parallel immutable graders amplify IO pressure

**Symptom:** Parallel grader execution can make the cluster slower by starting
many full prepare/checkouts at once.

**Evidence:** Worker hosts showed critical IO pressure while only one landing
job was truly active. Several immutable grader runs shared the same merge-train
workflow but each paid expensive prepare/workspace cost.

**Expected:** Parallelism should reduce wall time without pushing all hosts
into critical IO pressure.

**Fix direction:** Reuse immutable prepared workspaces where safe, or split
prepare into one shared immutable workspace snapshot plus cheap per-grader
copies. Cap parallel grader fanout by current host pressure, not only by a
static repository setting.

### Prepared workspace snapshots for grader fanout

**Performance idea:** The `prepare` step should be able to publish a prepared
workspace snapshot that later grader steps can restore instead of repeating the
same checkout, bundle install, npm install, and other setup work.

**Proposed design:** After `prepare` succeeds, tar the prepared workflow
workspace, upload it to Active Storage (MinIO/S3 in production), and record the
blob key plus integrity metadata on the workflow. Use a short retention window,
initially 24 hours, because the artifact is only useful while a workflow and
its immediate retry/repair steps are active.

**Grader behavior:** Before a grader creates its local immutable workspace, it
should try to download and extract the prepared snapshot. If the snapshot is
present and validates, the grader runs from that restored workspace. If the
download, extraction, checksum validation, or Active Storage lookup fails, the
grader must fall back to the current behavior: create and prepare the workspace
locally on that worker. After a successful local fallback prepare, the worker
may attempt to upload/replace the prepared snapshot for later graders, but that
upload must be best-effort and must not fail the grader.

**Terminal cleanup:** When the workflow reaches a terminal state, delete/purge
the prepared workspace blob. Also keep a TTL sweeper so abandoned workflows or
missed terminal callbacks do not leak large archives in object storage.

**Safety constraints:** The snapshot must be scoped to one workflow/base
checkout and must not be shared across unrelated workflows unless we later add
content-addressed cache keys with strong invalidation. Restore should verify
the expected commit SHA, repository identity, `.syrus.yml` digest, and archive
checksum before use. Secrets and per-run agent temp files must not be included
in the archive.

**Expected impact:** Parallel graders stop multiplying the expensive prepare
cost across worker hosts. This should reduce IO pressure and wall time most for
workflows with many graders and heavyweight dependency installs.

### Stale distributed grader runs delay workflow completion

**Symptom:** Runs can remain `running` with stale heartbeats while no useful
child process is visible, keeping collectors and landing workflows waiting.

**Evidence:** WF-28203 had stale `work-engine-simulations`,
`production-build-boot`, and `website-build` grader runs. Some hosts showed
critical pressure with no matching active child process.

**Expected:** A dead grader process should be detected quickly enough to unblock
the collector and trigger the normal retry or failure path.

**Fix direction:** Reconcile run heartbeats against the worker process table and
expected command metadata. Mark dead runs failed with a retryable failure when
the process is missing or the PID now belongs to another command.

**Fixed:** The WorkEngine reconciler no longer treats stale unfinished
`SpawnedProcess` rows as proof that a running Run still has live worker
evidence. If the Run heartbeat is stale and the only matching grader/agent
process row is also stale, the existing worker-died repair path can fail and
retry the Run instead of waiting behind phantom process liveness. Covered by
`spec/services/work_engine/reconciler_spec.rb`.

### Distributed grader failures still surface as generic main breakage

**Symptom:** Some merge-train grader failures are real, but the operator only
sees broad "grader failed" state while the queue is blocked.

**Evidence:** Recent merge-train attempts showed `migration-lint`,
`migration-baselines`, `plugin-boundaries`, `rspec`, and `react-tests` failures.
At least one prepare failed in an immutable source checkout on `npm ci`.

**Expected:** The landing queue banner should distinguish "waiting for
collector", "active grader failures need repair", "host pressure", and "stale
run reaping" rather than compressing everything into a stuck landing state.

**Fix direction:** Promote collector/fanout status into the landing queue status
payload, including failed grader names, stale run count, and the current
admission blocker.

**Fixed:** The landing queue status payload now summarizes suspicious active
grader barriers instead of going silent whenever a landing workflow is merely
`running`. It reports collector progress, failed grader names, cancelled
grader count, and stale running grader count once the barrier has failures,
cancellations, stale runs, or has waited past the queue-starvation threshold.
Covered by `spec/services/app/dashboard_payload_spec.rb`.

### Sequence allocation can fail under concurrent work creation

**Symptom:** Some production failures included `Validation failed: Sequence has
already been taken`.

**Evidence:** This appeared during the Sep 13 landing sweep while multiple
grader and repair workflows were active.

**Expected:** Step/run/work-unit sequence assignment must be atomic under
parallel fanout and reconciler-created work.

**Fix direction:** Audit sequence allocation for retry loops and fanout steps.
Prefer database-backed atomic increments or retry-on-unique-violation around
the smallest creation transaction.

**Fixed:** `JobLog` already retried optimistic append collisions. The remaining
gap was command-span instrumentation: `GraderCommandSpans::Recorder` now
retries `CommandSpan` sequence collisions and records the span at the next free
sequence instead of failing the grader run. Covered by
`spec/services/grader_command_spans/recorder_spec.rb`.

### Rails process shutdown bookkeeping is slow

**Symptom:** Ad hoc Rails runners and app processes repeatedly log slow
`InstanceVersion Update All` shutdown updates.

**Evidence:** Multiple production runner probes emitted slow SQL events for the
same conditional `instance_versions` update, ranging from hundreds of
milliseconds to several seconds.

**Expected:** Instance-version heartbeat and shutdown bookkeeping should not add
noticeable latency or lock pressure during incident debugging.

**Fix direction:** Add the missing index or reduce write frequency/contention
for `instance_versions` shutdown updates. Confirm with slow-query samples after
deploy.

**Fixed:** `SyrusVersion.server_process?` now requires both `SYRUS_ROLE` and a
long-lived server/worker command shape (`rails server`, `puma`, `thrust`, or
`bin/jobs`). Ad hoc Rails runners and maintenance commands inside pods no
longer register transient `instance_versions` rows or run at-exit finalize
updates. Covered by `spec/services/syrus_version_spec.rb` and
`spec/services/instance_version_supervisor_spec.rb`.
