# Visual Review

Visual review gives the worker agent a configured RuntimeSession target it can
drive against its own workflow workspace to catch visible defects — broken layout,
missing content, console errors, incorrect rendering, broken interactions —
before graders run. An independent reviewer agent forms its own go/no-go
judgment, exercises the running app, captures "after" screenshots as
Workflow artifacts, and records a verdict that can send the change back
for another implementation pass.

Execution is provider-neutral: every configured target is a workflow-owned
`RuntimeSession`. The reviewer gets generic inspect, wait, input, snapshot,
and capture tools, while Syrus owns lifecycle, control leases, and teardown
on success, failure, retry, cancellation, and missing submission. Existing
`preview:` configuration is translated into a `browser` target automatically,
so current browser reviews do not require a configuration migration. The
reviewer prompt carries the selected provider key, advertised capabilities,
launch/build options, dimensions, review notes, and required evidence labels.
Terminal-only reviews receive generic runtime controls without browser DOM
tools; mixed browser/terminal reviews receive both. Terminal evidence is
attributed to its target and semantic screen generation in the Review UI.

## On by default

Visual review is on by default instance-wide; there is no feature flag to
toggle. A repository opts out (or overrides rounds/files/seed notes) per repo via
`.syrus.yml`'s `visual_review` block (see [`syrus_yml.md`](syrus_yml.md));
omitting the block (or the `enabled` key within it) defers to the always-on
default.

## How it works

Visual review starts a repository preview when needed, opens affected pages in a browser, checks desktop and mobile layouts, exercises relevant interactions, captures evidence, and records `approved`, `needs_work`, or `skipped`. A `needs_work` verdict enters the configured repair loop; skipped means the change is not visually testable or the environment cannot support a meaningful review.

Draft browser captures are private to the active review until submitted. Submitted screenshots and comparisons appear in the workflow review surface. Draft evidence is bounded and expires; failed curation remains available without publishing misleading evidence.

The review uses the submitted test plan and changed-file surface map to choose pages. It may skip before invoking an agent when configured file patterns do not match. In multi-project repositories it selects an affected preview-capable project and reports ambiguity rather than testing an unrelated app.

## Changed-surface coverage

Syrus expects evidence for the actual changed route, screen, or component state. A faithful proxy is acceptable only when the task or diff makes that shared surface the intended target and the reviewer explains the choice. Unreachable routes, authentication walls, missing seed data, unexpected redirects, and preview errors are reported as blockers, not approved from an adjacent page.

## Verdicts

- `approved` — the changed surfaces were exercised and look correct.
- `needs_work` — findings are actionable and enter the repair loop.
- `skipped` — the change is not visually testable or an external environment blocker prevents review.

Every requested review opinion receives one repair reaction when it returns `needs_work`, including the final configured round. Findings from prior iterations remain available to later review and repair turns. The reviewer must submit a verdict explicitly.

## Configuration (`.syrus.yml`)

```yaml
visual_review:
  enabled: true
  rounds: 2
  required: false
  when_files_changed:
    - "app/frontend/**/*"
    - "app/views/**/*"
  seed_notes: "Log in as demo@example.com / password to reach the dashboard."
```

- **`enabled`** — explicitly turns visual review on (`true`) or off
  (`false`) for this repository, overriding the always-on default. Omitting
  the key (or the whole block) defers to that default (enabled).
- **`rounds`** — how many visual-review passes run. Range 0–10, default 1.
- **`required`** — whether unavailable browser-preview preparation fails the
  workflow. Defaults to `false`, which records the review `skipped`, raises a
  WorkflowWarning, and continues when the preview cannot be prepared. Set to
  `true` to fail the workflow instead. A configured terminal runtime target
  that cannot start always fails coverage: missing workspace affinity, relay
  startup failure, and relay readiness timeout cannot become successful skips.
  This does not change reviewer-submitted `needs_work` findings.
- **`when_files_changed`** — optional glob patterns; when present, visual
  review only runs when at least one changed file matches. Same semantics as
  a grader's `when_files_changed`. Omitting it runs visual review regardless
  of which files changed.
- **`seed_notes`** — optional free text describing how to reach an
  authenticated or populated state in the preview app. Read by the reviewer
  agent as a hint, not executed.

