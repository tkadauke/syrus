# Workflow-step internals


Each Syrus workflow is a chain of steps. Steps are either **agentic** (invoke the agent CLI) or **non-agentic** (run service code directly). Step kinds are registered in `app/models/step/kind.rb`.

Agentic workflow processes receive short-lived Syrus CLI authentication in
their environment: `SYRUS_CLI_URL` points at the app API and
`SYRUS_CLI_INVOCATION_CONTEXT` carries a signed invocation context for the
current Run. The `syrus` CLI prefers that internal context over
`~/.syrus/credentials`, so agent shells can call app API commands without a
long-lived human API token. The token resolves to the Run's user and is scoped
to the current run/job/repository boundary; app API requests that try to cross
that boundary are rejected or filtered. Invocation-context CLI requests are
read-only by default: mutating app API calls return `403` and must go through
the MCP/admin confirmation path instead. Each internal CLI request writes an
operational audit event with user, repository, job, workflow, run, command
namespace, and high-level outcome, with invocation tokens and lease identifiers
redacted.

Safe examples inside an agentic Run include `syrus job show JOB-<id> --json`,
`syrus job log JOB-<id>`, `syrus job diff JOB-<id>`, and read-only repository
or identity commands such as `syrus repo list --json` and `syrus whoami --json`.
The bundled credential store plugin also exposes
`syrus credential_store lease` plus the `syrus credential exec` and
`syrus credential ssh-agent` wrappers as narrow runtime-authenticated
exceptions to the read-only default. `lease` returns only metadata. The wrapper
commands materialize credential payloads only inside the child process
boundary, redact child output, clean up temporary material, and record
credential access/completion audit rows without writing plaintext payload
material to transcripts.
Human operators still use `syrus login` and `~/.syrus/credentials` outside
Syrus-managed runtimes; a workflow subprocess should not create or depend on
that file. Future CLI work that needs in-runtime data, such as target graph
query commands, should build on this same runtime
availability layer instead of inventing a second authentication path.

`Step` is also the workflow DAG node record for the distributed-workflow
foundation; Syrus does not create a separate node table. Every Step has a
`placement_policy` column. The default is `pinned_workflow_workspace`, which is
the legacy behavior: run on the workflow's mutable workspace and owning storage
key. Other supported policies are `immutable_source_checkout` for read-only
validation from a durable source snapshot, `control_plane` for fanout/collect
or orchestration work that does not need a repository checkout, and
`external_context` for checks that run against a connector or runtime outside
the checkout.

The non-pinned policies are gated by both the instance `distributed_workflow_dag`
feature flag and the repository's `distributed_workflow_dag_enabled` setting.
When either gate is off, newly materialized Steps stay pinned even if their
`Step::Kind` entry declares a future distributed placement. Descriptive
projection metadata such as `projected_target_label`,
`projected_target_fingerprint`, `projected_resource_key`, `barrier_group`,
`barrier_labels`, and source-snapshot references stays in `steps.details`; only
scheduler-hot placement is a column.

If an active Workflow's owning worker or storage disappears, reconciliation
rebuilds its mutable checkout on a live worker from the newest remotely
verified source snapshot, published agent checkpoint, or safe durable branch.
When a mutation Step has succeeded, that source must be the exact head recorded
by the latest successful mutation; an older but otherwise valid snapshot is not
a recovery candidate. The rebuilt checkout must resolve to the recorded commit
before ownership is transferred. Stranded immutable grader Runs are requeued
before their `grader_collect` barrier, and later phases continue normally.

A Workflow that has not committed anything yet -- the state between a
successful `prepare` and the first mutation -- has no snapshot, no published
checkpoint and no branch of its own. Its recovery candidate is the Job's
effective base branch, the same ref `prepare` checked out, because no mutation
has been recorded and so there is nothing of the agent's to lose. This is the
common case: it is what "the worker holding a just-prepared workspace was
replaced" looks like. The base branch stops being a candidate the moment any
mutation succeeds, since reconstructing from it would then publish or grade a
checkout with the implementation missing.

Syrus never replays a running mutable Step: when no durable head exists,
validation disagrees, or a mutable Run may still have side effects, the attempt
fails with the retryable
`workspace_recovery_failed` outcome. Normal automatic retry then releases the
old WorkUnit locks and starts a fresh Workflow from the Job's effective base,
including approved dependency branches.

