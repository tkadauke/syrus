# Landing Queue

The landing queue manages the flow from "approved" to "merged." Once a Job is approved, Syrus queues it for landing via the `auto_merge` workflow, `external_pr_merge` for externally filed PRs, or `merge_train` for Epics with merge trains enabled.

## Approval and landing

When an operator approves a Job:

1. The Job transitions to `approved`.
2. `LandingQueueProcessor.try_land!` evaluates whether the Job can proceed immediately or must wait.
3. If ready, Syrus dispatches the landing workflow and moves the Job to `landing`.

Landing queue candidates are ordered by `Job#priority` first
(`urgent`, `high`, `medium`, `low`), then by the existing FIFO approval
order (`approved_at`, falling back to `updated_at`, then `id`) within the
same priority. Dependency prerequisites still sort before their dependents,
and Epic merge-train members stay grouped as one atomic landing unit.

When repository approval propagation is enabled, Syrus mirrors eligible Job
approvals as GitHub PR reviews (`Job::ApprovalPropagator`). It compares the
approving user's own GitHub login (resolved via their connected PAT) against
the PR's actual author login: when they differ — the normal case — the
review is posted authenticated as the approving user's own PAT, so it's
genuinely attributed to them on GitHub. When they match — a true self-review,
where the approver is the same GitHub identity as the PR's author — GitHub
rejects same-identity self-approval, so the review is posted instead using
the GitHub App's installation token, with the body still crediting the real
approving human by name. Propagation is skipped only when no usable
credential exists at all: the approving user has no connected PAT and the
repository has no active App installation.

Jobs wait in `approved` when:
- A same-repo Job is already landing (serialized per repo by default).
- The Job is part of an Epic with `merge_train_enabled` and siblings aren't yet approved.
- A dependency Job hasn't closed successfully.
- The repository's main branch health is `broken` and Syrus has paused repository landing for repair.

`inconclusive` main branch health is warning-only. Syrus shows the main-health warning surfaces and notifications, but it does not hold queued workflows or landing queue entries solely because the signal is inconclusive.

The dashboard's landing queue `Blocked reason` column first shows the per-Job
queue blocker recorded by `LandingQueueProcessor`. If that value is blank,
the dashboard falls back to merge-train and start-gate diagnostics for the
same landing unit, such as a queued merge train blocked by `urgent_job_active`,
an already-active merge train, or landing state drift where a Job is in
`landing` with no active workflow or train.

## Failures that are not rejections

`LandingFailureHandler` splits a failed landing attempt two ways. A **deferral**
keeps the Job `approved` and lets the landing queue try again; a **failure**
reverts it to `implemented`, clears the approval, and waits for an operator.
Only a genuine rejection of the work — failed graders — belongs on the second
side. Everything that says nothing about whether the change is landable is a
deferral: GitHub 5xx, a sidecar that did not come up, a dead worker, lock
contention, and a `prepare` failure (the workflow never reached a grader, so the
change was never judged — the environment failed to build).

Putting a new failure path on the wrong side of that split costs an operator a
round of re-approving, potentially every member of a merge train.

## Failing PR checks: inherited vs. introduced

A Job whose GitHub checks are red is held out of landing, but *why* they are red
decides which hold applies. `PrCheckAttribution` compares the checks failing on
the PR head against the checks already failing on its base:

- **`own`** — at least one check is red here that is not red on the base. The
  Job introduced a failure. Blocked as `pr_checks_failing`, and that key is on
  `LandingBlockerOverride::NON_OVERRIDABLE_KEYS`: no override.
- **`inherited`** — *every* failing check is also failing on the base. The Job
  did not cause this. Blocked as `pr_checks_failing_inherited`, which **is**
  overridable, so an operator who has read the evidence can land it.
- **`unknown`** — no failing check names recorded for this SHA, or no settled
  health record for the base. Falls through to `pr_checks_failing`; the system
  does not guess in the Job's favour.

