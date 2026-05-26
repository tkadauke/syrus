# Syrus Roadmap

The deterministic harness is built and running in production on K3s.
Issue-driven and cron-driven jobs, PR feedback follow-ups, CI-failure
follow-ups, auto-rebase, MCP sidecar, and the v1 linear-chain
execution DAG (Workflow → Step → Run) all shipped. What's left
organizes into hardening work on the running deployment and a
backlog of feature directions.

---

## Hardening

Production polish on what's already running. No new features, just
tightening.

- **Sandbox the agent in a Docker container.** The agent runs as a
  host process inside the worker pod today. Per-Workflow workspace
  cloning under `$SYRUS_DATA_ROOT/workflows/<id>/` (outside
  Rails.root) stops the *accident* class of agent-leaks-into-the-
  operator's-checkout. The *determined* class still needs real
  isolation: each Run inside a disposable container with only its
  worktree bind-mounted, the host filesystem otherwise invisible,
  and process limits applied. Same posture multi-tenant safety
  needs anyway. Tracked in #29.
- **Prometheus metrics.** Workflows / Steps / Runs by state and
  trigger kind, agent latency histograms, GH rate-limit gauges.
- **Structured JSON logs with correlation id per Run.**
- **Retention policy for `JobLog`.** Archive transcripts older than
  N days to S3/MinIO, keep metadata in MySQL.
- **Sentry-equivalent error reporting.** Today everything goes to
  worker stdout and the operator's `kubectl logs` muscle memory.

---

## Future ideas

Unscheduled directions. Not committed, not ordered — captured here so they
don't get lost.

### Job as execution DAG: v2 + v3

v1 (linear chain) shipped. The two follow-ups described in the
original entry are still ahead.

**v2 — explicit parallel branches.** The work to go from "linear
chain" to "real graph with concurrent branches" (graders running in
parallel, fan-in to `pr_open`) is non-trivial: needs a step
dispatcher that finds runnable nodes, handles fan-in, manages
partial-failure semantics. We can build it if/when there are actually
multiple graders to run concurrently — the v1 linear chain is enough
for the current grader story (graders run sequentially after the
test step, before `pr_open`).

**v3 — agent-authored edges (the interesting one).** Templates from
v1 are the *minimum* DAG; the agent extends them at runtime via
MCP tools:

- `submit_test_plan(steps:)` — already in the roadmap; in this
  model, calling it adds a `test_run` step downstream of the
  current step, with the plan as the step's input.
- `request_review(prompt:)` — adds an `adversarial_review` step.
- `request_grader(kind:)` — opt the current Job into a specific
  grader.
- `mark_optional_step_done(kind:)` — declare an existing optional
  step as skippable for this run (e.g. agent already verified
  manually).