CLI/TUI targets may declare an opt-in `environment` block with literal
non-secret `static` values and/or a repository-owned argv command that maps
explicit generic runtime inputs to allowlisted output variables. Commands get
JSON on stdin and emit `KEY=value` records; undeclared output is dropped,
hard-forbidden process-control names fail coverage, and resolved values are
never persisted. See [`syrus_yml.md`](syrus_yml.md#visual_review) for the full
schema and security rules.

See [`syrus_yml.md`](syrus_yml.md) for the full `.syrus.yml` reference.

Nested `visual_review:` blocks are scoped to their project. Their
`when_files_changed` patterns are resolved relative to the nested
`.syrus.yml`, and their seed notes are shown when that project preview is one
of the affected choices. Use root settings for repository-wide policy and
nested settings for product-specific review scope, seed guidance, or opt-outs.

## Seeding requirements

The reviewer drives the same in-step preview `start_preview`/`stop_preview`
tools spawn (see [`preview_environments.md`](preview_environments.md)). A
preview boots from a fresh checkout on every run, so reaching an
authenticated or populated view depends on the repository's preview `seed`
command being idempotent and producing demo data. The "Seed preview demo
data" Job template
(`lib/agent_skills/configure-preview-seed-data.md`) is a one-time, per-repo
onboarding pass that makes the seed mechanism idempotent, adds a demo
user and representative sample data if the repo has none, and records how
to reach that state in `visual_review.seed_notes`. Repositories that skip
this onboarding still get a running preview, but the reviewer agent may
only ever see an unauthenticated or empty-state app. If the documented seed
notes don't cover the feature under test, the reviewer agent may run
additional ad hoc seed commands itself via its normal shell access before
driving the browser.

## The browser tool set

The reviewer can navigate, inspect accessibility structure, click, type, select, hover, evaluate page behavior, resize the viewport, and capture screenshots. Reviews normally exercise desktop (1280×800) and mobile (390×844) layouts unless a surface is genuinely single-viewport. Browser access is limited to the active preview and literal local preview hosts.

## Screenshot artifacts

Use `submit_visual_artifact` to publish an intentional browser capture with a title and description. It can capture the current browser or a selected visible element and records page, viewport, and subject context. A file-path upload is reserved for repository-owned render outputs, not arbitrary worker files.

When compatible before-and-after evidence exists, Syrus may generate a visual comparison and quantitative diff. Incompatible dimensions or mismatched subjects are reported and skipped rather than compared misleadingly. Evidence appears in workflow and Job review surfaces.

## Manual "Run visual review" trigger

Operators can run visual review on demand — for a fresh look after
implementation, or to cover a pass that was skipped or never configured —
without waiting for a new implementation. The Job detail page exposes a
"Run visual review" action (and chat exposes the equivalent
`run_visual_review` pending action) on implemented or approved Jobs with no
active run, gated by the same visual-review plan resolution the
automatic loop uses — the action is unavailable if visual review isn't
configured/enabled for the repository. This dispatches a standalone
`manual_visual_review` workflow and does not create before/after comparison
artifacts by itself. The reviewer runs alone against whatever is already on
the branch; unlike the automatic loop, it does not loop back into
`implement`/`respond` on `needs_work`. The verdict and critique are recorded
on the workflow the same way an automatic pass records them, for the operator
to read and act on manually.

The chat `run_visual_review` tool also accepts an optional `prompt` of up to
4,000 characters. It appears in the confirmation card and is stored on the
resulting workflow so retries and worker handoffs retain it. The reviewer sees
it in a separately labelled manual-review section for reproducing a focused
viewport or interaction state and capturing the requested evidence. It does
not become implementation feedback, does not change repository seed notes,
and never authorizes the reviewer to modify the implementation.

The Job detail page also exposes a separate "Run before/after comparison"
action when visual-review screenshots already exist. That dispatches
`visual_diff` directly for operator inspection rather than changing the
manual visual-review semantics.

## Which workflows include visual review

The automatic visual_review loop runs in `initial`, `retry`, `pr_comment`,
`chat_feedback`, and `coding_handoff` workflows when visual review resolves
enabled and `rounds > 0`. It does not run in `ci_failure`, `auto_merge`, or
maintenance workflows (`rebase`, `stack_rebase`). The manual trigger's
standalone `manual_visual_review` Workflow is available independently of
those chains wherever the Job state and repository configuration allow it.

### Feedback workflows (pr_comment, chat_feedback)

`pr_comment` and `chat_feedback` lead with a bare top-level `respond` step,
the same way `initial`/`retry` lead with `implement`. When visual review is
enabled, the loop runs after the `adversarial_review` loop and before the
grader retry chain, review-first just like `initial`:

```
respond → visual_review(1) → [respond → visual_review(2) → ...] → graders
```

The reviewer prompt includes a note that this is a feedback workflow and the
full feedback history (PR comments or chat message) being addressed, and
reads the diff from the `respond` step rather than an `implement` step.

### Coding handoff workflow

`coding_handoff` has no bare leading `implement`/`respond` step — a chat
coding session already produced the diff before the workflow started, so
`coding_handoff_fix` plays the "agent_step" role instead, the same shape
`implement`/`respond` play elsewhere:

```
visual_review(1) → [coding_handoff_fix → visual_review(2) → ...] → graders
```

Because the chain has no `implement`/`respond` step at all,
Visual review falls back to a fresh `git diff`
against the default branch — the same fallback path used by the standalone
`manual_visual_review` workflow. A `needs_work` verdict is repaired by
`coding_handoff_fix`, which also handles the workflow's grader retry loop.

For coding handoffs, visual-review history is deliberately separated from final
publication provenance. A `needs_work` visual review remains in
`visual_review_iterations` as historical evidence, but a later
`coding_handoff_fix` records `latest_coding_handoff_fix` and resets the final
visual-verification status until another `visual_review` approves or skips that
fixed revision. `pr_open` and rebase `force_push` then write
`coding_handoff_publication_provenance`; operators should use that artifact to
tell whether the pushed HEAD contains the latest fix and whether visual review
verified that final revision.