Both halves of the comparison are persisted, which is what makes the call
auditable rather than a black box: `jobs.pr_checks_failing_names` (written by
`PollPullRequestJob`, `LandingQueueRecheck`, and `CiRepair::CheckRefresh`) and
`main_branch_health_checks.ci_failed_checks` (written by
`PollMainBranchHealthJob`). The base compared against is the PR's own
`mergeability_base_sha` when a health record exists for it, else the
repository's most recent settled CI poll.

**An inherited verdict is evidence, not proof.** Check-run names are coarse: a
single `rspec` check can be red on main for spec A and red on a PR for specs A
*and* B, and by name alone those are indistinguishable. That is why `inherited`
downgrades the block to overridable by default rather than landing the Job
automatically — auto-landing on that signal can let a second breakage through
while main is already red.

`Repository#land_on_inherited_check_failure` (default `false`, per repository,
in the repository settings form) opts out of the hold: an `inherited` verdict
then clears the checks gate outright and the Job keeps moving while main is red.
Whether that is safe depends on how granular the repository's check names are —
a repo with one monolithic `tests` check gets very little signal from a name
match, a repo with per-suite checks gets a lot — which is why it is a
per-repository setting rather than an instance-wide one.

The opt-in clears the **checks** gate only. Every later gate still applies
(mergeability, rebase cap, epic siblings, parent Job, dependencies), and it never
excuses an `own` or `unknown` verdict.

The verdict and its evidence are surfaced in three places so an operator and an
agent see the same thing: the Job page's PR-checks banner (which checks fail
here, which fail on the base, and the base SHA), the app payload
(`job.pr_checks.attribution`), and the admin API
(`GET /api/v1/admin/jobs/:id` -> `pr_checks_attribution`).

Syrus already made this distinction for its *own* grader steps via
`.syrus.yml`'s `grade.failures: allow_inherited` ->
`Adjudicators::InheritedGraderFailure` -> `MainBranchFailureClassifier`. This is
the same idea applied to GitHub check runs, which previously had nowhere to
record which checks failed.

## known_flaky_failure_dismissal_enabled

`InheritedGraderFailure` cannot catch a spec that fails intermittently on the
base branch too -- comparing against a single base-branch run proves nothing
when the flake might simply not have reproduced there this time. That gap has
stalled a merge train for hours across dozens of retries: a genuinely flaky
spec kept failing a required grader on every `landing_fix` retry, unrelated
to the PR's diff.

`Adjudicators::KnownFlakyFailure` closes it from the other direction: when
every failing test in a required grader Step already has a confirmed-flaky
history in Test Insights (`flaky: true`, and a flakiness score at or above a
configurable floor), the failure is dismissed at rung 0 instead of blocking
landing or spending a `landing_fix` repair turn. It reuses whatever
`:test_evidence` plugin already answers "which tests failed in this run" and
"what is this test's flakiness score" -- with no such plugin, or no scoring
history yet, it declines rather than guessing.

Off by default, opted in per repository via
`Repository#known_flaky_failure_dismissal_enabled` (same shape as
`trust_clean_rebase_grade` and `land_on_inherited_check_failure` above): a
repository whose flakiness history is not yet trustworthy should not have
required-grader failures waved off silently.
`Repository#known_flaky_failure_min_score` optionally raises the minimum
flakiness score a test needs before its failure counts as "confirmed" flaky
(default `Adjudicators::KnownFlakyFailure::DEFAULT_MIN_SCORE`), guarding
against a single historical blip looking like a pattern. A dismissal is
recorded as a `known_flaky_grader_failure` workflow artifact (the dismissed
grader names, the confirmed-flaky tests and their scores) and logged on the
`grader_collect` Step, the same visibility `record_inherited_main_failure!`
gives an inherited-failure dismissal -- an operator or agent looking at why a
red required grader did not block landing should never have to infer it from
the absence of a failure.

## new_test_flakiness_gate_enabled

`KnownFlakyFailure` only has signal once a test has run at least twice across
real Workflows -- a brand-new test, or one freshly modified by this Job, has
no history yet, so neither it nor a plain `InheritedGraderFailure` comparison
against base can tell a test that is flaky from day one apart from a
genuinely stable one.

