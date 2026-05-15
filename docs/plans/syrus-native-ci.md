# Syrus-native CI — grade step + loop primitive

_Captured 2026-05-12. Implementation should land across 4 PRs (see
"Build order"); the GitHub Actions removal is the last one._

_Status check 2026-05-15: partially shipped. `Steps::Grade`,
`Workflows::Loop`, loop iteration tracking on `Step` / `Run`,
`RepoGradePlan` / `.syrus.yml` grade parsing, grade failure feedback,
the iteration UI, and `initial` / `retry` / `pr_comment` loop wiring
are present. The remaining cleanup is the final handoff from GitHub
check-run driven remediation: `ci_failure` polling, `Workflows::CiFailure`,
`Steps::AnalyzeAndFix`, and the related prompt/spec surface still exist
and should be retired in the Build order step 4 follow-up. Inline
same-Run continuation for controlled grade failures is also explicitly
tracked as a dropped `#332` follow-up in the specs._

## Context

`.github/workflows/ci.yml` is currently blocked by a GitHub Actions
billing limit, which means every push gets a `conclusion: failure`
on its check runs. `PollAllPullRequestsJob` reads that as "tests
broke" and enqueues a `ci_failure` workflow, which spends the
agent's turn budget rediscovering that there is nothing to fix.
Every Job retries. Every retry pays for itself in Anthropic
tokens.

Rather than pay for GitHub-hosted runners, run the equivalent
quality gates inside Syrus on the worker pod's filesystem — the
clone is already there, the env is already scrubbed, the agent is
already authoritative on the diff. The check that produced the
signal becomes the same check that the agent reads and fixes,
removing the round-trip through GitHub.

Going one step further: the agent should iterate on grader output
inside one Workflow, not via a follow-up `ci_failure` Workflow.
This plan introduces a `Loop` chain primitive that wraps implement
+ grade in a bounded retry, with the agent's session continuing
across iterations via `--resume`.

## Decisions locked

1. **Run quality gates inside Syrus, not on GitHub Actions.** Every
   check from `ci.yml` (brakeman, bundler-audit, importmap audit,
   rubocop, rspec) becomes a `grade` step entry in `.syrus.yml`.
2. **Loop primitive in the chain DSL.** `Loop.new(max_iterations:
   5, steps: [:implement, :grade])` wraps the implement+grade pair
   into a bounded retry. Default max iterations is 5, hard ceiling
   10, per-repo override via `.syrus.yml`, fleet-wide default in
   `AppSetting.grade_max_iterations`.
3. **Session continuity across iterations via `--resume`.** Each
   iteration's implement Run sets `parent_session_id` to the prior
   iteration's `ClaudeSession.session_id`. The agent keeps full
   memory of what it tried.
4. **Full grader output flows to the agent, with a size escape
   hatch.** Up to 32 KB inline; over 32 KB → head 4 KB + tail 8 KB
   + path pointer to the full log on disk. Agent can `cat` /
   `grep` the full file if it needs the middle.
5. **One Step row per logical step; iteration index lives on Run.**
   `Run#iteration` (integer, default 1). Implement has multiple
   Runs across iterations, all under the same Step. Grade has
   multiple Runs under the same Step. Step rows are NOT
   pre-materialized for every possible iteration; the next
   iteration's Runs are created on demand when grade fails and
   budget remains.
6. **pr_open lives outside the loop.** Loop must converge first.
   No broken intermediate PRs.
7. **`pr_comment` chain uses the same loop.** Operator feedback on
   an open PR triggers `prepare → loop(respond → grade) →
   summarize_amend → push`.
8. **`Steps::CiFailure` is retired.** Once `grade` ships and
   stabilises for two weeks on production, the polling that
   creates ci_failure Workflows from GitHub check_runs is removed.
   Quality is now adjudicated locally.
9. **`.github/workflows/ci.yml` deleted.** No zombie billing-blocked
   runs. `.github/` directory removed if no other workflows exist.

## `.syrus.yml` schema

```yaml
prepare:
  - bundle config set --local path vendor/bundle
  - bundle install --jobs 4

grade:
  max_iterations: 5       # optional; per-repo override of AppSetting.grade_max_iterations
  steps:
    - name: tests
      run: bin/rspec
      required: true       # default; failure triggers another iteration
    - name: lint
      run: bin/rubocop
    - name: security
      run: bin/brakeman --no-pager --except EOLRuby
    - name: gem-audit
      run: bin/bundler-audit
      required: false      # advisory; failure logged, does NOT trigger another iteration
    - name: js-audit
      run: bin/importmap audit
      timeout_minutes: 5   # optional; default 15, hard ceiling at Run-level 30
```