The DAG starts as the trigger's template; the agent grows it
(append-only — no removing edges, no cycles) as it learns what the
change needs. Pairs naturally with `Step.depends_on` (a v3 schema
change replacing today's `next_step_id` linear chain) — the agent's
MCP call inserts a new node and edges into the existing graph.

**UI implications:**

- **Per-Job page**: graph view of the current Job's DAG. Nodes
  colored by state, current node highlighted, click-to-drill-into
  step transcript and runs. v1's linear chain renders today as a
  vertical card stack; with v3's agent-authored edges it grows
  organically.
- **Step detail panel**: list of attempts (Runs) under the step,
  with each Run's transcript / diff / agent metadata. Clicking
  "Retry failed step" retries just that step, not the whole Job.

### Non-GitHub task sources

Ingest work from todo lists and task trackers beyond GitHub Issues — Jira,
Asana, Linear, plain Markdown TODO files, etc. Each source becomes another
poller feeding the same `Job` pipeline; the harness shouldn't care where the
prompt came from.

### Quality graders before PR submission

A `Job` only opens its PR once a configurable set of *graders* all pass.
Graders are pluggable quality signals; if any fails, the agent receives
the failure context and iterates rather than shipping a red PR. Examples:

- **CI graders** — delegate test/build execution to an external CI system
  (TinyCI et al) instead of running tests inside the worker. Keeps the
  worker pod lean and reuses existing build infra.
- **Adversarial review graders** — another agent reviews the diff with a
  critical prompt ("find bugs", "challenge this design") and votes
  approve/reject with rationale.
- **Static graders** — linters, type checkers, security scanners,
  coverage thresholds.
- **Custom graders** — arbitrary user-defined scripts or LLM prompts
  scoped per repo.
- **Visual graders (web app screenshots)** — for repos that render a
  web UI, the grader boots the app (via a per-repo `bin/grader-up`
  script or a Docker compose stub), navigates through a small set of
  configured pages/routes with a headless browser (Playwright /
  Puppeteer), captures screenshots, and feeds them back to the agent
  as multimodal input. Catches whole classes of regressions invisible
  to unit tests: blank pages, layout breakage, console errors, broken
  navigation, accessibility regressions. Same iterate-on-failure loop
  as the other graders — the agent sees the screenshots that
  triggered the failure verdict and tries again. Optional second pass:
  a vision-capable model evaluates the screenshots against per-repo
  rubrics ("looks broken", "matches the design system") rather than
  pixel-diffing, so cosmetic changes don't trip false positives.

Per-repo config picks which graders are required vs advisory.

### Agent-authored test plans for visual graders

Generalises the visual grader bullet above. Pre-configured screenshot
routes catch *generic* breakage; agent-authored plans catch what the
agent was actually trying to verify. The agent knows the intent of its
own changes; the harness doesn't. Let the agent write the test it
wants run.

**Shape:**

- New MCP tool: `submit_test_plan(steps: [...])`. Each step is a
  small structured action the headless browser can execute —
  `navigate(path)`, `click(selector)`, `fill(selector, value)`,
  `expect_visible(selector)`, `screenshot(label)`, `assert_no_console_errors()`,
  etc. Plain JSON; no scripting language to vet.
- Calling `submit_test_plan` **ends the agent run** with an
  "awaiting test results" outcome. Don't keep tokens / worker
  threads tied up while the browser dances for minutes.
- A `RunTestPlanJob` boots the app (per-repo `bin/grader-up`),
  drives the steps with Playwright, captures screenshots and
  console logs, records pass/fail per step.
- When complete, dispatch a follow-up `Run` that hands the agent the
  result: screenshots (multimodal), per-step verdicts, console errors.
  Agent either fixes and resubmits, or calls `submit_summary` to
  open the PR.

**Continue prior session vs new session for the follow-up:**

Default to **continue** the agent's prior session (`--resume <session_id>`,
infrastructure already in place). Reasoning: the agent wrote the plan;
the agent knows the intent of its changes; the prompt cache makes
continuation cheap within TTL.

Two bail-outs to a new session:

1. **Cache cold** — prior session ended longer ago than the extended
   prompt-cache TTL (~1h). Continuation cost approaches new-session cost
   anyway, so spend the budget on a fresh perspective.
2. **Repeat failures** — same plan-and-fix loop has failed 2–3
   times. The agent is patching symptoms; force a new session as a
   "fresh eyes" reset. Same logic as the rebase attempt cap, scoped
   to test-plan iteration.

**Interactions:**

- Stacks with the other graders. Test-plan failures and CI failures
  both feed back to the agent in the same iterate-on-failure loop.
- Per-repo opt-in. Repos without a frontend get nothing from this;
  repos with one mark it required vs advisory like any other grader.
- Vision-model second pass (from the visual-graders bullet) still
  applies — same screenshots, evaluated against per-repo rubrics.
- Token budget concerns: long screenshot batches can blow the
  context window. Cap per-plan screenshot count and fall back to
  text-only verdicts when over budget.

### Multi-layer rate limiting

Per-repo concurrency (one running `Job` per repo) and per-Workflow
failure caps exist today. Production needs more layers stacked:

- **Concurrency caps** — max parallel `Job`s globally, per-account, and
  cross-repo. Enforced at dispatch time; excess jobs queue rather than run.
- **Time spacing** — minimum gap between consecutive `Job`s on the same
  repo (and same account), so a flood of new issues doesn't unleash a
  swarm at once. Token-bucket or fixed-window, configurable per scope.
- **Burst vs sustained** — short-term bursts allowed up to a cap, but
  sustained rate clamped lower to stay under GitHub / Claude API limits.

Every limit needs to be visible in the UI (current usage vs cap) and
overridable per repo for trusted setups.

### Claude usage budgets and thresholds