`TouchedTestFiles` closes that gap inside each typed test grader. Once that
grader's normal command passes, it looks at the test files this Job's diff
added or modified
relative to its effective base branch (`_spec.rb`, `_test.rb`,
`.spec`/`.test.ts(x)`, `test_*.py`/`_test.py`, `_test.go` -- not the whole
suite, and not the untouched majority of an existing spec file). When that
set is non-empty, `TouchedTestRepeatGate` reruns just those files a few more
times (default `TouchedTestRepeatGate::DEFAULT_REPEATS`, 5) against that
grader. Files are first restricted to the grader target's resolved
`when_files_changed` scope, so nested-project graders only judge tests owned
by their project. RSpec and Vitest graders perform this work in their normal
distributed fanout slots; non-test graders do not participate. Building that "just
these files" command does *not* require the grader to have separately opted
into `BaseRevisionRetry`'s `base_retry: { strategy: plugin }` -- that would
make the gate a silent no-op for most repositories, since `base_retry` is a
rarely-configured opt-in for a different feature. Instead: an explicit
`command`/`files_as_args` `base_retry` on the grader (if the repository
already configured one, e.g. this repo's own `rspec` grader) is reused
as-is; otherwise `TouchedTestRepeatGate` asks the same `:focused_test_command`
extension point `BaseRevisionRetry` uses, but with its own synthesized
`plugin` strategy -- that point's whole contract is "can a language plugin
build a file-scoped rerun command for this grader," independent of whatever
`base_retry` the grader has (or doesn't have) configured. A grader whose
language has no registered `:focused_test_command` provider (only Ruby and
JavaScript today) and no explicit `base_retry` command is skipped for that
grader, logged, rather than guessed at. Focused commands run with the same
relevant environment the owning grader declared inline (`RAILS_ENV`,
`COVERAGE`, Bundler paths) plus the normal grader subprocess environment, so a
plugin-scoped focused rerun is not silently stripped of the prefix the full
plugin grader just used.

Mixed repeat results (some pass, some fail) fail the grading iteration with a
`grader_failure` Problem carrying
`evidence: { new_test_flakiness: true, focused_command_failure: false, result:
{...} }`, and the repeat result is stored on that grader Step and included in
the iteration rollup so the repair prompt, the chat report, and the Job page
all show "this Job's new test failed N/5 times on repeat" instead of a generic
failed grader -- the agent or operator sees they introduced flakiness, not that
they broke an existing check. A stable touched test (all repeats pass) leaves
the iteration's outcome untouched. If every repeat fails after the owning full
grader passed, the gate classifies that separately as a suspect focused rerun
(`focused_command_failed_consistently`, `focused_command_invalid`, or
`focused_command_timed_out_consistently`) and carries `evidence:
{ new_test_flakiness: false, focused_command_failure: true, result: {...} }`.
Each failed repeat stores bounded combined stdout/stderr, exit status, timeout
state, duration, focused command, normal command, and diagnostic environment,
so operators and repair agents can see whether the file-scoped command or its
environment is the failing surface.

Off by default, opted in per repository via
`Repository#new_test_flakiness_gate_enabled` (same shape as
`known_flaky_failure_dismissal_enabled` above): it spends real extra command
runs on every Job whose diff touches spec files, so a repository opts in
deliberately rather than paying that cost by default.
`Repository#new_test_flakiness_gate_repeats` overrides the default repeat
count.

## isolated_repro_dismissal_enabled

`KnownFlakyFailure`'s `flakiness_score` needs accumulated cross-run history
to say anything -- a test that has only ever failed once, or whose history
was lost to an ingestion bug, gives it nothing to work with. An agent
investigating a required-grader failure during `landing_fix` (or another
repair step) often already does the obvious thing: run the exact failing
example in isolation, against the exact failing commit, before touching any
code, to see whether it reproduces. That is a different, better-grounded
signal than either `flakiness_score`'s accumulated history or an agent's
unverifiable opinion that a test "looks flaky" (rejected elsewhere as
correlated with each Job's incentive to get its own PR unblocked, not
independent) -- it's a verifiable *action*, with a command and its raw
output, that speaks to this one occurrence immediately.

The `record_isolated_repro` MCP tool lets an agent record that fact as
structured evidence -- the exact command, its raw output, and whether it
reproduced -- via a `:test_evidence` provider's `record_isolated_repro!`/
`isolated_repro_evidence` capability (`TestInsights::IsolatedReproAttempt`,
stored in its own table, never mixed into `TestCase`'s `scored` pool that
`flakiness_score` reads). `IsolatedReproRecorder` validates the call before
it is ever stored: it reads the workspace's actual `git rev-parse HEAD`
rather than trusting an agent-supplied SHA, and requires it to still equal
the exact commit the last grading iteration failed at -- which rejects both
a repro run against the wrong commit and one recorded after the agent's own
fix commits exist (either moves HEAD away from the graded commit) -- and
requires the named test to be among what the grader Step actually reported
failing, not merely asserted by the agent.

`Adjudicators::IsolatedReproDismissal` closes the loop at rung 0: when every
failing test in a required grader Step has a same-SHA, pre-fix "did not
reproduce" record, the failure is dismissed instead of blocking landing or
spending another repair turn. Off by default, opted in per repository via
`Repository#isolated_repro_dismissal_enabled` (same shape as
`known_flaky_failure_dismissal_enabled` above). A dismissal is recorded as an
`isolated_repro_grader_failure` workflow artifact (the dismissed grader
names, the non-reproducing tests, and the SHA) and logged on the
`grader_collect` Step, the same visibility `record_known_flaky_failure!`
gives a flakiness-history dismissal.

A same-workflow `retry_until` re-run of the whole grader is a different
thing entirely and is not what this records: that is a normal grading
execution and already belongs in `TestCase`'s `scored` pool (excluded from
it only via `TestCase.wip_repair_failures` when it's the workflow's own
in-loop self-repair). `record_isolated_repro` is for a single, deliberately
targeted example run outside the normal grading loop.

## Stopping a landing attempt

While a Job is `landing` -- solo (`auto_merge`/`external_pr_merge`) or as part
of an Epic merge train -- the Job detail page shows a **Stop Landing** button.
It is available to the same operators who can otherwise mutate the Job (the
owner, an admin, or a repository member with write access), via
`POST /api/v1/app/jobs/:job_id/stop_landing` (`Job#stop_landing!`).

Stop Landing cancels the Job's active landing Workflow -- the solo
`auto_merge`/`external_pr_merge` Workflow, or the single Epic-wide
`merge_train` Workflow when the Job is a train member -- and reverts the Job
to `implemented`, clearing its approval the same way a genuine landing
failure does (`LandingFailureHandler`/`MergeTrainFailureHandler`). This is
deliberate: an explicit stop should require the operator to re-approve before
Syrus attempts to land the Job again, not silently re-enter the landing
queue. For a merge-train member, stopping the train reverts every member Job
that hadn't already merged, the same as any other train failure or
cancellation.

Stop Landing does not close the Job (contrast with the general-purpose
**Cancel** button, which cancels active work and closes the Job entirely) --
the PR and branch stay intact for the operator to re-approve once ready.

## auto_merge workflow

**Step chain:** `mergeability_preflight → prepare → retry_until(graders, repair: landing_fix) → push → auto_merge`

### mergeability_preflight

Refreshes GitHub's mergeability status for the PR. When GitHub says the PR is
ready, Syrus first attempts a deterministic rebase onto the current base branch
and force-pushes it with `--force-with-lease` if the rebase changes the PR head.
Final graders then run against that rebased head. If the deterministic rebase
conflicts, Syrus dispatches a `rebase` workflow and defers. If GitHub is still
computing (`mergeable: null`), Syrus runs a local rebase preflight to distinguish
conflicts from GitHub lag. If a prior landing validation is still valid for the
current artifact, base, and grader configuration, skips grader re-validation and
logs the reuse reason.

### Grader re-validation

Before merging, Syrus re-runs the full required grader suite on the exact PR branch being landed.

Landing throughput instrumentation is written to each Workflow's
`landing_throughput_metrics` artifact and surfaced in admin workflow debug
payloads. Validation decisions record whether landing graders were skipped or
rerun, the cache match type (`exact_head`, `same_tree`, or
`clean_rebase_carry_forward`), and the rejection reason when Syrus reruns
validation. Grader loop timing records the grader count, wall-clock duration,
summed individual durations, and whether required graders failed. Fanout-specific
cap and efficiency metrics are intentionally absent until parallel landing
grader fanout is designed and enabled separately.

If graders fail, `landing_fix` (an agentic repair step) attempts a fix, and graders re-run. This loop repeats up to `grade_max_iterations` times.

### Speculative landing validation

When the `landing_validation_prefetch` feature flag is enabled, a successful
landing grader loop can warm the next same-repository landing unit before the
current unit actually publishes to the base branch. Syrus dispatches an
infrastructure validation workflow for the next eligible unit:

- Ordinary owned-branch PRs use `landing_validation`.
- Epic merge-train units use `merge_train_validation`.

For an ordinary PR, the workflow:

- Clones the next PR branch.
- Fetches the current landing workflow's local `HEAD` as the predicted future base.
- Rebases the candidate onto that predicted base without pushing.
- Runs the same fast landing graders without `landing_fix`.
- Records a `LandingValidationCache` artifact with the predicted base SHA and base tree SHA.

For an Epic merge-train unit, the workflow builds the candidate integration tree
on top of the same predicted future base, mechanically rebases each member
branch into that scratch integration branch, and runs fast landing graders
without creating a real `MergeTrain`, pushing, or repairing.

The real `auto_merge` or `merge_train` workflow later reuses that validation
only if the candidate head/tree, base ref, base tree, grader fingerprint, and
changed-file fingerprint still match. A different base commit SHA is allowed
only when its Git tree SHA is identical to the predicted tree, which covers
GitHub rebase-merge producing a different commit object for the same contents.
If any identity differs, the normal serialized landing workflow reruns graders.

Speculative validation is not an additional landing lane. It never pushes,
merges, or repairs; a failed speculative workflow leaves the Job approved and
the normal landing queue path intact.

### push and auto_merge

After graders pass, Syrus pushes any repair commits and calls the GitHub merge API. The merge method (merge, squash, or rebase) is configured per-repository.

### Transient failures

If GitHub's merge API returns a transient error, the Job is deferred back to `approved` and retried. If GitHub returns 405 "PR can't be rebased," Syrus dispatches a `rebase` workflow instead of treating the attempt as terminal.

### After a successful merge

The Job transitions to `pr_merged`. If the merged PR was depended on by other Jobs, those dependencies are satisfied and their workflows unblocked.

## external_pr_merge workflow

**Step chain:** `mergeability_preflight → prepare → grader_fanout → grader_collect → external_pr_merge`

External PR Jobs use the GitHub PR as the source of truth instead of a Syrus-owned branch. The workflow refreshes GitHub mergeability, prepares the workspace so grader dependencies are installed, runs required graders against the external PR head, then calls GitHub's merge API for the external PR number. It still skips the normal `push` step.

For same-repository external PRs, `mergeability_preflight` first attempts a deterministic rebase of the PR head ref onto the current base branch and force-pushes it with `--force-with-lease` before landing graders run. If that deterministic rebase conflicts, Syrus dispatches the normal `rebase` workflow against the external PR's actual head branch and defers landing. Fork PRs skip this preflight rebase because Syrus cannot push their branches.

For same-repository external PRs, grader failures enter the `landing_fix` retry loop before merge. If the agent commits a repair, `external_pr_merge` pushes the local repair commit to the PR's actual head branch immediately before merging. For fork PRs, Syrus cannot push repairs; required grader failures post a `REQUEST_CHANGES` review and `fail_landing!` returns the Job to `implemented`.

## trust_clean_rebase_grade

When `Repository#trust_clean_rebase_grade` is enabled (off by default), a clean `rebase` workflow can carry forward a prior green landing validation to the new head/base pair. A clean `merge_train_rebase` recovery can do the same for a base-moved Epic integration branch. This allows later `auto_merge` or `merge_train` landing steps to skip re-running graders when the only change is a mechanical clean rebase onto the base branch.

Grade carry-forward records a fresh `LandingValidationCache` artifact for the post-rebase head, tree, base ref, base SHA, required-grader fingerprint, and changed-file fingerprint. It only carries forward from a successful required-grader validation, not from another carried validation, and the base ref plus required-grader fingerprint must match the source validation. The changed-file fingerprint is recomputed and stored on the new artifact for diagnostics and later exact-head reuse, but it does not veto carry-forward: with `trust_clean_rebase_grade` enabled, the operator is explicitly accepting the risk that a clean rebase onto a moved base changes the apparent diff. Later reuse reports this as `clean_rebase_carry_forward` rather than as a normal exact-head hit. It is never applied speculatively.

## LandingValidationCache

Stores the result of a successful required-grader run as a workflow artifact:

```json
{
  "required_graders_passed": true,
  "head_sha": "abc123",
  "tree_sha": "tree789",
  "base_sha": "def456",
  "base_tree_sha": "basetree123",
  "base_ref": "main",
  "grader_fingerprint": "grade-plan-sha256",
  "validation_source": "graders",
  "checked_at": "2026-07-13T10:00:00Z"
}
```

Later `auto_merge` or `merge_train` retries can skip re-validation when:

- `exact_head`: the artifact's `head_sha` matches the commit being landed.
- `clean_rebase_carry_forward`: a trusted clean rebase re-stamped the validation for the new head/base.
- `same_tree`: the commit SHA differs, but the Git tree SHA matches the validated tree.

All reuse requires the base ref and required grader fingerprint to remain unchanged when those values are recorded. Non-speculative validations also require the base SHA to remain unchanged. Stale validations older than seven days are rejected. Audit logs explain whether landing graders were skipped or rerun, including changed base, changed grader configuration, stale validation, and cache-miss reasons.

Speculative validations may also record `base_tree_sha`. For those artifacts,
later reuse accepts a changed `base_sha` only when `base_tree_sha` still matches,
then continues checking grader and changed-file fingerprints normally.

## Dependency gating

A Job blocked on another Job will not enter the landing queue until the dependency closes with one of these reasons: `pr_merged`, `external_pr_merged`, `pr_approved`, or `no_changes`. Same-Epic dependencies are also satisfied once the upstream Job is `approved` or `landing`.

If the prerequisite Job closes unsuccessfully, including `cancelled`, dependents remain blocked with `dependency_failed` until an operator removes or overrides the dependency. Syrus should not keep creating maintenance rebase workflows for a dependent while it is in this permanent dependency-failed state.

Manual dependency rows can opt into `satisfaction_mode: "closed"` for cleanup or teardown gates that only need the target Job to reach any terminal close. In that mode a dependency on a cancelled Job is satisfied. Normal implementation dependencies default to `satisfaction_mode: "success"` and must not be weakened to closed mode just because the prompt says "after" or "once"; use closed mode only when any terminal outcome is explicitly acceptable.

Implementation has a narrower, execution-only exception: a same-Epic child Job may start on an `implemented` parent once that parent has a materialized branch, PR, and head SHA, as long as stack parent selection is unambiguous. For approved same-Epic fan-in, Syrus may also create a prepared combined base branch and start the child there when all dependency PR branches merge cleanly. This does not satisfy the landing gate above.

Operators can add or remove manual dependencies from the Job detail page; admins can override the gate.

## Closed-PR resolution

When a PR is closed without GitHub marking it merged, Syrus inspects the branch against the PR base with `git cherry` and picks one of three outcomes:

- **`pr_merged`** — every commit on the branch has a patch-equivalent commit on the base. The work landed, even though this PR was not the thing GitHub merged: a merge train landed a rebased copy, or someone cherry-picked it. This is a landing, and recording it as anything else files real work as work that never happened.
- **`no_changes`** — the branch is not ahead of the base by a single commit. The agent genuinely produced nothing (the normal happy path for a survey-style cron Job).
- **`pr_closed`** — the branch still carries commits the base does not have.

`no_changes` and `pr_merged` both count as successful resolutions for dependency gates and landing queue wakeups; the distinction matters for attribution, not for gating.
