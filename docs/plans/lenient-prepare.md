# Lenient prepare mode

_Captured 2026-05-11. Design only; implementation should land as one
follow-up issue, with an optional per-issue-label follow-up if the
repository-level setting proves useful._

## Context

`prepare` currently runs before the agentic implementation step for
initial, retry, PR-feedback, and CI-failure workflows. It is useful when
it succeeds because dependency installs and other deterministic setup
work happen outside the agent's turn budget. It is also terminal when it
fails: the `Run`, `Step`, and `Workflow` are marked failed, and the
implement step never runs.

Some repositories want a middle ground. Setup should still be attempted,
but a transient registry outage, flaky install script, or missing local
tool should not necessarily prevent the agent from inspecting the code
and making the requested change.

This plan adds `Repository#strict_prepare`, defaulting to `true`.

## Behavior

| Setting | Behavior |
|---|---|
| `strict_prepare: true` | Current behavior. Any prepare command failure fails the `Run`, `Step`, and `Workflow`; downstream steps do not run. |
| `strict_prepare: false` | Prepare still runs. If any prepare command fails or times out, Syrus records a warning-level terminal state for the prepare `Run` and `Step`, logs the failure, stores failure metadata on the `Workflow`, and advances to the next step. |

This setting controls failure strictness, not whether prepare runs. It is
orthogonal to `syrus-skip-prepare` and `prepare_enabled: false`, which
skip the step entirely.

## Setting Placement

Add a non-null boolean column on `repositories`:

```sql
ALTER TABLE repositories
  ADD COLUMN strict_prepare BOOLEAN NOT NULL DEFAULT TRUE;
```

The repository edit form should expose it near the existing prepare
configuration as an advanced option:

```
[x] Strict prepare
    Fail the workflow if prepare fails.
```

Default `true` preserves every existing repository's behavior. Per-job
or per-issue-label leniency is worth a follow-up (`syrus-lenient-prepare`)
only after the repository-level mode has proven useful; the first
implementation should keep the policy surface small.

Precedence if the label ships later:

1. Skip-prepare label or repo setting wins and does not run prepare.
2. Lenient-prepare label can relax strictness for one job.
3. Repository `strict_prepare` is the default for jobs on that repo.

## State Semantics

Add a new terminal state, `failed_warning`, to both `Run` and `Step`.

`failed_warning` means "this unit failed, but policy allowed the
workflow to continue." It should be terminal for cleanup, pruning,
session retention, and historical display, but it should not be counted
as a hard failed run in failure totals, auto-pause thresholds, or the
dashboard's "failed workflow" filters.

The `Workflow` should continue to `succeeded` if all later steps
succeed. It should not enter a new warning state in v1. Instead, store
metadata on `workflow.artifacts`, for example:

```json
{
  "prepare_status": "failed_warning",
  "prepare_failed_at": "2026-05-11T14:03:22Z",
  "prepare_failure_message": "prepare command failed (exit 1): npm ci",
  "prepare_failed_command": "npm ci"
}
```

This keeps the top-level workflow state compatible with existing logic:
terminal succeeded still means the PR pipeline completed, while the
artifact preserves that setup was incomplete.

Implementation implication: `Step#failed_warning` must advance the chain
the same way `Step#succeeded` does. Do not call the existing
`Step#fail_workflow!` callback for warning failures.

## Prepare Failure Model

Keep prepare all-or-nothing for v1. Commands still run in order; the
first non-zero exit or timeout stops the prepare step. Lenient mode
changes only what Syrus does with that failure after it is observed.

Rationale:

- Current `Steps::Prepare` raises immediately on the first failed
  command. Keeping that control flow avoids redesigning `.syrus.yml`.
- Later commands may depend on earlier commands. Continuing blindly
  through every command can make the warning harder to understand.
- The operator's intent is "try setup, then let the agent continue if
  setup fails," not "reinterpret the setup script."

Per-command `continue_on_error: true` is a separate `.syrus.yml` feature
and should not be part of the first implementation. If it ships later,
it should be modeled as prepare-plan behavior: a command can fail and be
logged while the prepare step itself keeps running. `failed_warning`
should then be used only when the prepare step as a whole ends in a
failure that lenient mode permits.

## Prompt Heads-Up

When a prepare step ends in `failed_warning`, the next agentic step must
receive explicit context in its prompt. Prompt context is required even
if the same information is stored structurally; the agent should not
have to discover this by inspecting logs.

Prepend this block before the issue, feedback, or scheduled-task prompt:

```text
Prepare step warning:

The prepare step did not complete successfully, but this repository is
configured with strict_prepare=false, so Syrus is continuing.

Failure:
<failure message>

The workspace may be missing dependencies, generated files, or other
setup output. Proceed if the task is still reasonable. If the missing
setup prevents useful work, fail clearly and explain what prepare needs.
```

Prompt composition should be centralized, not hand-coded in every
agentic step. A small helper such as `Prompts::PrepareWarning` or a
`Steps::Base#prompt_with_prepare_warning(prompt)` wrapper keeps
`implement`, `respond`, and `analyze_and_fix` consistent. `summarize`
steps do not need the warning unless they become responsible for
running tests or interpreting setup-dependent results.

## Structured Metadata

Store prepare warning metadata on `Workflow#artifacts` in v1. Do not add
MCP sidecar access yet.

The MCP option is useful later if agents need programmatic access to
workflow state, but the current sidecar has a single narrow purpose:
`submit_summary`. Expanding it for one warning flag is not necessary for
the first implementation and would couple lenient prepare to agent
provider behavior. The prompt plus artifacts are enough.

## Retry Semantics

Retry should attempt prepare again.

For a hard prepare failure (`strict_prepare: true`), existing retry
behavior stays unchanged: retrying the failed step reopens prepare and
runs it again.

For a lenient prepare warning followed by a successful workflow, there
is no failed workflow to retry. If the operator wants another attempt,
they should use the normal job-level retry/manual retry path, which
creates a new workflow and reruns prepare from the start.

If a later step fails after lenient prepare, retrying from the failed
later step should not rerun prepare. The historical warning remains on
the workflow artifacts and should still be included in the retried
agentic step's prompt. A full workflow retry reruns prepare.

Do not auto-clear old `failed_warning` states when a later workflow's
prepare succeeds. Historical workflow state should remain factual.

## Interaction With Graders

Future grader, test, browser-test, and adversarial-review steps should
treat `workflow.artifacts["prepare_status"] == "failed_warning"` as a
trust signal:

- Test failures may be less conclusive because dependencies or generated
  assets may be missing.
- Test success is still useful, but should be annotated as coming from a
  workspace whose setup emitted a warning.
- Reviewers should include the prepare warning in their context when
  deciding whether a PR is ready.

When configurable pipelines arrive, step policy should probably become
explicit:

```yaml
steps:
  - kind: prepare
    on_failure: warn
  - kind: test
    requires_successful_prepare: true
```

That is future shape only; v1 should keep the single repository setting.

## UI And API

The job page should display `failed_warning` differently from hard
failure: amber/warning treatment, not red/blocking treatment. The
prepare transcript remains visible and should include the failing
command and exit status or timeout.

The admin API serializers should emit the raw state value and, for
workflows, the prepare warning artifact. API clients can then
distinguish:

- hard failed workflow: workflow `state=failed`
- successful workflow with lenient prepare warning: workflow
  `state=succeeded`, prepare step `state=failed_warning`

Admin overview "recent failures" counters should continue to count only
hard failed runs unless a separate warning counter is added.

## Acceptance For Implementation

- [ ] `repositories.strict_prepare` exists, defaults to `true`, and is
      editable in the repository form.
- [ ] `Run` and `Step` support terminal `failed_warning` state.
- [ ] Strict repositories preserve current prepare-failure behavior.
- [ ] Lenient repositories run prepare, record warning metadata when it
      fails, mark prepare `Run`/`Step` as `failed_warning`, and continue
      to the next step.
- [ ] The next agentic prompt includes the prepare warning block.
- [ ] Workflow artifacts store prepare warning metadata.
- [ ] Failure counters and auto-pause logic ignore `failed_warning`
      unless they explicitly opt into warning counts.
- [ ] Specs cover strict failure, lenient continuation, prompt warning
      content, retry behavior, and admin/API serialization.

## Out Of Scope

- Skipping prepare entirely. That belongs to the skip-prepare label and
  repository setting.
- Per-command `continue_on_error` in `.syrus.yml`.
- MCP sidecar workflow-state reads.
- A workflow-level `succeeded_with_warnings` state.
- Automatically retrying prepare after implement succeeds.
- Clearing historical prepare warnings after later workflows succeed.

## Cross-References

- GitHub issue #229: per-issue skip-prepare label.
- GitHub issue #230: per-repository prepare-enabled setting.
- GitHub issue #231: failure-callout UI. Its unblock actions should
  eventually offer "try implement anyway" for hard prepare failures.
- Roadmap: "Quality graders before PR submission." Graders should
  receive the prepare warning as a trust signal.