A close cousin of multi-layer rate limiting, but oriented around dollar
cost and subscription-cap percentage rather than concurrency. Lets the
operator configure thresholds — global, per-account, and per-repo —
under which Syrus refuses to enqueue new runs.

**Signals available today:**

- Stream-json `result` events include `total_cost_usd` and token counts
  per run. Syrus already parses these — accumulating them gives us
  cumulative spend per user / per repo / per time window without any
  new external dependency.
- `claude --max-budget-usd <amount>` — per-run hard cap that the CLI
  itself enforces. Pass through as a per-repo setting.
- `claude auth status --json` confirms subscription tier
  (`free` / `pro` / `max`) but does **not** surface usage percentage.

**Not available (yet):**

- Programmatic "% of weekly subscription cap used." Anthropic may
  expose this — the `claude-code` REPL has a `/usage` slash command —
  but the CLI doesn't ship it as queryable JSON today. Don't scrape
  the REPL output; revisit when there's a real endpoint.

**Initial design:**

- Per-repo and per-account dollar budgets over rolling time windows
  (24h / 7d). Persist `runs.cost_usd` from the stream-json result.
- New `Run` dispatcher check: if projected cost would exceed the
  threshold, hold the run in `queued` and surface "budget threshold
  reached" in the UI rather than letting it run and burn budget.
- `--max-budget-usd` as a per-run safety net set from the per-repo cap.
- UI: spend in the current window vs cap, on the Repository show page
  and globally on the dashboard.

When Anthropic ships a subscription-usage endpoint, layer that signal
in alongside the self-tracked spend (whichever is more conservative
wins).

### Task dependency modeling

Let a `Job` declare it depends on other jobs (or external work). Visualize
the resulting graph as a Gantt chart and a dependency graph in the UI.
Useful when one issue blocks another or when a multi-step plan is split
across PRs.

### Richer agent log storage + UI

Today's `JobLog` captures streamed transcript chunks per Run. The
richer version: structured tool-call timelines, token/latency
breakdowns per turn, searchable across runs, linkable, diff-able.
Replayable sessions (the JSONL captured for `--resume` already
covers part of this).

### REST API

Expose the core resources (`Repository`, `Job`, `Workflow`, `Step`,
`Run`, `JobLog`) over a versioned REST API so external tools and
scripts can register repos, enqueue jobs, and stream logs without
going through the web UI.

### MCP API

Speak the Model Context Protocol so other agents can use Syrus as a tool —
list repos, enqueue a job on an issue, fetch job status and logs. Turns
Syrus into a building block for higher-level agent workflows. Distinct
from the per-Run MCP sidecar that already ships (that one is *internal*
— this is the *external* surface).

### Syrus CLI

Command-line tool wrapping the REST/MCP API so a developer (or an agent
running locally) can drive Syrus from the terminal: `syrus jobs list`,
`syrus run <repo> <issue>`, `syrus logs --follow <job>`. Useful for ops
and for agents that prefer a CLI surface to an HTTP one.

### Repo browsing view

Browse the working tree of a repo at a given point in time, including the
post-run state of any `Job` (the worktree as it was when the PR opened).
Lets users inspect what the agent actually produced beyond the diff —
helpful when reviewing large or generated changes.

### Auto rebase-and-merge on approval

Watch the review signal as another input alongside review comments.
When a syrus-opened PR receives an approving review and all required
checks/graders are green, automatically rebase the branch onto its base
and merge — no human button-press needed. Per-repo opt-in, with a kill
switch label (e.g. `syrus-no-automerge`) for cases the reviewer wants
to merge by hand.

### Offer infra-quality "free PRs" on repository onboarding

When an operator registers a new repository, Syrus can detect common
infrastructure smells and offer to fix each one as a one-shot PR — no
issue needed. The first concrete instance: Rails apps without a
custom merge driver for `db/schema.rb` get hit by a trivial-but-
constant version-line conflict every time two PRs run concurrently.
Syrus already solved this internally (`bin/merge-ruby-schema`,
`.gitattributes`, `bin/setup` registration); offering to drop the
same setup into a freshly-onboarded Rails repo as a single PR
costs the operator one click and saves them the recurring rebase
toil. Generalizes: similar "free PRs" for `.pre-commit-config.yaml`
scaffolding, `.editorconfig`, GitHub Actions workflow templates,
etc. Detection is shallow heuristics on the cloned repo's tree;
the PR itself is a tiny static template.

