# Syrus Roadmap

Syrus runs in production as a chat-driven, multi-repo coding automation
harness — not just an issue→PR bot. Issue-driven, cron-driven, and
operator-initiated ("direct") Jobs, **Epics** (ordered stacks of Jobs for
work too big for one PR), and **Chat** (planning, Coding Mode, Local Mode,
Chat Goals for multi-turn continuation loops, and an admin Supervisor
control room) all funnel into the same Workflow → Step → Run execution
pipeline described in `CLAUDE.md`. Around that core: a landing queue with
per-repo auto-merge and Epic **merge trains** (atomic multi-PR landing
through one integration branch), **delivery tracks** (`promotion` /
`hotfix_sync` / `upstream_export` trigger kinds for repos that split
development and release branches), and a **plugin architecture** that
ships whole feature surfaces — agent providers, chat providers, MCP tool
sets, input sources, source-control providers — as gems, bundled or
third-party. A `WorkUnit`/`WorkIntent` ownership-and-scheduling layer
(`docs/plans/work-units-and-execution-resilience.md`) now centralizes the
retry/lock/landing policy that used to be scattered across services, in
front of `StepDispatcher`, which remains the actual execution engine.

`CLAUDE.md` is the authoritative architecture description and
`config/syrus_docs/` has feature-level detail; this document does not
restate either. Read this roadmap as "what's still open," not as an
introduction to what Syrus is.