`grade:` accepts either the full hash form above or a bare array
of step entries (in which case `max_iterations` falls back to the
`AppSetting`). Both forms must round-trip through the parser.

`name:` must be unique within the file, alphanumeric + dashes,
because it's used as a filesystem path component.

## Components

### 1. `Steps::Grade` handler

`app/services/steps/grade.rb`:

- Reads `grade.steps` from `.syrus.yml` (or skips with a logged
  "no graders configured" if absent).
- Runs each grader sequentially, fail-fast on `required: true`
  failures, recording results in `workflow.artifacts["iterations"]`
  under the current iteration index.
- Writes every grader's full stdout+stderr to
  `.syrus/grade-output/iteration-N/<grader-name>.log` (workspace-
  relative). The workspace adds `.syrus/` to `.git/info/exclude`
  during setup so it never appears in `git status`.
- Step succeeds if every `required: true` grader passes; fails
  otherwise. Advisory graders contribute to artifacts but never
  cause failure.

Result entry shape (one per grader per iteration):

```json
{
  "name": "tests",
  "required": true,
  "status": "failed",
  "exit_code": 1,
  "duration_s": 23.4,
  "log_path": ".syrus/grade-output/iteration-2/tests.log",
  "log_bytes": 84231
}
```

Failure-fast is per-iteration — once one required grader fails,
the rest in the iteration are skipped (entries recorded with
`status: "skipped"`). Operator saves wall time; agent gets the
first failure to fix.

### 2. `Loop` chain primitive

`app/services/workflows/loop.rb`:

```ruby
module Workflows
  class Loop
    attr_reader :max_iterations, :steps

    def initialize(max_iterations:, steps:)
      raise ArgumentError, "loop steps required" if steps.empty?
      @max_iterations = max_iterations
      @steps = steps.map(&:to_s).freeze
    end

    def loop? = true
  end
end
```

Workflow chain definitions can now mix symbols (single steps) and
`Loop` instances:

```ruby
# app/services/workflows/initial.rb
class Initial < Base
  steps :prepare,
        Workflows::Loop.new(max_iterations: 5,
                            steps: [ :implement, :grade ]),
        :summarize,
        :pr_open
end
```

`Workflows::Base.instantiate` is extended to materialize the
*first* iteration of any Loop node: it creates one Step row per
inner step kind, marked with `iteration: 1` on the Step (new
column). Subsequent iterations are materialized on demand by
`StepDispatcher` when grade fails and budget remains.

### 3. Data model

```ruby
# db/migrate/<ts>_add_iteration_to_steps_and_runs.rb
add_column :steps, :iteration,  :integer, null: false, default: 1
add_column :steps, :loop_id,    :string                         # uuid-ish; groups iterations of the same loop
add_column :runs,  :iteration,  :integer, null: false, default: 1
add_index  :steps, [ :workflow_id, :loop_id, :iteration ]
```

- `Step#loop_id` is the same UUID for every Step that belongs to
  the same logical Loop node (across all its iterations). Lets
  the UI group iterations + lets the dispatcher count
  "iterations so far" without re-walking the chain.
- `Step#iteration` is which iteration of its Loop this Step is.
- `Run#iteration` mirrors its Step. (Convenience denormalization
  so the admin API's flat Run list can filter by iteration
  without a join.)
- Non-loop steps keep `iteration: 1`, `loop_id: nil`. No
  migration churn for existing rows.

`Workflow#current_iteration` is a derived method (max iteration
across in-progress Steps grouped by loop_id).

### 4. Dispatcher behavior

`app/services/step_dispatcher.rb`:

After a grade Step terminates:

- **Succeeded:** advance to next_step_id (post-loop step, e.g.
  `summarize`).
- **Failed**, `iteration < loop.max_iterations`:
  1. Create the next iteration's Step rows (implement + grade)
     with `iteration: current + 1`, same `loop_id`.
  2. Wire current grade's `next_step_id` → new iteration's
     implement.
  3. Wire new iteration's grade's `next_step_id` → original
     post-loop step (looked up by walking the original chain
     definition; cached on `Workflow#chain_template`).
  4. Enqueue the new implement Run with `parent_session_id`
     copied from the prior iteration's `ClaudeSession`.