### Properly formatted diff view

Render the agent's `git diff` in the job UI as a real diff — syntax
highlighting, side-by-side or unified toggle, expand/collapse per file,
line numbers, copy-line. Today's "DIFF" panel is a raw monospace dump;
this turns it into something a reviewer actually wants to read before
clicking through to GitHub.

### Job as execution DAG (phased agent execution)

Today's `Run` conflates "a node in the workflow" with "an attempt at
executing that node." Once we add phased execution (implement →
summarize → test plan → test execution → graders → PR open), the
linearity breaks down. Different trigger kinds need different
workflows. The right model is a DAG: each `Job` is an execution
graph; each node is a step with its own retry policy and
preconditions; each step has zero or more `Run`s (today's `Run`
becomes "an attempt at a step").

This entry organizes several adjacent roadmap items — **Agent ↔
Syrus MCP sidecar**, **Quality graders before PR submission**,
**Agent-authored test plans for visual graders** — into one coherent
machinery. Those entries describe the *what* of individual nodes;
this entry describes *how the nodes are wired together and executed*.

**Data shape:**

```
Job ──< Step ──< Run
              │
              └─ depends_on_step_id (or, in v3, a join table)
```

- `Step.kind` — `implement`, `summarize`, `test_plan`, `test_run`,
  `ci_grader`, `visual_grader`, `adversarial_review`, `pr_open`,
  `rebase`, `pr_comment_response`, etc.