The Step whose active Run was interrupted remains failed and retains the
failure classification. Downstream Steps that never started are cancelled,
so the workflow graph distinguishes the causal failure from work that did not
run. Manual recovery follows the same boundary: Syrus offers a fresh
implementation retry and does not advertise an in-place failed-Step retry for
this outcome.

That retry is load-bearing, and it is worth knowing how it can be lost. A Run
the repair ended carries no exception and no agent output, so re-classifying it
finds nothing to read. `RunFailureClassifier` therefore refuses to overwrite a
confident verdict with its own no-evidence fallback
(`application_error, retryable: false`); without that refusal, the
re-classification `AutoRetryJob` performs before acting turned a retryable
outcome into a non-retryable one, skipped the attempt as "failure is not
retryable", and left the Job failed with `failure_count` 0 and no second
Workflow.

`StepDispatcher` keeps the legacy one-successor walk unless distributed DAG
placement is enabled for both the instance and the repository. With those
rollout gates on, it treats explicit `depends_on_ids` edges as the
readiness source for the distributed region: every queued immutable-source Step
whose dependencies are terminal can receive a Run in the same dispatch pass.
A queued sibling whose dependencies are still active, failed admission, or could
not be placed does not block unrelated ready immutable-source siblings. Serial
steps still serialize the chain, and collect/barrier Steps wait until every
explicit dependency is terminal.

**A fanout that materializes parallel Steps must write those edges.** Placement
alone is not enough, and the failure is silent: with `depends_on_ids` empty,
`Step#dependencies_settled?` falls back to the linked-list predecessor, so
sibling N waits on sibling N-1 and the ready set can only ever contain one of
them. The Steps still get immutable-source placement and per-Run Solid Queue
keys — everything *looks* configured for parallelism — and they still run
strictly one at a time. `preflight_grader_fanout` shipped in exactly that state
and ran 14 graders single-file, about a second apart, with the gate fully on
in production. Both grader fanouts now do the same two things: link graders to the
shared continuation when the gate is on, and state the fan-out/fan-in as
`depends_on_ids` edges.

`immutable_source_checkout` Steps materialize a detached checkout from the
Step's `source_snapshot_id`. Before running the Step command, Syrus runs the
normal repository prepare plan once per worker storage key, Workflow, source
snapshot SHA, and prepare fingerprint. Later immutable-source Steps on the same
worker with the same snapshot and fingerprint reuse that prepared state instead
of rerunning prepare. A changed source snapshot SHA or changed resolved prepare
plan naturally produces a different cache key. The prepare fingerprint also
includes the normalized worker capability environment: OS, architecture,
declared capability probes, runtime identifiers, and relevant toolchain
versions. Prepared archives and local prepare caches from a different
capability class are rejected before restore, with a log line naming the
metadata mismatch, so macOS-native dependency artifacts are not reused by Linux
graders or vice versa. Each immutable-source Step records its cache hit or miss
in `steps.details["prepare_cache"]`, including
`worker_storage_key`, `workflow_id`, `source_snapshot_sha`,
`prepare_fingerprint`, worker environment metadata, `cache_key`, `cache_path`,
`prepare_source`, and `command_count`. Target-specific prepare is intentionally
not part of this rollout.

