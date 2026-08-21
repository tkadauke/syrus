# Workflow Warnings

`WorkflowWarning` is a generic, reusable mechanism for surfacing
deterministic, structural findings on the Job details page with a
one-click "file a fix Job" action. It is **always on** — unlike
`InsightSuggestion` (gated behind the `agent_insights` Labs flag, see
`agent_insights.md`), warnings are core grading hygiene, not an
experimental feature, and are visible to every operator regardless of
Labs opt-in.

## Model

`WorkflowWarning` is deliberately structured like `InsightSuggestion`
(title/severity/evidence/suggested_prompt/state/created_job — a proven
shape already in this codebase) but lives in its own table and carries
its own linkage:

| Field               | Type      | Description                                                  |
|---------------------|-----------|----------------------------------------------------------------|
| `kind`               | string    | Open-ended discriminator, e.g. `"grader_side_effect"`.        |
| `severity`           | string    | `low` / `medium` / `high`.                                     |
| `title`              | string    | Short, human-readable summary.                                 |
| `evidence`           | json      | Structured detail specific to `kind`.                          |
| `suggested_prompt`   | text      | Pre-filled prompt for the "File a fix Job" action.              |
| `job_id`             | reference | The Job the finding belongs to.                                 |
| `workflow_id`        | reference | The Workflow the finding was recorded during.                   |
| `step_id`            | reference | Optional — the specific Step the finding is scoped to.          |
| `state`              | string    | `pending` / `dismissed`.                                        |
| `created_job_id`     | reference | Set once the fix-Job button is used.                             |

## Recording a warning

Any Step handler can record a warning with:

```ruby
WorkflowWarnings.record!(
  workflow: workflow,
  step: step,               # optional
  kind: "some_new_kind",
  severity: "medium",       # default
  title: "Short summary",
  evidence: { "key" => "value" },
  suggested_prompt: "..."   # optional
)
```

This is the entire reusable surface — a future check calls this same
helper with a new `kind` string and gets storage, generic rendering on
the Job details page, and insight-job discoverability for free, with
zero new frontend code required per new kind.

## First consumer: grader side-effect detection

`Steps::Grader` captures `git status --porcelain` immediately before and
after each grader command runs. If the porcelain output differs, it
records a `kind: "grader_side_effect"` warning with
`evidence: { "grader_name" => ..., "command" => ..., "changed_files" => [...] }`
and a `suggested_prompt` that asks the agent to reproduce the grader
locally, decide whether the changed output should be gitignored, and — if
the output is genuinely important — consider moving the command from
`grade:` to `.syrus.yml`'s `formatters:`/`generated:` section instead of
leaving it as a mutating validation step.

Grader pass/fail is completely untouched by this — purely additive,
matching the non-fatal posture of `record_prepare_soft_failure!`
(`app/services/steps/prepare.rb`) and `record_autofix_failure!`
(`app/services/steps/autofix.rb`).

## Frontend rendering

The Job details page (`app/frontend/routes/jobDetail/WorkflowGraph.tsx`)
renders each Step's `warnings` array with one generic panel component
driven entirely by `kind`/`title`/`evidence` — there is no per-kind
branching, so new warning kinds need zero new frontend code. Each warning
shows a "File a fix Job" button that opens an editable, pre-filled prompt
(the same edit-then-confirm UX shape `InsightSuggestion`'s Accept flow
already established) and posts to
`POST /api/v1/app/jobs/:job_id/workflow_warnings/:id/file_job`, which
creates a `direct` Job from the (possibly-edited) prompt and stamps
`created_job_id` on the warning. Warnings can also be dismissed via
`POST /api/v1/app/jobs/:job_id/workflow_warnings/:id/dismiss`.

## Insight-job discoverability

`list_recent_workflows` (the MCP tool `agent_insight_run` workflows use
to survey recent workflow history, see `agent_insights.md`) includes each
workflow's associated `WorkflowWarning` rows in its `warnings` field. An
insight agent's normal read-only survey therefore picks these up
automatically as evidence for higher-level pattern suggestions — e.g.
noticing a grader has repeatedly triggered a `grader_side_effect` warning
and proposing a `formatters:`/`generated:` reclassification via
`submit_insight`.
