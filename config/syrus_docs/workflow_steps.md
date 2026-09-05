# Workflow Steps

Each Syrus workflow is a chain of steps. Steps are either **agentic** (invoke the agent CLI) or **non-agentic** (run service code directly). Step kinds are registered in `app/models/step/kind.rb`.

Before a queued Run starts, `RunJob` may defer pickup on the selected compute
host if that host is under critical resource pressure or is already running a
resource-guarded Run. This host-local guard applies to `:runs`, `:merges`, and
sticky resume queue workflows and covers agentic Steps plus CPU-heavy grader
work. A deferred pickup leaves the Run queued, records a `run_host_admission`
Workflow artifact and a system JobLog line, then re-enqueues the same Run
without spending a retry or repair iteration. Worker-died auto-retries also
record `failed_worker_*` context and defer while the failed host's fresh health
sample remains critical. See
[`multi_worker.md`](multi_worker.md#per-host-run-pickup-admission).

## How a step reports failure

A step handler raises `Steps::Base::StepFailed`. When the handler knows *what*
went wrong, it says so in the shared failure vocabulary
(`Problem::Kind`) rather than only in prose:

```ruby
fail_with!(:merge_train_rebuild_required,
           "merge_train_reconcile: integration branch is missing; rebuild required",
           evidence: { merge_train_id: train.id })
```

An exception class that always means one thing declares it once instead, and
every `raise` of that class carries it:

```ruby
class BranchDiverged < StepFailed
  problem_code :branch_diverged
end
```

The declared code is persisted on the Run's diagnostic and read by the layers
that act on the failure — `RunFailureClassifier` returns it directly (with
confidence `1.0`, because it is a report rather than a guess), and
`LandingFailureHandler` uses it to tell "rebuild this train" apart from "this
landing is dead". Those layers previously recovered the meaning by matching
regular expressions against the message text, and they disagreed with each
other whenever the wording drifted.

Declaring a problem is **optional and should stay that way**. Most failures are
genuinely opaque at the raise site — a git command failed, the provider
returned something unexpected — and are still classified downstream from
process outcomes, exception classes and log evidence. Declare a code only where
the step was actually certain; a confident wrong code is worse than an honest
`application_error`. Codes are validated statically by
`spec/architecture/declared_problems_are_known_spec.rb`.

## Setup steps

### prepare

Non-agentic. Runs the commands from `.syrus.yml` `prepare:` (or auto-detected from lockfiles) in the cloned workspace. Explicit commands hard-fail on error; auto-detected commands soft-fail with a warning so a wrong guess doesn't block the first run. Per-timeout: 10 minutes per command.

Present in: `initial`, `pr_comment`, `chat_feedback`, `ci_failure`, `retry`, `auto_merge`, `landing_validation`, `merge_train_validation`, `external_pr_merge`, `merge_train`, `coding_handoff`, `skill`, `main_branch_repair`.

**Empty/uninitialized remotes.** `WorkflowWorkspace#clone_and_checkout` (called at the start of `prepare`) auto-recovers when a freshly-created GitHub repository has zero branches — for example, when GitHub hasn't finished async-provisioning its auto-init commit yet, or auto-init was disabled. When the branch-scoped clone fails, Syrus checks whether the remote genuinely has no branches at all (`git ls-remote --heads`); if so, it clones the empty repository, creates the configured default branch locally with a minimal initial commit, and pushes it before continuing. A log line in the Run transcript notes when this happened. Any other clone failure — most commonly a `default_branch` that doesn't match what's actually on GitHub — still fails the step as before.

**Plugin detection.** Right alongside `RepoPrepPlan.for`, `prepare` also runs `RepoPluginDetector.for(workspace.path)` against the freshly-cloned workspace and records the result as the `detected_plugins` Workflow artifact (`workflow.set_artifact!("detected_plugins", [...])`, readable back via `workflow.detected_plugins`) — the union of every enabled `:prepare_detector` and `:preview_provider` plugin's `detect?(repo_path)` match, e.g. `["ruby", "syrus-rails", "javascript"]`. Computed fresh every Run rather than cached on `Repository`, so a repo's language mix never goes stale. Any later Step in the same Run (or extension point without its own natural per-repo gate, such as `:prompt_injector`) can read `workflow.detected_plugins` instead of re-deriving file-existence checks. The Job/Workflow detail page renders it as a "Detected: …" line on the workflow card. See `config/syrus_docs/plugins.md` for the underlying extension points.

## Agentic implementation steps

Each Workflow stores a concrete `agent_provider` when Syrus creates it, and
retrying a failed Step inside that Workflow keeps using the pinned provider.
Each Job also has a future-workflow provider setting: `default`, `claude`, or
`codex`. `default` resolves the current repository/user default at workflow
creation time; explicit values pin newly-created workflows for that Job to the
selected provider.

Operator-triggered retry-with-provider actions are one-shot overrides. They
create that retry or follow-up Workflow with the requested provider, but they do
not rewrite the Job's future-workflow provider setting or any existing Workflow
pin.

### implement

Agentic. The primary coding step: the agent reads the issue, explores the repo, writes code, and commits. Used in initial and retry workflows.

In `initial` and `retry` (and `respond` in the feedback workflows), the agent step is always a bare top-level step — it runs exactly once, unconditionally, regardless of whether adversarial review, visual review, or a grade loop are configured for the repository. The `adversarial_review`, `visual_review`, and grader retry loops that follow only decide whether (and how) that work gets revised; see the `adversarial_review` step and the `format`/`generate` section below.

**No-change outcome:** When the agent runs successfully but produces no diff
(it correctly determined the requested work was already done), the step raises
`Steps::Base::NoChangesProduced`. The workflow fails as normal for audit
accuracy, but `propagate_fail_to_job!` detects this error class and closes the
Job with `closure_reason: "no_changes"` instead of marking it failed.
`no_changes` is a successful terminal outcome and satisfies downstream Job
dependencies automatically.

If the no-diff run instead matches the background-wait failure pattern — the
agent backgrounded or scheduled work, then ended the turn expecting a later
notification or `ScheduleWakeup` continuation — Syrus raises
`Steps::Base::AgentGaveUpWaiting` instead. That failure is classified as
`agent_gave_up_waiting` and retryable, and it does not close the Job as
`no_changes`; it means the agent misunderstood Step Run execution rather than
proving the requested work was already unnecessary.

**Timeout after commit:** If the agent subprocess times out after it already
created a commit, Syrus does a conservative partial-result check before failing
the step. A clean worktree, an intact branch history, a non-empty diff against
the step's starting SHA, and a non-empty diff against the workflow base are all
required. When those checks pass, the Run records `agent_diff`, `step_agent_diff`,
`head_sha`, and `base_sha`, marks the Step details with
`captured_after_agent_timeout`, publishes the normal Run checkpoint, and lets
downstream graders validate the committed result. Dirty worktrees, no-op commits,
or broken branch history still fail as normal.

**Provider usage-limit outcome:** If the provider reports exhausted usage, quota, credits, billing balance, or a daily/weekly/monthly/model limit, the run records `agent_outcome=provider_usage_limit` and failure classification `provider_usage_limit`. The provider circuit breaker opens immediately for the affected provider/model when known; if the model cannot be determined, Syrus fails closed at provider scope and shows that reason to the operator. When the provider reports a reset time, Syrus schedules the failed Run's auto-retry for five minutes after that reset; Codex structured usage reset windows are preferred over parsing log text, while provider text such as `resets 7am (America/New_York)` is parsed from the failure time. If no reset is known, Syrus uses the conservative provider-circuit backoff. The app projects current-user provider availability into chat and Job payloads: chats using the exhausted effective chat provider and Jobs using an unavailable agent provider show a warning with provider label, state, reason, retry/reset timing, evidence source, and observed time where available until the window expires/restores or the operator switches that chat/Job to another configured provider. Transient provider circuits use the non-red provider-unavailability treatment.

**Provider availability pause:** Before the first Run and between Steps,
`StepDispatcher` checks the Workflow's pinned `agent_provider` against the
current user's per-agent pause threshold. Agent Settings stores these thresholds
on the user; each provider defaults to 10%, and 0 disables automatic
provider-availability pauses for that provider. When structured Codex or Claude
usage is below the threshold, or any provider has an active usage-exhausted
signal, Syrus records `pause_reason: provider_availability` and schedules a
recheck instead of creating the next Run. Running steps finish first. Codex and
Claude rechecks refresh the usage snapshot when stale so Workflows resume
automatically once usage is above threshold. Operators can force a recheck or
"Resume anyway" from Agent Settings or the usage banner; the override is
per-user/per-provider and only suppresses pauses until newer provider evidence
arrives.

**Provider failover policy:** Agent Settings persists a disabled-by-default
agent-provider failover policy for admission/retry selection before a Workflow
has started. The policy stores an ordered provider list and a cause list
covering usage exhausted, usage low, rate limited, provider transient/circuit
open, and auth error. Only providers returned by
`User#configured_agent_providers` are selectable at use time, so the policy
never chooses an unconfigured provider. Auth errors are modeled for visibility
but excluded from the default automatic-failover causes, and explicit Job
provider pins are respected unless the separate `override_explicit_pins` setting
is enabled. Automatic failover records `provider_failover_decision` on the
Workflow artifacts and app payloads project that as `provider_failover` on Job
detail, dashboard rows, repository Job rows, compact Job payloads, and Workflow
cards. The payload includes original and selected provider labels, automatic vs
operator mode, reason, decision time, and an unavailable-provider evidence
summary when available. This policy does not switch chat providers or enqueue
`SwitchChatProviderJob`.

**Claude usage probe:** `ClaudeUsageProbe` (`plugins/claude_agent/app/services/claude_usage_probe.rb`)
mirrors `CodexUsageProbe` as a proactive, ground-truth signal for Claude/Anthropic
usage instead of relying solely on reactive error-text classification. It makes a
minimal `POST /v1/messages` call (1 `max_tokens`, the cheapest Haiku model) using
the user's stored Claude Code OAuth token with the `anthropic-beta:
oauth-2025-04-20` header, then reads Anthropic's `anthropic-ratelimit-unified-5h-*`
/ `-7d-*` response headers to classify `available` / `warning` (>= 85% utilization)
/ `exhausted` (>= 100%). Results are persisted via
`ProviderAvailabilityEvidence.record_claude_probe!` (`source: "usage_probe"`,
`account_id: nil` — there is no Claude equivalent of `CodexAccountScope`) and gated
on the same 10-minute staleness window as Codex. It is invoked opportunistically —
no dedicated cron — from `AgentProviders::Claude#invoke`/`.invoke_one_shot` after
every Claude agent call, and from `ProviderAvailabilityPause#refresh_stale_usage`
as a pre-Run gate check, exactly like Codex's wiring. It feeds Agent Settings'
usage snapshot/depletion display and the threshold-based provider-availability
pause above; reset offsets from Anthropic's headers are anchored to the probe's
`observed_at` timestamp, with Syrus adding its normal retry buffer when
scheduling a retry. It also feeds `ProviderCircuitBreaker`: fresh `exhausted`
probe evidence can open the Claude circuit before any Run fails, and fresh
`available` evidence suppresses false-positive circuit opens, the same as Codex
evidence already does.

### run_skill

Agentic. The `skill` workflow's equivalent of `implement`: resolves the Job's
`skill_name` via `Skills.for(repository:, name:)` (repo-local
`.syrus/skills/<name>/SKILL.md` override, else a built-in `Skills::` class),
renders the resolved definition's instructions with `skill_args` substituted
(`Skills::Renderer`, `{{key}}` placeholders — same convention as
`Prompts::ScheduledTask`), and invokes the agent. Records `skill_source`
(`repo_override`/`built_in`) and the resolved path/class onto the Run before
invoking the agent, so provenance is captured even for a no-diff run.

**No-change outcome:** identical to `implement` — a successful run with no
diff raises `Steps::Base::NoChangesProduced`, which `propagate_fail_to_job!`
turns into a `closure_reason: "no_changes"` Job closure instead of `:failed`.
This is the intended outcome for read-only skills (an `investigate` skill) and
purely operational skills that only report.

As with `implement`, a no-diff run that matches the background-wait failure
pattern raises `Steps::Base::AgentGaveUpWaiting` instead of
`Steps::Base::NoChangesProduced`, so it is visible as a retryable
`agent_gave_up_waiting` failure rather than a successful no-op skill.

`Steps::Summarize` treats `run_skill` the same as `implement` — it resumes the
agent session from whichever of the two ran, so `run_skill → summarize →
pr_open` composes exactly like `implement → summarize → pr_open`.

### respond

Agentic. Addresses PR review feedback or chat feedback. Reads the new comments and makes the requested changes.

### analyze_and_fix

Agentic. Inspects failing CI checks and fixes the root cause. Used in `ci_failure` workflows.
When an iteration makes no new diff and repeats an earlier `report_main_concern`
for the same observed main SHA, failing grader/test list, and normalized reason,
Syrus treats it as `blocked_by_main`: the current retry loop's remaining grader
check steps are skipped and the workflow proceeds to `summarize_amend`/`push`.
If GitHub Actions reports that a job failed before repository tests ran
(for example runner setup or action-download infrastructure failures), Syrus
records the CI infrastructure reason and does not start an agentic repair
workflow for that signal.

### coding_handoff_fix

Agentic. Used inside the `coding_handoff` grader retry loop before any PR exists. Repairs required grader failures on the captured handoff branch with a fresh workflow-agent turn. The prompt includes original Job context, committed handoff branch metadata, recent branch commits, and `Prompts::GradeFailureFeedback`.

### landing_fix

Agentic. A focused repair step inside `auto_merge` and `merge_train` workflows. Runs only after final graders fail on the exact PR branch being landed; successful repairs are pushed before the merge API call.

### manual

Agentic. Operator-triggered free-form step; prompt is supplied at dispatch time.

### format

Non-agentic. Runs `.syrus.yml`'s `formatters:` commands, each scoped to its
own `files:` glob intersected with this iteration's diff (`git diff
--name-only <base>...HEAD`) — a formatter whose glob matches nothing in the
diff is skipped. With no `formatters:` key at all, no formatting runs at
all — the safe default, since a repo that never configured formatting
should never receive unsolicited autocorrect commits. An explicit
`formatters: []` (a blank array) opts into the deterministic
formatter/linter-autocorrect commands language plugins register under the
`:autofix_command` extension point (Ruby's `bundle exec rubocop -a`,
JavaScript's `npx eslint --fix .`/`npx prettier --write .`, Go's `gofmt -w
.`, Python's `ruff format .`/`black .`), each gated on the plugin detecting
its own config signal in the repo (e.g. Ruby only offers `rubocop -a` when
`.rubocop.yml` is present) and on the diff being non-empty. `formatters:
false` (or `off`) explicitly disables formatting altogether, including the
plugin defaults. Commits any resulting changes. A
command failing is always soft — logged as a warning and skipped, the same
non-fatal posture `prepare`'s auto-detected commands use — since a broken
formatter must never block the workflow the way an explicit `.syrus.yml`
grader failure does; whatever it managed to fix is still committed.

### generate

Non-agentic. Runs `.syrus.yml`'s `generated:` commands
(`command`/`sources`/`generates`/`codegen_ignore`), each scoped to its own
`sources:` glob intersected with this iteration's diff the same way
`format` scopes `formatters:` (an entry with no `sources` configured always
runs). Commits any resulting changes, which is effectively the `regen ==
committed` check: if the regenerated output already matches what's
committed there's nothing to commit. Entries marked `codegen_ignore` are
skipped here — that flag exists because their generator is non-deterministic
across environments (e.g. `db:schema:dump`'s SQLite vs. MySQL output), so
auto-committing their regenerated output would introduce environment noise
instead of fixing anything; that invariant is meant to be grader-validated
instead. There is no plugin-provided default for codegen — it's inherently
repo-specific — so this step simply no-ops when `generated:` isn't
configured. `generated: false` (or `off`) explicitly disables it. A command
failing is always soft, same posture as `format`.

Both steps are inserted as repair steps of the grader retry loop in `retry`,
`pr_comment`, and `chat_feedback` workflows (`repair: [ implement | respond,
format, generate ], check: [ grader_fanout, grader_collect ]`), so they rerun
on every retry iteration right before graders check again — a style
regression or stale generated output the agent's latest edit reintroduced
gets fixed for free before the next grade rather than costing another agent
turn. See [`plugins.md`](plugins.md#autofix_command) for the
`:autofix_command` extension point contract and the bundled providers `format`
falls back to.

`initial` shapes the same loop `repair_first: false` instead: `repair: [
implement ], check: [ format, generate, grader_fanout, grader_collect ]`.
Initial's `implement` is always a top-level step that runs before this loop
is ever consulted (see below), so the first grading pass runs the
non-implement pipeline directly against that work; `implement` only comes
back as a repair step once a grader iteration actually fails.

None of `format`, `generate`, or the `grader_fanout`/`grader_collect` check
phase is materialized as a Step by default. `Workflows::Base.grader_retry_loop`
resolves `RepoGradeLoopPlan.for_job(job)` before the workspace is cloned
(mirrors `RepoAdversarialReviewPlan`/`RepoVisualReviewPlan` — reads
`.syrus.yml` from the repository's default branch through GitHub) to decide
whether the repository's `.syrus.yml` actually configures `formatters:`,
`generated:`, or `grade:`. A freshly onboarded repository with no
`.syrus.yml` yet gets no grade loop at all — nothing to hide, since no Step
rows are created for it (`retry`/`pr_comment`/`chat_feedback` still get a bare
`implement`/`respond` step in that case; `initial`'s top-level `implement`
covers the same need). As soon as any one of the three is configured, the
whole grade loop materializes together: the agent step, whichever of
`format`/`generate` are actually configured, and `grader_fanout`/
`grader_collect` (the check phase always appears once the loop exists, even
if only `formatters:` or `generated:` triggered it — there is no way to retry
without a check). This gating only applies to the autofix-enabled call sites
(`initial`, `retry`, `pr_comment`, `chat_feedback`); `ci_failure`, `skill`,
`main_branch_repair`, and `external_pr_feedback` always materialize their
grader check unconditionally, since grading is the entire point of those
repair loops.

## Review and quality steps

### adversarial_review

Agentic. An independent reviewer agent critiques the implementation, calls the available `submit_adversarial_review` MCP tool name with a verdict and findings, and any workspace changes it makes are discarded. Runs in a bounded loop before graders when `adversarial_review.rounds > 0`.

Every workflow that has this loop (`initial`, `retry`, `pr_comment`,
`chat_feedback`, `external_pr_feedback`) leads with a bare top-level
`implement`/`respond` step that runs regardless of whether adversarial review
is configured, so the loop is always review-first: iteration 1 is
`adversarial_review` alone, reviewing that top-level step's diff directly.
A `needs_work` verdict always inserts a repair `implement`/`respond`,
unconditionally, regardless of remaining review budget; the repair pairs with
another review whenever budget remains. Once the review that just ran was the
last one `rounds` allows, its `needs_work` repair runs alone, with no trailing
review — there's no budget left to act on further feedback. `rounds: N` seeks
exactly N review opinions, each reacted to with exactly one repair; the loop
never fails the workflow on its own. See [`adversarial_review.md`](adversarial_review.md).

### visual_review

Agentic. An independent reviewer agent drives a headless browser against its own `start_preview` instance to catch visible defects, then calls the available `submit_visual_review` MCP tool name with a verdict (`approved`, `needs_work`, or `skipped`) and findings; any workspace changes it makes are discarded. Runs in a bounded, review-first loop immediately after the `adversarial_review` loop and before the grader retry loop, in `initial`, `retry`, `pr_comment`, and `chat_feedback` workflows, gated by `visual_review.enabled` in `.syrus.yml` or the instance-wide `Feature.visual_review_enabled?` default (see [`syrus_yml.md`](syrus_yml.md) and [`visual_review.md`](visual_review.md)). Like `adversarial_review`, iteration 1 is `visual_review` alone, reviewing whatever `implement`/`respond` step (or the tail of a preceding `adversarial_review` loop) already ran before it — there is no redundant leading `implement`/`respond` inside this loop's own iteration 1.

Before spending an agent turn, the step applies `visual_review.when_files_changed` as a deterministic pre-filter — same glob semantics as a grader's `when_files_changed` — and skips immediately (verdict `skipped`, no agent turn) when configured and no changed file matches. When the agent does run, it reads the `submit_test_plan` artifact's `visual_review_recommended`/`visual_review_reason` fields (set by the implementing agent) as a hint, but makes its own independent go/no-go call before ever starting a preview. `needs_work` always inserts a repair `implement`/`respond` iteration, the same way `adversarial_review`'s does; `approved` and `skipped` both exit the loop early.

If the reviewer agent finishes without calling its required MCP tool (`submit_adversarial_review` / `submit_visual_review`), the step raises and `RunFailureClassifier` records `missing_required_tool_call` (confidence 0.85, retryable). Both steps discard the reviewer's workspace changes before this failure is raised, so there is no partial state a retry could compound — `WorkEngine::RepairExecutor` picks it up on the normal 5m/20m/1h auto-retry backoff instead of surfacing as an operator-action-required stuck-job alarm.

### visual_diff

Agentic. Deferred before/after comparison over already captured visual-review screenshots. The workflow checks out the Job's merge-base against `Job#effective_base_branch` as the before revision, starts the same preview/browser capture path from that baseline workspace, asks the agent to submit matching baseline screenshots with `submit_visual_artifact`, then pairs them with the prior visual-review after screenshots into a durable `visual_diff_comparison` typed artifact. It runs as its own low-priority `visual_diff` workflow, owns no Job lifecycle transition, and automatic instances skip or cancel once the Job is already approved, landing, or closed. A separate manual Job action can still dispatch it for explicit operator inspection.

### grader_fanout

Non-agentic. Reads grader definitions from `.syrus.yml` and materializes one `grader` Step per configured grader command. Run once at the start of each check cycle.

Grader materialization remains sequential within the current workflow workspace.
Landing-specific fanout is not enabled; any future design needs isolated
workspaces for grader side effects before multiple grader Runs can overlap.

Before matching a grader's `when_files_changed` globs, this step also asks
every registered `:affected_test_analyzer` plugin (see
[`plugins.md`](plugins.md#affected_test_analyzer)) whether it can more
precisely resolve which files this diff actually affects — real
import/dependency-graph analysis instead of a glob's path-pattern guess. A
confident answer is added to the matched-file set (never removed from it),
so it can only turn a would-be skip into a run; no registered analyzer, a
declining analyzer, or one that raises all fall back to plain glob matching
against the raw diff. This expanded set is never used for the
`grade_plan_changed_files` artifact or its fingerprint, which stay a literal
diff for comparison against other landing-validation-cache fingerprints.

### grader

Non-agentic. Runs a single grader command (e.g., `bin/rspec`). Required graders must pass; non-required graders warn on failure.

Syrus does not mutate grader commands for specific test frameworks. If a command needs multiple formatters, coverage toggles, parallelization, or CI-only filtering, put that policy in `.syrus.yml` or a repository wrapper script such as `bin/rspec-fast`.

Graders declare a single command and optional `phases:`. Syrus chooses the
phase from workflow context and runs only graders whose `phases` include it:
`review` before operator approval, `landing` after approval, and `ci` for
`ci_failure` plus `main_grader` workflows. Put cheap smoke/structural checks in
`review`, full suites in `landing`, and CI-only checks in explicit `ci` phase
graders.

Speculative `landing_validation` workflows use the `landing` phase. Their
`when_files_changed` selection is computed against the predicted post-merge
base, not the current `origin/main`.

An earlier `fast:` command selected a parallel variant for landing trigger
kinds and for grade-loop iterations after the first, back when `run:` was
serial. That meant the first grader pass of every workflow — the common case —
ran single-threaded, and thirteen trigger kinds were in neither list and never
reached the fast path at all. `run:` is the parallel command now, so `fast:`
has been removed entirely: it is no longer parsed, and declaring it in
`.syrus.yml` has no effect.

An older `ci:` alternate command is still parsed for compatibility. It expands
into a separate `<name>-ci` grader whose only phase is `ci`; new configs should
spell that out directly.

`grader` Runs also persist bounded command spans for top-level phases inside
composite commands. The splitter recognizes conservative top-level `&&`, `||`,
and `;` operators outside quotes and shell groupings, then labels common Syrus
phases such as `bundle check`, `bundle install`, `db:test:prepare`, `rspec`,
`rubocop`, `frontend tests`, `frontend build`, `website build`, `migration
checks`, `eager load check`, and `production build boot`. Commands that are too
complex to split safely fall back to one whole-command span with metadata naming
the fallback reason.

### grader_collect

Non-agentic. Aggregates grader results. Fails the check cycle if any required grader failed; succeeds otherwise.
Failed collect steps still write grader loop timing before raising, so landing
repair loops show whether the failed attempt actually spent time running graders.
In `ci_failure` workflows, `grader_collect` may be skipped after a repeated
no-op `analyze_and_fix` main-concern diagnosis so the workflow can publish
earlier repair commits without rerunning known non-actionable graders.

### grade

Non-agentic. Legacy single-grader step; prefer `grader_fanout`/`grader`/`grader_collect` for new workflows.

## Summary and PR steps

### summarize

Agentic. Asks the agent to call the available `submit_summary` MCP tool name with a PR title, body, and operator-facing summary. Skipped if the upstream agentic step (`implement` or `run_skill`) already called `submit_summary`.

### summarize_amend

Agentic. Same as `summarize` but used after `respond` or `analyze_and_fix` to produce the follow-up commit message for this revision. It does not refresh the canonical Job title, PR body, or test plan.

### refresh_job_metadata

Agentic. Runs after successful `pr_comment` and `chat_feedback` workflows. Asks the agent to call `submit_job_metadata` with either `changed=false` for narrow fixes or canonical Job/PR metadata when feedback changed the Job's effective intent. The subsequent `push` step applies changed metadata to direct Job titles, managed PR title/body, Job detail summary/test plan, and search indexing.

### test_plan

Agentic. Asks the agent to call the available `submit_test_plan` MCP tool name with reviewer-facing test steps. Skipped if `implement` already called `submit_test_plan`. Follows `summarize` in initial workflows.

### pr_open

Non-agentic. Pushes the branch and opens the PR using the title/body from workflow artifacts. Falls back to `PrSummarizer`, then to a templated default if no agent-authored copy is available.

When a duplicate retry workflow reaches `pr_open` after a newer workflow has
already published the same PR branch, Syrus marks the older workflow
superseded/cancelled instead of surfacing a nonretryable branch-divergence
failure. Real branch divergence with no newer successful publisher still
requires operator review.

### review_plan

Agentic, but best-effort — never fails the parent Job/Workflow. Optional
step, opt-in via `.syrus.yml` `review_plan: true` (see [`syrus_yml.md`](syrus_yml.md)). Runs after `pr_open` in chains that end with
`initial_pr_finish_steps`. Resumes the agent from the last successful
`implement` session and asks it to call `submit_review_plan` with a handful
of specific, high-signal "pay attention to X because Y" points anchored at
`file`/`line`. On success, formats the artifact and posts (or upserts) a PR
comment; an empty item list posts nothing. Any failure anywhere in the step
— agent error, missing tool call, MCP sidecar unavailable, GitHub API error
— is logged and swallowed rather than raised. See
[`review_plan.md`](review_plan.md) for the full feature reference.

## Push and rebase steps

### push

Non-agentic. Pushes the PR branch, applies any `job_metadata` refresh artifact, and updates managed PR footers. On a non-fast-forward rejection, fetches and attempts a deterministic rebase, retrying the push if clean. If the rebase conflicts, dynamically inserts `push_agent_rebase` → grader repair loop → `push_after_rebase`.

### push_agent_rebase

Agentic. Resolves a rebase conflict mid-push-chain.

### push_after_rebase

Non-agentic. Final push after a conflict-resolved rebase.

### auto_rebase

Non-agentic. Attempts a deterministic `git rebase` onto the base branch. On clean rebase, marks `agent_rebase` skipped and proceeds to `force_push`.

### agent_rebase

Agentic. Resolves rebase conflicts. Runs only when `auto_rebase` encounters
conflicts. The rebase prompt requires the agent to attempt concrete
file-by-file conflict resolution before it may abort as "not mechanical"; broad
architecture or commit-history judgments are not sufficient.

Autonomous rebase dispatch is guarded against retry storms. After three
consecutive failed `agent_rebase` / `stack_agent_rebase` attempts for the same
Job and unchanged PR head/base SHA pair, the pollers pause redispatch for
`AppSetting.rebase_failure_cooldown_minutes`. The block is time-boxed:
successful rebases, PR head/base changes, cooldown expiry, or an explicit
operator rebase can allow another attempt.

### force_push

Non-agentic. Force-pushes with `--force-with-lease=<branch>:<observed_sha>` to prevent clobbering concurrent pushes.

### stack_auto_rebase / stack_agent_rebase / stack_force_push

Non-agentic / Agentic / Non-agentic. Same as the single-PR rebase chain but operates across a dependent PR stack in dependency order.

## Landing steps

### mergeability_preflight

Non-agentic. Refreshes GitHub mergeability, mechanically rebases and
force-pushes a ready owned PR branch or same-repository external PR head onto
the current base before landing graders run, runs a local rebase preflight when
GitHub is still computing, dispatches rebase workflows for conflicts, and
short-circuits if a prior landing validation is still valid. Fork external PRs
are checked for mergeability but are not rebased because Syrus cannot push their
head branches.

### speculative_landing_build

Non-agentic. Used only by the feature-gated `landing_validation` infrastructure
workflow. It verifies the current landing workflow's local workspace is still at
the predicted base commit, verifies the candidate PR head when known, fetches the
predicted base from the source workspace, and performs a local `git rebase`
without pushing. Conflicts or stale identities fail only the speculative
workflow; the Job remains approved for the normal landing queue path.

### speculative_merge_train_build

Non-agentic. Used only by the feature-gated `merge_train_validation`
infrastructure workflow. It verifies the current landing workflow's local
workspace is still at the predicted base commit, fetches that predicted base,
builds a scratch integration branch for the next Epic merge-train unit by
mechanically rebasing each member branch in dependency order, and records the
speculative head/tree identity. It never creates a real `MergeTrain`, pushes,
or repairs. Conflicts or stale identities fail only the speculative workflow;
the Epic remains approved for the normal landing queue path.

### auto_merge

Non-agentic. Calls the GitHub merge API. Transient failures defer the Job back to `approved`; a 405 "can't rebase" dispatches the rebase path instead of treating the attempt as terminal.

When a merge succeeds and GitHub returns a merge commit SHA, Syrus stores it as `Job#landed_sha`. `PollAllDeploymentStagesJob` later uses that SHA to detect configured deployment stages from repository tags.

### external_pr_merge

Non-agentic. Calls the GitHub merge API for an `external_pr` Job's `external_pr_number`. If same-repository landing repair produced commits in the workflow workspace, pushes those commits to the PR's actual head branch before merging. Fork PRs are never pushed by this step.

### merge_train_assemble

Non-agentic. Validates that all open Epic child Jobs are approved and the member count is within `AppSetting.merge_train_max_size`.

### merge_train_build

Agentic. Rebases member branches onto a growing integration branch in dependency order. Tries deterministic `git rebase` first; hands conflicts to the agent on failure.

On success it pushes the integration branch and records it as the workflow's required workspace branch, so a later step that resumes on a different worker checks out the train rather than falling back to a member branch. See [Merge Train](merge_train.md).

### merge_train_reconcile

Agentic. Runs on the built merge-train integration branch before prepare, graders, coverage, and landing. Asks the configured agent provider to inspect the integrated tree for cross-Job inconsistencies. No diff is a successful result; focused reconciliation edits are committed onto the integration branch and then the normal gates continue.

### merge_train_land

Non-agentic. Pushes the integration branch, merges one integration PR into base, then comments on and closes the member PRs.

### merge_train_rebase / merge_train_agent_rebase / merge_train_land_after_rebase

Base-moved recovery chain during merge-train landing. `merge_train_rebase` is
non-agentic and attempts a deterministic integration-branch rebase onto the
moved base. `merge_train_agent_rebase` is agentic and is skipped on a clean
deterministic rebase; when the deterministic rebase conflicts, it resolves and
completes that in-progress rebase. `merge_train_land_after_rebase` is
non-agentic and lands the recovered integration branch after validation.

## Coverage steps

### coverage_analyze

Non-agentic. Parses coverage artifacts produced by graders, merges multiple sources, computes diff annotations against the PR diff, stores a coverage artifact on the workflow, attaches a hit-map blob, creates a `CoverageSnapshot`, and evaluates the configured threshold.

### coverage_pr_comment

Non-agentic. Posts the formatted coverage summary as a PR comment when `pr_comment: true` is set in `.syrus.yml`.

## Dependency audit steps

### dependency_audit

Non-agentic. Runs after `coverage_analyze`, in `initial`, `retry`, `pr_comment`, and `chat_feedback` workflows. Always present in these chains, but self-skips at runtime unless the PR diff (`git diff <default>...HEAD`) touched a lockfile owned by a registered `:dependency_audit_command` plugin (Ruby's `Gemfile.lock`, JavaScript's `yarn.lock`/`pnpm-lock.yaml`/`package-lock.json`, Python's `uv.lock`/`poetry.lock`/`requirements.txt`, Go's `go.sum`) — see [`plugins.md`](plugins.md#dependency_audit_command) for the extension point contract.

When a matching lockfile changed, runs each matching provider's audit command (`bundle-audit check --update`, `npm`/`yarn`/`pnpm audit --json`, `pip-audit`, `govulncheck ./...`) and stores the results as the `dependency_audit` workflow artifact. A non-zero exit status is not a step failure — it is how these tools report that vulnerabilities were found, and `dependency_audit`'s `fail_policy` is `:advance` so a broken audit tool never blocks the chain. A clean scan across every scanned ecosystem leaves no `pr_comment_body` in the artifact, so nothing gets posted — a clean scan is a silent no-op. `Steps::PrOpen` posts the formatted findings as a PR comment (alongside the coverage comment) when it opens or updates the PR in `initial`/`retry` workflows.

### dependency_audit_pr_comment

Non-agentic. Posts or updates the formatted dependency-audit comment on an existing PR. Inserted after `dependency_audit` in `pr_comment` and `chat_feedback` workflows, where the PR already exists (mirrors `coverage_pr_comment`). No-ops when the `dependency_audit` artifact has no `pr_comment_body` (no lockfile changed, or every scanned ecosystem was clean) or the Job has no PR yet.

## Preflight grader steps (main_branch_repair)

### preflight_grader_fanout

Non-agentic. Materializes one `preflight_grader` Step per configured grader at the start of a `main_branch_repair` workflow. Unlike `grader_fanout`, this step:

- Runs **all** configured graders regardless of `when_files_changed` (no PR diff exists before the implement step)
- Does **not** check the `GraderConclusionCache` for reuse (always runs fresh)
- Is not inside a retry loop (no `apply_loop_max_iterations!`)

Resolves its grader plan via `LandingGraderPlan`'s `:ci` phase (`main_branch_repair` is one of `LandingGraderPlan::CI_TRIGGER_KINDS`), the same phase `ci_failure`/`main_grader` use — not the `:landing` phase auto-merge/merge-train use. This matters because a repository can configure a lightweight grader for `phases: [landing]` (e.g. plain `rspec`) and a separate, slower, GitHub-Actions-equivalent grader for `phases: [ci]` (e.g. `rspec-ci`, including `:ci_only` specs) that is the one actually reflected in `Repository#ci_health`. Resolving `:landing` here would let preflight report "all required graders passed" without ever re-running the CI-equivalent suite, closing the repair Job on a false positive while the real CI-only failures (and `ci_health`) stayed broken — `MainHealthChangedService.ensure_repair_job!` would then spawn another `main_branch_repair` Job on the very next poll tick, looping indefinitely.

### preflight_grader

Non-agentic. Identical to `grader` but writes logs to `.syrus/grade-output/preflight/<name>.log` to avoid collisions with the main grade loop's per-iteration log files.

Preflight graders use the same command-span instrumentation as normal graders.

### preflight_grader_collect

Non-agentic. Aggregates preflight grader results. Two outcomes:

- **All required graders passed:** Sets the `preflight_passed` workflow artifact, cancels all downstream steps (`prepare`, `implement`, the grade loop, `summarize`, `test_plan`, `pr_open`), and returns. The dispatcher advances past the cancelled steps and marks the workflow succeeded. `Workflows::MainBranchRepair#after_success` detects the artifact and marks the repository's `grader_health` **and** `ci_health` healthy (a preflight pass is conclusive for both, since it re-ran the same `:ci`-phase graders that mark `ci_health` broken) without the agent ever running.
- **Any required grader failed:** Stores `preflight_failures` with each failing
  grader's name, exact command, exit metadata, log path, and captured output
  tail, then logs the failure and returns normally so the chain continues to
  `implement`.

Unlike `grader_collect`, this step never raises `StepFailed` — a grader failure here means "proceed to implement", not "fail the workflow."

The next `main_branch_repair` `implement` prompt includes `preflight_failures`
and tells the agent to reproduce the exact failed command(s), run focused
examples against the failure tail first, and commit once the focused checks pass
before any optional full-suite verification.

## Coding handoff steps

### grader_fanout / grader_collect

Same as above. In `coding_handoff`, they run inside a retry loop repaired by `coding_handoff_fix`.

### local_mode_handoff_fix

Agentic repair step for `local_mode_handoff` grader failures. The operator's local daemon has already committed and pushed the implementation branch, so this worker workflow owns any grader-failure repair. The step uses the latest grader failure feedback, makes the smallest focused branch changes needed for required graders to pass, commits those changes, and must not route repair back to the originating Local Mode chat.

## Grader command spans

`grader` and `preflight_grader` Runs persist `CommandSpan` rows associated with
the Run, Step, Workflow, Job, and spawned process when available. Each span
records sequence, name, command excerpt, start/finish timestamps, duration,
exit status/outcome, hostname, and metadata.

Worker-health correlation reports each span's persisted `finished_at` plus an
effective bounded window. `effective_finished_at` is the earliest available
span finish, owning spawned-process finish, Run finish, or query time; samples
after that bound are excluded. If the effective bound differs from the
persisted span finish, the payload marks the span `truncated: true`, identifies
the source in `truncated_by`, and sets `orphaned: true` when the owning spawned
process ended as `orphaned`.

The Bash timing harness preserves the original single `bash -c` execution,
output capture, timeout handling, and failure behavior. It emits private
framed marker tokens that Syrus strips before writing grade output to
`.syrus/grade-output` or durable `JobLog` rows. Timeouts, stops, and operator
kills close any unfinished span with the Run-level outcome, so a killed slow
grader still shows the active phase.

### apply_suggestions

Non-agentic. Applies structured code-suggestion patches (e.g., from review comments) before the agent responds.

## Step resilience: in-place worker_died retry

When a worker process is killed mid-step (deploy rolling restart, OOM, node eviction), the run is classified as `worker_died`. For **non-agentic** steps (e.g., `prepare`, `push`, `grade`, `auto_merge`), Syrus creates a new Run on the same Step instead of immediately failing it. This repeats up to `Run::WORKER_DIED_STEP_MAX_RETRIES` (3) times before the step fails normally and the operator sees the Retry button.

**Agentic steps** (e.g., `implement`, `respond`) do not use in-place retry. They use the work-engine reconciler's session-resume path so the agent can pick up where it left off with prior conversation context intact. Successful provider session transcripts are retained until the normal `ProviderSession::RETAIN_AFTER_TERMINAL` pruning window expires so later workflow steps can rehydrate resume state after worker movement or deploys.

If Codex resume state is unavailable (`thread/resume failed`, missing rollout JSONL, or equivalent), Syrus classifies the failure as `agent_resume_unavailable`. Automatic failed-step retries carry an explicit no-resume marker so step-specific session fallbacks cannot keep selecting the same stale provider thread. Short synthesis steps such as `test_plan` may retry once in a fresh provider session using bounded durable context from the Job, PR summary, and implementation diff before falling back to deterministic artifacts.

If an agent CLI starts before Syrus finishes delivering the stdin prompt, the
provider may fail immediately with messages such as `no stdin data received`,
`Input must be provided either through stdin`, or `No deferred tool marker found
in the resumed session`. Syrus classifies these as `stdin_race_failed`, a
retryable infrastructure failure, so operators can distinguish prompt-delivery
races from genuine agent/application errors and automatic retry scheduling can
handle them through the normal retryable-failure path.

Retry scheduling for agentic steps is handled by `WorkEngine::RepairExecutor`, which creates `AutoRetryAttempt` rows and enqueues `AutoRetryJob` so retry classification and remediation stay under unified work-engine authority.

The in-place retry count is per-step per-workflow, not per-job. Each step failure classification is persisted as a `RunFailureClassification` row so the reaper and `RunJob` can accurately count prior retries.