- `Step.state` — `queued | running | succeeded | failed | skipped`
  (skipped = upstream failed, or agent-authored optional step that
  wasn't requested)
- `Step.next_step_id` (v1) or `step_dependencies` (v3) — wiring
- `Run` keeps today's columns but `belongs_to :step` instead of
  directly to `:job`; `trigger_kind` migrates from `Run` to `Step`
  (steps know what kind of work they are; runs are just attempts)

**Per-trigger DAG templates.** Each trigger kind is a different DAG
shape — that's central to the design, not an edge case:

- **Initial run** (issue → PR):
  `implement → summarize → test_plan → test_run → pr_open`
- **PR feedback** (`pr_comment`):
  `respond → summarize_amend → test_plan → test_run → push`
  (no `pr_open` — PR already exists; commit message comes from
  `summarize_amend`)
- **Rebase** (`rebase`):
  `auto_rebase` (non-agentic) → if conflict → `agent_rebase` →
  `force_push`. Skips all other phases — rebases don't need test
  plans or summaries.
- **CI failure** (`ci_failure`):
  `analyze_failure → fix → test_plan → test_run → push`
- **Retry** (`retry`):
  same DAG as `initial` but on the existing branch.
- **Manual** (`manual`):
  freeform — single `manual` step, no graph.

Templates live as Ruby classes (`Workflows::Initial`,
`Workflows::PrFeedback`, etc.) — one source of truth per trigger.

**v1 — linear chain, named concept (small).** Skip parallel
execution; just untangle Step from Run and ship phased execution
linearly via a `Step.next_step_id` pointer. The DAG of "implement →
summarize" is two boxes connected by an arrow. Templates per trigger
kind are linear chains. Existing single-Run flows migrate to a
single-step `Workflows::Legacy` (or just `implement`-only) workflow
to keep history clean. UI shows the chain horizontally on the job
page with the current step highlighted; dashboard rows surface the
current step name as a small caption under the status pill.

This is the immediate win: phased execution becomes possible without
any DAG/parallel-branch machinery. We get cleaner per-step prompts
and the per-trigger workflow templates, which is most of the value.

**v2 — explicit parallel branches.** *Skipped for now.* The work to
go from "linear chain" to "real graph with concurrent branches"
(graders running in parallel, fan-in to `pr_open`) is non-trivial:
needs a step dispatcher that finds runnable nodes, handles fan-in,
manages partial-failure semantics. We can build it if/when we
actually have multiple graders to run concurrently — but the v1
linear chain is enough for the current grader story (graders run
sequentially after the test step, before `pr_open`).

**v3 — agent-authored edges (the interesting one).** Templates from
v1 are the *minimum* DAG; the agent can extend them at runtime via
MCP tools:

- `submit_test_plan(steps:)` — already in the roadmap; in this
  model, calling it adds a `test_run` step downstream of the
  current step, with the plan as the step's input.
- `request_review(prompt:)` — adds an `adversarial_review` step.
- `request_grader(kind:)` — opt the current Job into a specific
  grader.
- `mark_optional_step_done(kind:)` — declare an existing optional
  step as skippable for this run (e.g. agent already verified
  manually).

The DAG starts as the trigger's template; the agent grows it
(append-only — no removing edges, no cycles) as it learns what the
change needs. This pairs naturally with `Step.depends_on` — the
agent's MCP call inserts a new node and edges into the existing
graph.

**UI implications:**

- **Per-Job page**: graph view of the current Job's DAG. Nodes
  colored by state, current node highlighted, click-to-drill-into
  step transcript and runs. With v1's linear chain this is just a
  horizontal row of boxes; with v3's agent-authored edges it grows
  organically.
- **Dashboard row**: small caption under the status pill —
  `currently: test_run (step 3/5)` — gives operators an immediate
  read on where the Job is.
- **Step detail panel**: list of attempts (Runs) under the step,
  with each Run's transcript / diff / agent metadata. Clicking
  "Retry failed step" retries just that step, not the whole Job.

**Failure semantics:**

- Step `failed` → downstream steps stay `queued` (effectively
  blocked) until a retry. Independent branches (v3) keep running.
- Job `failure_count` increments only on terminal failure (no more
  retries available for any step in the DAG).
- The "auto-close after N failures" rule keys off this same counter.

**Migration:**

- Add `Step` model. Existing `Run`s get backfilled into a single
  `Step(kind: "implement")` per Run, preserving history.
- New code paths use `Workflows::*` templates to scaffold steps.
- Old code paths (the `Run`-direct creation in `Job`,
  `PollPullRequestJob`, etc.) migrate one trigger at a time.

### Agent ↔ Syrus MCP sidecar

The agent needs a way to communicate structured signals back to Syrus
beyond just the diff: "I can't implement this", "this is already done in
commit X", "here's the PR title and body I want", "please ask the user
to clarify Y". Don't parse trailing JSON from the transcript — that's
one-shot, brittle, and dies with the run. Use MCP instead: the agent
already speaks tool-use natively.

**Shape**: a stdio-mode MCP server spawned by the worker as a sidecar to
`claude-code`. Agent talks to the sidecar over stdio; sidecar talks to
ActiveRecord directly in-process. No network, no auth, no token
lifecycle. The sidecar holds the current `run_id` so the agent can only
act on its own run.

**Initial tool surface** (run-scoped):

- `comment(body)` — append a comment to the run, visible in the UI
  alongside the transcript
- `mark_failed(category, reason)` — categories: `cant_implement`,
  `already_done`, `needs_clarification`, `blocked_external`
- `submit_summary(pr_title:, pr_body:, summary:)` — the agent-authored
  PR copy (single source for it; no JSON-blob fallback). Also rendered
  in the comment feed at the point in the run where the agent called
  it, so the operator sees "the agent submitted its summary here" in
  context with the streamed transcript — not just buried in the PR
  body once the run finishes
- `set_progress(stage, note)` — optional mid-run telemetry

**Degradation hierarchy** for the PR-copy case specifically:

1. Agent called `submit_summary` during the main run (cheapest — no
   extra tokens, signal is volunteered)
2. `PrSummarizer` second-shot invocation: a fresh `max_turns: 1` claude
   call rooted in a tmpdir, given the issue + the produced diff, asked
   for `{title, body}`. Catches the "agent forgot to call the tool"
   case without needing a parallel transcript-parsing channel
3. Templated PR body as a last resort, with "no agent summary"
   surfaced in the UI

For non-PR-copy signals (`comment`, `mark_failed`, etc.) there is no
fallback — if the tool wasn't called, the signal didn't happen.

**Audit**: every tool call lands in `JobLog` automatically.

**Reuse**: when the public REST API and MCP API entries below ship,
they expose the same internal services this sidecar uses.

### Unified job page context

Surface *all* relevant context for a job on its detail page, not just
the transcript and diff: the source issue title + body (already shown),
every issue comment, the PR title + body, every PR/review comment, plus
key metadata (reviewers, labels, checks). One screen captures the full
state of the conversation around this job — no tab-switching to
GitHub to figure out what's going on.

### In-Syrus comments that trigger re-runs

Let the user comment on a job inside Syrus itself, alongside the
issue/PR comments mirrored from GitHub. By default a new in-Syrus
comment triggers a re-run with the comment appended to the prompt
(opt-out per repo, or per-comment via a "don't re-run" toggle).
Bypasses the heavy GitHub-issue/PR comment workflow when the user
just wants to give a quick instruction — same effect as commenting on
the PR, without the round-trip through GitHub's UI.

### Multiple PRs per issue

Treat one GitHub issue as a collection of attempts, not a single PR.
Retries, parallel variants ("show me three approaches"), and natural
splits (foundation refactor first, then the feature) all want >1
thread on the same issue. The polling dedup already only blocks
*non-terminal* duplicates, so this is mostly a first-class UI/data-
model surfacing job: list every `Job` (thread) attached to an issue,
link them together, and let the user pick a "primary" if useful. The
opposite — one PR closing multiple issues — is *not* modeled
structurally; honor GitHub's `Closes #X, #Y` in agent-authored PR
bodies and surface "also closes #Y" as a read-only link on the job
page.

### In-UI agent chat

Optional chat window in the web UI where the user can talk to an agent
that controls Syrus on their behalf — "rerun the last job on issue 42
with extra context", "cancel everything on the foo repo", "show me jobs
that failed this week". A conversational front-end to the same actions
the REST/MCP/CLI surfaces expose.

---

## Competitive scan, May 2026

These items came out of the May-2026 competitive scan in
[`docs/competitive-landscape-2026-05-10.md`](docs/competitive-landscape-2026-05-10.md).
The full doc surveys the field (Composio AO, Archon, OpenHands, Sweep
AI, Anthropic claude-code-action, GitHub Copilot Coding Agent, Devin,
Gru.ai, Etienne, Claude Squad, etc.) and concludes that nothing has
the same shape as Syrus today. The items below are the *learnings*:
what to steal outright, what to adapt, what to push past the field on,
and what to consciously not do.

### Steal and ship — clear wins, low design cost

- **`@syrus` mention + issue-assignment as triggers, alongside
  labels.** Anthropic's `claude-code-action` and Copilot Coding Agent
  both support `@`-mention and "assign issue to bot user" as triggers.
  Labels work but are unfamiliar to people coming from those tools.
  Cheap to add — same poller path with extra predicates. Lowers
  onboarding friction.
- **GitHub "suggested change" auto-apply.** When a reviewer leaves a
  native suggested-change block on a Syrus PR, apply it directly with
  no agent invocation. Skip burning tokens on stuff GitHub already
  structured for you. Trivial to detect, big UX improvement on the
  PR-comment loop.
- **`triage` as a first-class Step kind, default-on.** Gru.ai's
  15-step pipeline starts with triage; Devin v3 does dynamic planning.
  A 1-turn `triage` Step that just answers "is this ready, does it
  have enough info, should we ask for clarification?" prevents the
  most expensive failure mode — wasted full implement runs on
  under-specified issues. New `Step.kind`, opt-out per repo. Output
  feeds the `implement` Step's prompt or short-circuits the Workflow
  with a `needs_clarification` outcome.
- **CI-failure context enrichment.** Today the CI-failure trigger
  hands the agent the failure context it can find. Could be much more
  useful: parse the failed step's log, extract the actual error block
  (not the whole 50k-line log), pass that as structured context. Saves
  tokens, raises fix quality. Pure prep-side work; no agent change.
- **Local-dev / no-GitHub mode.** A `bin/syrus dev <local-path>` that
  runs the harness against a local checkout without GitHub. Useful for
  dogfooding Syrus changes; useful for users who want to try Syrus
  before deploying. No new infra — workspace cloning already supports
  any source. Distinct from the bigger
  [`syrus-as-dev-environment`](docs/plans/syrus-as-dev-environment.md)
  plan, which is about Syrus *being* the dev environment; this is just
  a way to drive the existing harness without GitHub round-trips.

### Steal and adapt — good ideas, need Syrus-specific design

- **Supervisor / ambient-awareness agent.** Distinct from the existing
  [In-UI agent chat](#in-ui-agent-chat) entry, which is *passive*
  (operator initiates conversation). Composio AO's pattern is
  **active**: the supervisor watches every running Job, every PR,
  every CI status, and pings the operator only when there's a real
  decision. Long-running Run subscribed to ActiveRecord changes,
  posting to Slack/UI when something needs attention. Pairs with the
  rate-limiting/budget work as a natural overlay. The chat surface
  becomes one input *into* the supervisor, not the supervisor itself.
- **Codebase-intelligence prepass on repo registration.** OpenHands'
  "Large Codebase SDK" maps cross-file dependencies before the agent
  touches anything. Syrus today re-discovers the codebase shape on
  every Run. Pre-compute a *cheap* symbol/dependency map per repo
  (cached, refreshed on push), pass it as agent context. Big win on
  first-Run latency and quality. Critically not Sweep-style heavy
  indexing — just enough to answer "what files reference symbol X."
  Pairs naturally with the [free-PRs onboarding](#offer-infra-quality-free-prs-on-repository-onboarding)
  entry — same prepass, more output kinds.
- **Helm chart for self-hosters.** OpenHands-Cloud ships via Helm.
  Syrus's deployable today is "your-K3s-deploy-config." Productizing
  as a Helm chart turns the deploy from a project into a `helm install`
  command — directly widens the addressable user base for the
  small-team-self-host niche (which is the moat). Pair with a sample
  `values.yaml` and a one-page "deploy on your own k8s" guide.
- **Slack as a first-class bidirectional surface.** The
  [Non-GitHub task sources](#non-github-task-sources) entry mentions
  Slack as an *ingest* path. The bigger lever is *bidirectional*:
  comment in Slack → spawn Job; Job needs review → ping in Slack with
  one-click approve/deny; Job finishes → post the diff. Slack becomes
  the operator's mobile interface to Syrus when away from a desk.
  Probably the single highest-leverage external surface.
- **Dynamic re-planning escape hatch as a per-Step retry policy.**
  Devin v3's headline feature. The
  [agent-authored test plans](#agent-authored-test-plans-for-visual-graders)
  entry already includes the "repeat failures → new session" idea.
  Generalize it: every Step declares its retry strategy
  (`same`, `incremental`, `fresh-eyes`). After N failures with the
  same approach, force a fresh session prompted explicitly to *try a
  different approach* rather than incrementally fixing. Different
  Steps get different policies — `implement` benefits from fresh-eyes
  resets; `pr_open` does not.
- **Per-Step retry/backoff policy.** Today retries live at the
  Workflow / Run level. Per-Step policy unlocks: graders retry
  differently from `implement`; `pr_open` uses longer backoff than
  `agent_rebase`; `test_run` retries failed sub-tests, not the full
  plan. Schema change: `Step.retry_policy` JSON column. Small,
  high-leverage. Prerequisite for the dynamic-replanning entry above.
- **First-class `verification` attribute on every Step.** Archon's
  organizing principle is that every workflow node declares whether
  it is deterministic-verified or AI-judged. Syrus has both kinds
  (deterministic: `git_clone`, `pr_open`; AI-judged: `implement`,
  `summarize`) but doesn't model the distinction. Make it explicit:
  `Step.verification = :deterministic | :ai_judged | :grader_panel | :human_required`.
  Lets the UI color them differently and lets the dispatcher reason
  about retries / budgets / graders uniformly. Pairs naturally with
  the [graders](#quality-graders-before-pr-submission) entry.

### Push past the field — original or rare, moat-deepening

- **Cross-repo coordination as a first-class concept.** Almost no one
  ships this. Composio AO is single-fleet/single-codebase; OpenHands'
  Large Codebase SDK is single-repo. The play: when an agent touches
  a shared library that lives in a separate registered repo, Syrus
  knows and can either (a) fan out a follow-up Job to update
  consumers, (b) warn the user that downstream repos will need
  follow-ups, or (c) block the merge until a consumer compatibility
  check passes. This is the natural endpoint of "multi-repo
  orchestrator" — and it's nearly empty territory in the field.
- **Visual graders shipped before anyone else.** The
  [Quality graders](#quality-graders-before-pr-submission) and
  [agent-authored test plans](#agent-authored-test-plans-for-visual-graders)
  entries already cover the design. The competitive scan finding: nobody
  else ships this. Multimodal-screenshot-as-grader paired with
  vision-model rubrics is genuinely novel. Worth pulling forward in
  the priority order — a competitor can't easily catch up because it
  requires the whole grader+test-plan+follow-up loop, not just one
  piece. *Reads as a priority signal on existing roadmap entries, not a
  new entry.*
- **Cost transparency as a marketing surface, not just a setting.**
  The [budget thresholds](#claude-usage-budgets-and-thresholds) entry
  is the operator-side. The *user-side*: every Job page shows actual
  cost. Every PR description includes "this Job cost $0.23 across 4
  turns." Becomes a sales argument vs Devin's $2.25-per-ACU opacity:
  "you can see what you paid; we don't markup." Surface in the
  dashboard, in PR bodies, and in the (eventual) Slack notifications.
- **Public benchmark / leaderboard.** SWE-bench is the canonical eval.
  Run Syrus end-to-end against SWE-bench-style task subsets, publish
  the score *and* the cost. Composio AO doesn't, OpenHands does only
  informally. Concrete numbers are the only credible answer to "is it
  better than just Copilot?" Investment is real but the result is
  durable. CI job that runs nightly against a fixed task set, posts
  results to a public dashboard.
- **Workflow templates as first-class shareable artifacts.**
  Per-trigger Workflow classes are Ruby today. Make them serializable
  artifacts (YAML/JSON) shareable across Syrus instances. "Here's the
  Rails-app-with-RSpec workflow template" → drop into `.syrus.yml` in
  your repo. Ecosystem play; nobody else has it because nobody else
  has the Workflow → Step → Run abstraction at all.
- **Cross-job context awareness in the agent prompt.** When the
  `implement` Step starts, the prompt today sees: the issue, the repo.
  It could also see: "there are 2 other Jobs running in this repo
  right now (#142 touching `user_model.rb`, #145 touching
  `auth_controller.rb`). Avoid stomping their changes." Cheap context;
  prevents merge conflicts the agent could have foreseen. Pairs with
  the existing per-repo concurrency cap and the cross-repo
  coordination entry above.

### Skip — popular elsewhere, wrong for Syrus

These are deliberate non-goals captured here so they don't drift back
in under feature-comparison pressure later.

- **Multi-Git-provider (GitLab, Gitea, Bitbucket) before traction.**
  OpenHands has it; Devin has it. Tempting, but adding the abstraction
  now is premature optimization, and it dilutes focus on the niche
  Syrus actually serves. Defer until a real user asks for it — most
  self-host users are on GitHub anyway.
- **Voice interface.** Devin shipped one. Niche, low ROI for a
  self-hosted multi-user tool.
- **Building our own agent loop.** OpenHands does this; Devin does
  this. Syrus's "thin orchestrator around `claude-code` CLI" is a
  strategic *advantage* — Anthropic's roadmap becomes Syrus's roadmap
  for free. Resist any temptation to "we should write our own agent
  runner." Provider abstraction across CLIs (which is partly already
  in flight) is fine; replacing the CLI with a homemade agent loop is
  not.
- **Webhook-based triggers as a v2 add-on.** `README.md` and
  `ARCHITECTURE.md` say polling-only is deliberate. Stay disciplined.
  The operational simplification is a feature; webhooks would force
  us to deal with delivery retries, signature validation, and a
  deploy-boundary problem. Don't fold under user pressure.
- **DAG v2 (parallel branches) before v3 (agent-authored edges).**
  Already noted in the [Job as execution DAG: v2 + v3](#job-as-execution-dag-v2--v3)
  entry. Reinforced by the scan: v2 needs a step dispatcher, fan-in
  semantics, partial-failure handling — heavy machinery for "graders
  run in parallel." v3 is where the *interesting* moat is. Land v3
  directly when the graders need it.

### Highest-leverage cluster

If picking three to push next from this list, the cluster that takes
Syrus from "an issue→PR bot" to "a teammate you can interrupt from
your phone" without requiring graders/sandboxing to land first:

1. **`triage` Step** (steal-and-ship) — kills the worst failure mode
   for ~$0.01 per Job.
2. **Per-Step retry policy + dynamic re-planning escape hatch**
   (steal-and-adapt) — turns failed Runs from "give up" into "try
   differently."
3. **Slack bidirectional surface** (steal-and-adapt) — moves the
   operator out of the kubectl-and-browser loop.

All three are independently shippable, give compounding leverage on
existing flows rather than waiting on heavier roadmap items, and don't
conflict with the planned graders/DAG-v3/sandboxing work — they make
that work more valuable when it lands.