Before a queued Run starts, `RunJob` may defer pickup on the selected compute
host if that host is under critical resource pressure or is already running a
resource-guarded Run. This host-local guard applies to `:runs`, `:merges`, and
sticky resume queue workflows and covers agentic Steps plus CPU-heavy grader
work. A deferred pickup leaves the Run queued, records a `run_host_admission`
Workflow artifact and a system JobLog line, then re-enqueues the same Run
without spending a retry or repair iteration. Worker-died auto-retries also
record `failed_worker_*` context and defer while the failed host's fresh health
sample remains critical. See
[`multi_worker.md`](../../../config/syrus_docs/multi_worker.md#per-host-run-pickup-admission).

Job detail workflow payloads expose this runtime placement data on each Step
under `steps[].placement` and dependency/barrier data under
`steps[].dependencies`. Placement fields describe the Step runtime object:
`policy`, source snapshot SHA/ref/tree, worker hostname/storage key, latest
worker-slot metadata, immutable-checkout prepare cache hit/miss, and any
admission block that applies to that Step. Projected target fields such as
`projected_target_label`, `projected_target_fingerprint`, and
`projected_resource_key` remain descriptive target-graph metadata; they explain
what the Step is checking but are not the Step identity.

The UI groups parallel grader batches from generic Step data rather than from a
separate grader-batch model: `grader_fanout` materializes `grader` Steps,
`grader_collect` / `preflight_grader_collect` depend on those Steps, and
`dependencies.barrier_progress` on the collector Step summarizes those grader
dependency states. Individual grader Steps still expose their own Step
dependency edges, target metadata, placement, and admission state, but they do
not present the collector's batch progress as their own. Admission blocks are
likewise Step-scoped. Worker-slot admission artifacts include a `step_id`; host
pickup deferrals include a `run_id`, which the payload resolves back to the
owning Step before showing the block. Sibling Steps therefore remain queued,
running, failed, or completed on their own merits instead of making the whole
workflow look paused.

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

`JobAttachmentContext::StorageUnavailable` uses the same mechanism for
agentic startup failures caused by transient ActiveStorage/MinIO connectivity
while materializing uploaded Job attachments. It declares
`storage_unavailable`, a retryable/deferred problem, so a temporary storage
outage does not become a terminal workflow failure before the provider process
starts.

The declared code is persisted on the Run's diagnostic and read by the layers
that act on the failure — `RunFailureClassifier` returns it directly (with
confidence `1.0`, because it is a report rather than a guess), and
`LandingFailureHandler` persists a derived `landing_failure_code` so later
landing queue and merge-train decisions can tell "rebuild this train" apart
from "this landing is dead" without reparsing the explanation text. Those
layers previously recovered the meaning by matching regular expressions
against the message text, and they disagreed with each other whenever the
wording drifted.

Declaring a problem is **optional and should stay that way**. Most failures are
genuinely opaque at the raise site — a git command failed, the provider
returned something unexpected — and are still classified downstream from
process outcomes, exception classes and log evidence. Declare a code only where
the step was actually certain; a confident wrong code is worse than an honest
`application_error`. Codes are validated statically by
`spec/architecture/declared_problems_are_known_spec.rb`.


Per-step harness behavior remains in [`config/syrus_docs/workflow_steps.md`](../../../config/syrus_docs/workflow_steps.md).

## Grader command-span telemetry

## Grader command spans

`grader` and `preflight_grader` Runs, plus immutable-source checkout prepare
commands, persist `CommandSpan` rows associated with the Run, Step, Workflow,
Job, and spawned process when available. Each span records sequence, name,
command excerpt, start/finish timestamps, duration, exit status/outcome,
hostname, and metadata.

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


## Provider implementation notes

`agy` is the Antigravity workflow provider. `SYRUS_AGY_MODEL` and
`SYRUS_AGY_EFFORT` are forwarded into the isolated Antigravity provider home as
Syrus-owned configuration hints, and Agy loads Syrus workflow tools from the
provider home's `~/.gemini/config/mcp_config.json` sidecar entry.

**Muse workflow provider:** `muse_agent` registers `AgentProviders::Muse`
through the same `:agent_provider` plugin extension point as Claude and Codex.
Muse is installed but disabled by default; enable the `muse_agent` plugin from
Admin -> Plugins after the worker/backend image has the `muse` CLI on `PATH`
and pilot users have saved Muse API keys. A Muse-backed workflow uses the
saved `User#muse_api_key`, stores provider state under a per-workflow Muse
home, and writes
`~/.config/muse/settings.json` in that home with a stdio
`syrus-mcp-sidecar` server for the current Run. Muse uses dotted MCP tool names
(`syrus-mcp-sidecar.submit_summary`) and normalizes its `payload_type` JSONL
envelope into `ClaudeTranscript`, so
`Steps::Base#log_mcp_required_tool_health` sees available/called tools the same
way it does for Claude and Codex. If a required workflow tool such as
`submit_summary`, `submit_test_plan`, `submit_adversarial_review`, or
`submit_visual_review` is absent from Muse's
reported MCP inventory, the invocation sets `agent_outcome=mcp_sidecar_failed`
and asks the running process to stop instead of waiting for the normal agent
timeout.

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


## Placement inference history

Syrus does not read a Job's title or body to choose a host. It did once, by
matching platform keywords, and that could not be made to work: a bug report
filed from a phone matched `iphone` inside its User-Agent, and a Kotlin/JVM Job
matched the sentence saying iOS was *"intentionally out of scope"*. Both were
planned for macOS, which no worker advertises, so each blocked on
`no_capable_worker` and retried indefinitely. Because nothing is guessed, there
is also no "mutually incompatible hosts" case to resolve: a request naming
several platforms is ordinary work on the declared or default host.


## Grader configuration and target-health history

An earlier `fast:` command selected a parallel variant for landing trigger
kinds and for grade-loop iterations after the first, back when `run:` was
serial. That meant the first grader pass of every workflow — the common case —
ran single-threaded, and thirteen trigger kinds were in neither list and never
reached the fast path at all. `run:` is the parallel command now, so `fast:`
has been removed entirely: it is no longer parsed, and declaring it in
`.syrus.yml` has no effect.

When `grader_collect` records a grader conclusion, it also records a persistent
`TargetHealthRecord` for each materialized grader target. The record stores the
target label, project id, repository, commit SHA, input fingerprint, command
fingerprint, environment fingerprint, status, timing, and log artifact
references.

`grader_fanout` and `preflight_grader_fanout` stamp each materialized grader
Step with deterministic target fingerprints. The input fingerprint covers the
target's declared source files, dependency target source files, dependency
labels, and owning `.syrus.yml` files. The command fingerprint covers the
target command and execution config, including dependencies, phases,
requiredness, timeout, file scope, owner config path, and target metadata. The
command fingerprint also includes declared execution capabilities. The
environment fingerprint covers locally available runtime/toolchain inputs,
normalized worker capabilities, OS, architecture, runtime identifiers, relevant
toolchain version probes, prepare dependency targets, prepare commands, common
lockfiles, and version files such as `Gemfile.lock`, `package-lock.json`,
`.ruby-version`, and `.tool-versions`.

`grader_collect` copies those stamped fingerprints into `TargetHealthRecord`.
Older or already-materialized grader Steps that do not have
`target_fingerprints` keep the compatibility fallback: input fingerprint comes
from the workflow source snapshot's explicit fingerprint when present, then its
tree SHA, then its source SHA, and finally the commit SHA. Syrus never uses the
workflow-local source snapshot row id as a target-health input fingerprint.
Workflow artifacts keep only
`target_health_record_refs` entries with record ids and identifying labels; the
database row is the primary store so later workflows can query target health
outside the workflow that produced it.

Before `grader_fanout` materializes a selected `grader` Step, normal affected
target runs check the same target-health proof used by format/generate:
current target fingerprints must have a latest healthy record, and every
executable dependency target must also be healthy for its current fingerprints.
A cache hit skips Step materialization, logs the reason, and records an entry
in `target_health_skipped_targets` on the workflow and fanout Step details.
If a record exists for the same target input and command but a different
environment fingerprint, the forced-rerun reason says the target-health proof
was rejected for an environment/capability mismatch and summarizes the cached
and current capability classes.
Review-phase focused graders should stay scoped to project surfaces with real
workflow execution today; temporary root backstops are appropriate only while a
nested target is visible to TargetGraph but not yet materialized as its own
grader Step. Broad release confidence belongs in landing/CI graders and
main-branch target-health sweeps, not in every review loop.
Baseline `main_grader` sweeps with no previous main SHA are the exception:
they select every configured grader target and bypass both target-health reuse
and successful full-plan `GraderConclusion` reuse so the broad sweep can catch
missed dependency edges or undercoverage that prior affected-target selection
would have skipped.
Landing and validation workflows continue to honor the target graph's
unaffected verdict when no reusable health row exists. Missing historical
health is not evidence that an unrelated target became affected; broad health
coverage belongs to the baseline main-branch sweep instead of each landing.

Target-health narrowing normally stands down on any iteration whose repair
changed code -- the repair is what invalidates the previous iteration's
passes, and "something changed" is the conservative reading. The two landing
definitions (`job_bundle`, `merge_train`) opt out of that coarse reading via
`WorkDefinitions::Base#target_health_narrows_after_code_changing_repair?`,
because `TargetHealthReuse` already answers the narrower question per grader:
it recomputes input, command and environment fingerprints from the
post-repair workspace and requires both a matching passing record and a
reusable dependency closure, so a grader whose transitive inputs the repair
did not touch keeps its pass while one the repair reached does not. Landing
regraded its full required suite after every repair iteration before this --
63 graders on one production repository, roughly fifteen minutes of a strictly
serial lander, to re-prove results from fifteen minutes earlier.

Scoped to landing deliberately: the fingerprints are only as complete as the
target graph's declared inputs and dependencies, so an undeclared coupling
would carry a grader forward that should have rerun. Landing is where the cost
concentrates and where the train's own graders ran minutes earlier. Ordinary
PR and repair workflows keep the conservative behavior.

For PR-facing repair workflows, landing workflows, validation children, and
`main_grader`, fanout also records `grader_target_selections`, one entry per
configured grader target with its affected verdict and target fingerprints.
CI-failure repair uses these entries to spot mapped GitHub checks that failed
after Syrus previously skipped the same target as unaffected, surfacing a
`ci_failed_skipped_target` workflow warning with source-scope and dependency
context. `Workflows::MainGrader` also uses those entries when the workflow
settles: a passing affected subset marks the repository grader signal healthy
only if every unaffected required target still has a matching healthy
`TargetHealthRecord`. A failed unaffected target keeps `grader_health` broken;
missing, stale, or unknown unaffected health keeps it unknown; timed-out,
cancelled, or inconclusive unaffected health keeps it inconclusive. This is how
main-branch target health preserves unaffected target state while avoiding
unnecessary target execution.

The Job/Workflow target graph API projects `grader_target_selections` and
`target_health_skipped_targets` into an operator-facing `explanations` envelope:
affected project counts, selected executable targets, skipped targets, cached
targets with target-health record references, and preview/project choices that
are ambiguous or unavailable. The Target Graph tab renders that envelope above
the graph so operators can understand the fanout decision without opening raw
workflow artifacts.

`grader_collect` folds those entries into the iteration rollup as passed
target-health skips, without recording a new grader conclusion for work that
did not run. Unknown, stale, failed, timed-out, cancelled, or inconclusive
health records are misses, so required graders still materialize and run.


## Publication checkpoint and divergence internals

Before doing anything else, `pr_open` restores the validated implementation from
its `RunCheckpoint` if the workspace does not already contain it. A Job's work
branch exists only in the workspace until this step pushes it, and workspaces
are node-local while each Run is claimed by whichever worker is free — so a
Workflow that hops workers between `implement` and `pr_open` gets a fresh clone
off the base with no implementation in it. `RunCheckpointPublisher` already
pushes every mutation step's commit to a durable remote ref for exactly this
case; until now only `summarize`/`summarize_amend` restored from it, which left
the step that actually publishes the branch as the one step that could not
recover. The restore is opportunistic: if it cannot run, the step behaves as it
did before and `close_empty_new_publication_branch!` still refuses to publish an
empty branch or file the Job as `no_changes`.

**Stacked-parent freshness barrier.** For any Job whose PR base is another open
Job's branch (Epic or not), a parent that was rebased and force-pushed while the
child was running does not cancel the child. Instead, immediately before
publishing, `pr_open` fetches the live parent head and checks that the completed
branch descends from it (`StackBaseFreshness`). The parent head the workspace was
prepared from is recorded in `workflow.artifacts["stack_base_prepared"]`. If the
parent moved, the child's own commits are rebased with `git rebase --onto
<live> <prepared>`, the required graders run again on the rebased tree, and the
check repeats, up to three rebases. A branch that was rewritten is pushed with
`--force-with-lease` pinned to the observed remote tip; a non-rewritten stacked branch
is likewise pushed conditional on the tip observed just before (or on being absent),
so a concurrent update is rejected as a divergence rather than accepted and later
erased by the rollback. After the push the
head is checked against the live parent once more before a PR is opened or the
Job becomes `implemented` (which is what releases dependents). Git cannot make a
push conditional on a different ref, so if the parent moved between the final
check and the push, that publication is rolled back (new branch deleted, or the
previous tip restored, both leased on the pushed head) and recorded in
`workflow.artifacts["stale_publication_rolled_back"]`. If the parent never settles,
the rebase conflicts, or post-rebase validation fails, `pr_open` fails with the
`awaiting_stable_base` problem, keeps the completed work, writes
`workflow.artifacts["awaiting_stable_base"]` with the observed parent heads, and
publishes nothing. Whole-stack restacking remains the recovery path for stacks
that were already published stale.

  Note `BranchDivergenceResolutionEvidence` does **not** back this banner. It is
  consumed only by the three admin MCP tools, its `diff_summary` is
  `base...HEAD` (what the workflow changed, not how the two candidates differ),
  and it is workspace-gated. Don't reach for it to answer operator-facing
  "which option do I pick" questions.