**Current frontier:** `docs/plans/workflow-engine-v3.md` ("One Failure
Vocabulary") is the active architectural initiative. Today the engine
names the same failure event four different ways across four control
planes — chain composition, admission/ownership, failure classification,
and reconciliation — and nothing cross-checks the translations between
them. That plan replaces the four vocabularies with one shared `Problem`
code, a single remediation table, and a policy layer keyed off
`Repository#risk_profile`. Engine-shaped roadmap items below should be
read against that plan, not against this document's old "execution DAG
v1/v2/v3" framing, which predated Steps, graders, Epics, and WorkUnit
entirely and no longer describes how the engine works.

Current MVP limits, still explicit as of this writing:

- **No per-Run sandbox isolation.** The agent runs as a host process in
  the worker pod; per-Workflow workspace cloning under
  `$SYRUS_DATA_ROOT/workflows/<id>/` (outside `Rails.root`) stops the
  *accident* class of agent-leaks-into-the-operator's-checkout, not the
  *determined* class. See Hardening, below.
- **Polling-only ingestion by design** — no inbound GitHub/webhook
  callbacks. Non-GitHub sources plug in through the `InputSource` plugin
  architecture (`config/syrus_docs/input_sources.md`; bundled
  `github_source` and `linear_source`), but they're still pollers.
- **Trusted users, trusted repositories.** Isolation between mutually
  distrusting operators on one instance is not a design goal today.

---

## Hardening

Production polish on what's already running. No new features, just
tightening.

- **Sandbox the agent in a Docker container.** Still the single biggest
  gap here. The agent runs as a host process inside the worker pod with
  only its own worktree bind-mounted by convention, not by enforcement.
  The *determined* class of leak needs real isolation: each Run inside a
  disposable container with only its worktree bind-mounted, the host
  filesystem otherwise invisible, and process limits applied. Same
  posture multi-tenant safety would need anyway. Tracked in #29.
- **Prometheus/OpenMetrics export.** Custom metrics infrastructure
  already exists (`app/services/metrics/`), but there's no
  Prometheus-compatible exposition endpoint — an operator's own
  Prometheus/Grafana stack can't scrape Syrus directly today, only the
  admin UI can read its own metrics.
- **Retention/archival policy for `JobLog`.** Other high-volume data
  types already have pruning (operational logs, workflow workspaces,
  spawned-process rows, walkthrough video blobs — see the matching
  `config/syrus_docs/` pages), but `JobLog` transcript chunks have none.
  Archive transcripts older than N days to S3/MinIO, keep metadata in
  MySQL.

---

## Future ideas

Unscheduled directions. Not committed, not ordered — captured here so
they don't get lost. If an idea you remember from an earlier version of
this document isn't listed below, it has almost certainly shipped —
check `CLAUDE.md` and `config/syrus_docs/` before assuming a gap still
exists (this document was badly out of date until the 2026-09-06
architecture audit that produced this rewrite).

### Multi-layer rate limiting

A global concurrency cap (`AppSetting.max_concurrent_agent_runs`) and
per-Job concurrency exist today. Still missing: minimum time-spacing
between consecutive Jobs on the same repo/account (so a flood of new
issues doesn't unleash a swarm at once), and a burst-vs-sustained
distinction so short-term bursts are allowed but sustained rate is
clamped lower, to stay under GitHub/agent-provider limits without being
as blunt as a flat concurrency cap. Every limit needs to be visible in
the UI (current usage vs cap) and overridable per repo for trusted
setups.

### Spend budgets and thresholds

Spend is tracked and visible today — `Run#cost_usd` and
`ChatSession#cumulative_cost_usd` roll up into Spending Insights
(`/insights/spending`) by date window, Epic, user, repo, trigger kind,
and agent provider. What's still missing is *gating*: per-repo and
per-account dollar budgets over rolling time windows (24h / 7d) that
hold a new Run in `queued` with "budget threshold reached" instead of
letting it run and burn spend — the same shape `max_concurrent_agent_runs`
already applies to concurrency, applied to dollars instead.

### Richer agent transcript search + UI

Meaningfully advanced since this idea was first written: Test Insights
(flaky/failing/slow test tracking), worker-health correlation
(`read_run_worker_health`), and structured per-failure `Problem` codes
(see the Workflow Engine V3 plan) all exist now. What's still open: a
genuinely searchable, diffable transcript view across Runs, rather than
reading one Run's `JobLog` at a time; replayable transcripts, if the
storage model ever needs more than today's streamed rows.

### Repo browsing view

Browse the working tree of a repo at a given point in time, including
the post-run state of any Job (the worktree as it was when the PR
opened). Lets an operator inspect what the agent actually produced
beyond the diff — helpful for large or generated changes.

### Offer infra-quality "free PRs" on repository onboarding

`Repository#recommended_actions`
(`config/syrus_docs/repository_feature_recommendations.md`) already
nudges an operator toward setup/automation suggestions on the repo page,
and a plugin can `suggests_enabling` itself off observed repo signals.
This idea goes one step further: detect common infrastructure smells at
registration time and offer to open the fix as a PR directly, no issue
needed — e.g. Rails repos missing a custom merge driver for
`db/schema.rb`, a missing `.editorconfig`, missing CI workflow
templates. Detection is shallow heuristics on the cloned repo tree; the
PR itself is a tiny static template.

### Multiple PRs per issue

Treat one GitHub issue as a collection of attempts, not a single PR —
retries, parallel variants ("show me three approaches"), and natural
splits all want more than one thread on the same issue. Distinct from
Epics, which already split one big change into an *ordered* stack of
Jobs/PRs; this is about *unordered* alternative attempts at the same
issue. List every Job attached to an issue, link them together, let the
user pick a "primary" if useful.

### Cross-repo coordination

`TargetGraph` / `Project` / `Target` (`config/syrus_docs/target_graph.md`,
DOC-20) exist today as internal plumbing — a repository's `.syrus.yml`
compiles into a canonically labeled graph — but nothing in the runtime
prepare/format/generate/grader pipelines reads it yet, and it doesn't
cross repository boundaries. The eventual goal this plumbing is aimed
at: when an agent touches a shared library that lives in a separate
registered repo, Syrus knows, and can fan out a follow-up Job to update
consumers, warn that downstream repos will need follow-ups, or block the
merge until a consumer compatibility check passes.

### Helm chart for self-hosters

Today's deployable is "your own K3s/K8s manifests" (`bin/deploy`) or
single-host Docker Compose (`install.sh --docker`). A Helm chart with a
sample `values.yaml` turns the deploy from "a project" into a
`helm install` command — directly widens the addressable self-host
audience for the small-team niche Syrus serves.

### Public benchmark / leaderboard

Run Syrus end-to-end against a SWE-bench-style task subset on a
schedule, publish the score *and* the cost. Concrete, reproducible
numbers are a more credible answer to "is it actually better than X"
than prose.

---

## Historical: competitive scan, May 2026

[`docs/competitive-landscape-2026-05-10.md`](docs/competitive-landscape-2026-05-10.md)
surveyed the field (Composio AO, Archon, OpenHands, Sweep AI, Anthropic
`claude-code-action`, GitHub Copilot Coding Agent, Devin, Gru.ai,
Etienne, Claude Squad) as of May 2026. Most of its "steal and ship" /
"steal and adapt" recommendations have since shipped or been
superseded and are intentionally not repeated as open items above:

- **Issue triage** shipped as the `triaging` Job state
  (`Job#triaging_reason`, `IngestionClassifier`,
  `config/syrus_docs/issue_triage.md`) — every labeled-issue Job
  classifies (attach to an Epic, duplicate, already-implemented, or
  ordinary work) before `implement` runs.
- **Per-Step retry/backoff and a re-planning escape hatch** shipped in
  substance: the grader retry loop's `repair_first` policy,
  `AppSetting.grade_max_iterations`, `WorkDefinitions`-owned
  retry/lock/landing policy, and `AutoRetryAttempt`'s 5m/20m/1h backoff
  schedule together cover what this used to describe as a single
  `Step.retry_policy` column.
- **Cost transparency** shipped as Spending Insights (see "Spend
  budgets and thresholds," above).
- **Non-GitHub task sources** shipped as the `InputSource` plugin
  architecture (`github_source`, `linear_source` bundled today).
- **Task dependency modeling** shipped as `JobDependency` /
  `JobDependencyParser` (`Depends-on:` / `Blocked-by:` issue lines).
- **A REST API, a CLI, and native GitHub-suggestion-shaped agent tool
  surfaces** all shipped — the admin REST API (`app/controllers/api/`),
  the Go CLI (`cli/`), and an MCP tool surface far larger than the
  original "comment / mark_failed / submit_summary / set_progress"
  sidecar sketch (`config/syrus_docs/mcp_tool_usage.md`).
- **Workflow templates as shareable artifacts** — only partially:
  `.syrus.yml` already carries repo-specific graders/formatters/generated
  commands, but the `Workflows::*` Ruby classes themselves are not a
  serializable, cross-instance-shareable format. Still open if anyone
  wants to pick it up.
- **`@syrus` mention / issue-assignment triggers alongside labels** —
  not confirmed shipped; check `config/syrus_docs/trigger_kinds.md`
  before re-proposing.

Two threads from the original scan are still genuinely live and worth
re-reading the source doc for before restarting either:

- **Slack as a bidirectional surface.** Platform ingestion/delivery is a
  real extension point today (`PlatformDelivery::Registry`,
  `config/syrus_docs/external_platforms.md`; Discord ships as a plugin
  through it) but Slack itself is "listed as a supported platform but
  disabled until its integration is configured"
  (`config/syrus_docs/connected_platforms.md`) — the bidirectional
  comment-in-Slack / approve-from-Slack / notify-on-finish loop the scan
  proposed has not been built.
- **A more actively ambient Supervisor.** Supervisor chat shipped as a
  pinned, feature-gated admin control room fed by `SupervisorEvents` and
  `ChatScopedEventEvaluatorJob` (`config/syrus_docs/chat.md`). Whether
  its current reactive-evaluation shape fully matches the scan's
  "actively pings the operator only when there's a real decision"
  framing is worth checking against current Supervisor behavior before
  treating this as closed.