- **Failed**, `iteration == loop.max_iterations`:
  Workflow fails with `failure_reason: "loop_exhausted"`. Last
  iteration's grade artifacts stay visible. No PR is opened.

### 5. Prompt: feedback into next iteration

`app/services/prompts/grade_failure_feedback.rb`:

Composes the full trajectory across all prior iterations from
`workflow.artifacts["iterations"]`, plus inline grader output up
to 32 KB / head-tail truncation policy above. The implement step
appends this to its base prompt only when `Run#iteration > 1`.

Sketch:

```
The previous iteration's quality graders flagged issues. Here are
the results from every iteration so far:

== Iteration 1 ==
  ✓ lint
  ✗ tests (exit 1, 23.4s)
    <full output, 6 KB>
  - security (skipped — earlier required grader failed)

== Iteration 2 ==
  ✓ tests
  ✗ lint (exit 1, 4.1s)
    <full output, 2 KB>
  ✗ security (exit 1, 18.3s, output 84 KB — truncated)
    Head:
      <first 4 KB>
    ...
    Tail:
      <last 8 KB>
    Full log: .syrus/grade-output/iteration-2/security.log

Pick the smallest correct change that resolves the failing required
graders without regressing the passing ones. Inspect the full log
file directly if the head+tail excerpt isn't sufficient.
```

`Prompts::SubmitSummaryInstructions` is appended by the same
path that Initial / PrFeedback already use, so the
`submit_summary` contract carries through every iteration.

### 6. AgentInvocation — pass through `parent_session_id`

Already exists for the `resume` trigger kind. Reuse: when
`Run#iteration > 1`, the implement Step sets
`resume_session_id: run.parent_session_id` on the AgentInvocation
constructor, exactly like `Steps::Base` does for the existing
`resume` chain.

### 7. UI: iteration switcher on the job show page

`app/views/jobs/show.html.erb`:

- Workflow card grows an iteration row when a Loop's iteration
  count exceeds 1. Pills/tabs labelled `Iteration 1`, `Iteration
  2`, …, with state colour (failed = red, succeeded = green,
  running = blue).
- Active tab is the current iteration (running) or the last one
  (terminal). Each tab body renders the implement + grade Step
  pair for that iteration. Grade Step expands per-grader rows
  with status + duration + a "Show log" link (renders the log
  contents from disk via a worker-side controller, NOT directly
  serving the file).

### 8. Pruning grade-output files

Workspace lifecycle is already tied to Workflow terminal
transitions (`WorkflowWorkspacePruneJob` sweeps old terminal
workspaces after 7 days). `.syrus/grade-output/` lives inside the
workspace and gets pruned with it — no separate cleanup job.

### 9. Remove GitHub Actions

Final PR in the sequence:

- Delete `.github/workflows/ci.yml`.
- Delete `.github/workflows/` if it's the only file.
- Delete `.github/` if it's the only directory under that root.
- Update `README.md` if it references GH Actions CI (grep first).
- Delete `Steps::CiFailure`, `Workflows::CiFailure`, the
  `ci_failure` trigger-kind branches in `PollAllPullRequestsJob`,
  and related specs. Bump
  `Run::TRIGGER_KINDS` to drop `ci_failure`.
- Add a migration to retire any in-flight `ci_failure` Workflows
  (mark `cancelled` with reason `superseded_by_grade`).

## Files to modify

**New:**

- `app/services/steps/grade.rb`
- `app/services/workflows/loop.rb`
- `app/services/prompts/grade_failure_feedback.rb`
- `db/migrate/<ts1>_add_iteration_to_steps_and_runs.rb`
- `spec/services/steps/grade_spec.rb`
- `spec/services/workflows/loop_spec.rb`
- `spec/services/prompts/grade_failure_feedback_spec.rb`

**Modified:**

- `app/services/workflows/base.rb` — extend `instantiate` to
  expand `Loop` nodes into first-iteration Steps; cache the
  chain template on the workflow so the dispatcher can resolve
  the post-loop next_step.
- `app/services/workflows/initial.rb`, `retry.rb`, `pr_feedback.rb`
  — wrap their implement (or respond) + new `grade` in
  `Loop.new(...)`.
- `app/services/step_dispatcher.rb` — loop-aware advancement
  (see §4 above).
- `app/models/step.rb` / `app/models/run.rb` — add `iteration`,
  add `loop_id` on Step; convenience methods (`Workflow#current_iteration`).
- `app/services/syrus_yml.rb` (or wherever `.syrus.yml` is parsed)
  — parse `grade:` key in both array and hash forms; validate
  `name:` uniqueness + slug shape.
- `app/views/jobs/show.html.erb` + new partials — iteration
  switcher.
- `app/services/workflow_workspace.rb` — add `.syrus/` to
  `.git/info/exclude` after clone.
- `app/models/app_setting.rb` — `grade_max_iterations` (default
  5, ceiling 10).
- `spec/services/syrus_yml_spec.rb` — schema parsing tests.
- `spec/services/step_dispatcher_spec.rb` — loop advancement.

**Deleted (final PR):**

- `.github/workflows/ci.yml`
- `app/services/steps/analyze_and_fix.rb` (subsumed by the loop;
  verify no other callers first)
- `app/services/workflows/ci_failure.rb`
- `ci_failure` branches in `PollAllPullRequestsJob`
- Their specs

## Build order

Ship as 4 PRs so each is independently reviewable and revertible:

1. **`Loop` primitive + `Run#iteration`.** Schema, model
   plumbing, `Workflows::Base` expansion. Workflow definitions
   not yet using it. Tests for `Loop.new`, the migration, and
   `Workflows::Base` round-trip with a single-step Loop.
2. **`Steps::Grade` handler + `.syrus.yml` schema.** New step
   kind that runs commands and writes artifacts. Not yet wired
   into any chain. End-to-end test with a fake `.syrus.yml`.
3. **Wire `grade` into `initial` / `retry` / `pr_feedback`
   chains via `Loop`.** Iteration switcher UI, prompt
   composition, dispatcher loop advancement, `parent_session_id`
   threading. The behavior-change PR; deploy + soak on
   `syrus-test` for a few days before #4.
4. **Retire GitHub Actions + `Steps::CiFailure`.** Delete
   `.github/workflows/ci.yml`, delete the `ci_failure` polling
   path and its supporting code. README + agent guide update.

## Verification

1. **Unit:** every new service has its own spec; full suite green.
2. **Loop convergence on `syrus-test`:**
   - File an issue that intentionally breaks rubocop on first
     pass (e.g. "rename `foo` to `Foo`" with no other lint fix).
     Confirm iteration 1 grade fails, iteration 2 grade passes,
     PR opens.
   - File an issue that's impossible to fix (deliberately
     contradictory). Confirm workflow fails with
     `loop_exhausted` after 5 iterations, no PR opened.
3. **Output truncation:** craft a `.syrus.yml` grader that emits
   ~100 KB of output. Verify the agent prompt contains head+tail
   and the log file path; verify `.syrus/grade-output/.../*.log`
   exists in the workspace and matches the full output.
4. **Workspace exclusion:** after a workflow runs, `git status`
   inside the workspace clone is clean — no `.syrus/` directory
   listed.
5. **Session continuity:** in iteration 2's claude transcript,
   confirm `session_id` matches iteration 1's (proves `--resume`
   threaded through, not a fresh session).
6. **GitHub Actions removed:** `gh run list --limit 5` after a
   push shows no entries (no workflows on the repo).

## Things to flag, not blockers

- **Adversarial-review grader** (`kind: agent_review`) is M3
  scope, not this plan. Schema today has only `kind: shell` (the
  default and only kind). Adding `kind:` later is a non-breaking
  schema extension because `name:` + `run:` are the only required
  fields today.
- **Browser-test grader** (`kind: browser_test`) is also future.
  Same extension story.
- **Parallel grader execution** is deferred. Single workspace +
  shared bundler/npm state makes parallel tricky. Sequential
  fail-fast is good enough; revisit if grade wall time becomes a
  pain point.
- **One-level loop nesting only.** Nested loops are rejected at
  workflow instantiation time.
- **Loop budget hard ceiling.** `grade.max_iterations` capped at
  10 even if `.syrus.yml` requests more, so a typo never produces
  a runaway agent.
- **Existing CI signal during transition.** PRs opened during the
  multi-PR rollout will still see the (failing, billing-blocked)
  ci.yml until step 4 deletes it. Acceptable — the grade step
  becomes authoritative and the GH signal is being ignored
  anyway. Make sure branch protection is OFF on the GH side
  during the transition so the broken ci.yml doesn't block
  merges.
