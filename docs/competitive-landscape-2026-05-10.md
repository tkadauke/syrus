# Competitive landscape

_Captured 2026-05-10. Snapshot of where Syrus sits relative to other AI
coding-agent harnesses, orchestrators, and SaaS competitors as of mid-2026._

## Why this exists

Syrus is no longer a thought experiment — the deterministic harness has
shipped, parallel-agent dispatch is in production, and `syrus`-labeled
issues are flowing through the pipeline across multiple repos. Before
investing further on the roadmap (graders, DAG v2/v3, sandboxing, visual
test plans, etc.) it's worth a deliberate scan: what already exists in
this space, where Syrus genuinely differentiates, and where we're
shipping table-stakes work everyone else has already shipped.

This document is a point-in-time read. Re-do it whenever a major
roadmap decision is on the table; the field is moving fast.

## Syrus today (snapshot)

Per `ROADMAP.md` opening and `ARCHITECTURE.md` (last reviewed
2026-05-03):

- Rails 8.1.3 + Solid Queue (MySQL prod / SQLite dev/test), Tailwind +
  Turbo Streams + Stimulus UI, Octokit, AASM state machines.
- Polling daemon — never accepts webhooks. Ingests issues, PR comments,
  CI failures, scheduled tasks, rebases.
- Domain model is `Workflow → Step → Run` (the v1 linear chain shipped;
  agent-authored DAG extensions are v2/v3 backlog).
- Per-Run **MCP sidecar** in stdio mode talks ActiveRecord directly so
  the agent can call `comment`, `mark_failed`, `submit_summary` etc.
  without parsing trailing JSON from the transcript.
- Auto-rebase, agent-driven when the deterministic merge fails.
- Deployed to K3s alongside Winston/Gloria. Multi-user with per-user
  encrypted Claude + GitHub credentials.
- Agent is the `claude-code` CLI, spawned as a host process inside the
  worker pod (sandboxing in Docker is roadmapped — see issue #29).

## Roadmap themes

Pulled from `ROADMAP.md`'s "Future ideas" section — not committed, but
the direction:

| Theme | What it is |
| --- | --- |
| Sandboxing | Disposable container per Run, only the worktree bind-mounted. |
| DAG v2/v3 | Parallel branches, then agent-authored edges via MCP (`submit_test_plan`, `request_review`, `request_grader`). |
| Quality graders | Adversarial-review agents, static checkers, CI delegation, **visual screenshot graders** with vision-model rubrics. |
| Agent-authored test plans | Agent writes a Playwright-style script, harness runs it, feeds screenshots back multimodally. |
| Budgets & rate limits | Per-user/per-repo dollar budgets and concurrency, hooked to `claude --max-budget-usd` and stream-json `total_cost_usd`. |
| Non-GitHub triggers | Jira, Linear, Asana, plain-markdown TODOs into the same Job pipeline. |
| REST + MCP API + CLI | External surfaces over the same internal services. |
| In-Syrus comments → re-runs | Skip the GitHub round-trip for quick instructions. |
| Auto rebase-and-merge on approval | Optional per-repo. |
| "Free PRs" on onboarding | Detect smells (e.g. missing `db/schema.rb` merge driver) and offer a one-shot fix. |
| Multiple PRs per issue, in-UI agent chat, repo browsing | UI/data-model surface area. |

## What already exists out there

Split by "how close is the actual shape," not by name recognition.

### Closest analogs (multi-agent harness over GitHub repos)

**[Composio Agent Orchestrator](https://github.com/ComposioHQ/agent-orchestrator)**
— open source, ~4.1k stars, launched Feb 2026. Each agent gets its own
worktree/branch/PR; fixes CI failures and responds to review comments
autonomously; supervisor-agent dashboard at `localhost:3000`. **Closest
in spirit to Syrus.** Differences: appears to be a single-user local
dashboard, not a multi-tenant deployable web app. No per-user encrypted
credentials, no polling daemon model. No MCP sidecar; no explicit
graders; no Quality-DAG. Their own discussion thread compares against
**T3 Code**, **OpenAI Symphony**, and **Cmux** as peers — that's the
immediate competitive cluster.

**[Archon](https://github.com/coleam00/archon)** — "first open-source
harness builder for AI coding." Workflows are DAGs where each node is
either deterministic (bash, test, git op) or AI-driven; **AI only runs
where it adds value** — the same philosophy Syrus describes as "harness
owns mechanics, agent only writes code." Per-workflow-run worktrees.
Differences: Archon is a *framework/builder*; Syrus is a deployed
application with strong opinions (issue→PR loop, GitHub-native polling,
claude-code-as-agent). You'd build something Syrus-shaped *with*
Archon, not switch to Archon.

**[OpenHands](https://github.com/OpenHands/OpenHands) +
[OpenHands-Cloud](https://github.com/All-Hands-AI/OpenHands-Cloud)** —
most polished open-source competitor. v1.0.0 ships with the new
`software-agent-sdk`; Helm charts for self-hosting on Kubernetes;
GitHub-native (label an issue or `@openhands` and it comments + opens a
PR). Multi-Git-provider via abstraction layer. **Large Codebase SDK**
for cross-file dependency mapping. Differences: OpenHands *is* the
agent (their own loop, their own model integration); Syrus is a thin
orchestrator around the claude-code CLI. OpenHands-Cloud is
single-tenant/enterprise; Syrus is multi-tenant from the ground up. No
first-class graders concept yet. No polling-only architecture.

### Adjacent but different shape

**[Sweep AI](https://github.com/sweepai/sweep)** — Apache-2.0; the OG
"`Sweep:`"-issue-to-PR bot. Has effectively pivoted to a JetBrains
plugin per their repo description. The original Sweep flow is the
prior generation of what Syrus is doing — proves the demand and the
shape, but the OSS isn't an active competitor to Syrus's specific
design.

**[Anthropic claude-code-action](https://github.com/anthropics/claude-code-action)**
— official GitHub Action. `@claude` mention or issue assignment
triggers a run; supports Anthropic API, Bedrock, Vertex, Foundry.
**This is exactly what Syrus is replacing** for our setup: per-repo GHA
install, no central state, no cross-repo coordination, no graders. If
you only have one repo, this is the cheaper answer.

**[GitHub Copilot Coding Agent](https://docs.github.com/en/copilot/concepts/agents/coding-agent/about-coding-agent)**
— assign an issue to Copilot, it works in the background, opens a PR.
GA as of 2026; agentic code review shipped Mar 2026 and feeds review
suggestions to the coding agent. Differences: locked to github.com +
Copilot subscription, model is GitHub's choice, no self-hosting, no
BYOK.

**[Devin](https://cognition.ai/blog/introducing-devin)** (Cognition) —
closed-source SaaS, $20–$500/mo. Devin v3 (2026) supports dynamic
re-planning; multi-agent parallelism added in v2. 20+ tool integrations
including Jira / Linear / Slack. Same problem space; opposite
philosophy: managed black box vs. self-hosted glass box.

**[Gru.ai](https://gru.ai/)** — 15-step pipeline (triage → audit →
brainstorm → plan → build → review → ship). Notable because **bash
scripts (not LLMs) enforce pipeline integrity** — same poka-yoke
philosophy Syrus follows. SaaS, not self-hostable.

**[Etienne](https://github.com/BulloRosso/etienne)** — small project,
"coding agent harness for custom AI agents" with CRON + FSMs.
Conceptually adjacent to Syrus's `ScheduledTask` + AASM state machines.

**[Claude Squad](https://github.com/topics/claude-max?o=desc&s=stars)**
— tmux + worktrees for parallel local Claude instances. Single-user,
local-only. Not competing on the deployment model.

### Less direct

- **Codegen** — discontinued as a standalone product Jan 2026; tech
  absorbed into ClickUp.
- **OpenCode** — 147k stars, GitHub Copilot partnership; CLI-shaped
  agent, not an orchestrator.
- **myclaude / wshobson/agents** — sub-agent *libraries* invoked by
  Claude Code, not an orchestrator owning the GitHub loop.
- **Self-hosted Express+Bun BYOK bridges** that wrap claude-code/codex
  CLIs into a REST API with per-user keys + rate limits + cost tracking.
  That's a credential/proxy layer, not a workflow layer — could
  *complement* Syrus rather than compete.

## Bottom line

**Nothing in either OSS or commercial space is the same shape as
Syrus.** The closest combination would be: take Composio AO's
parallel-agent-with-its-own-worktree model, glue on Archon's
deterministic-DAG philosophy, deploy via OpenHands-Cloud's Helm charts,
layer Devin's polished UX — and you're approaching Syrus, but you've
assembled four projects.

### What's genuinely differentiated

1. **Multi-tenant, self-hosted, BYOK.** Almost everyone is single-user
   OSS or single-tenant SaaS.
2. **Polling-only, no webhooks.** Deliberate operational simplification
   almost no one else makes.
3. **Orchestrator around `claude-code` CLI.** Doesn't reimplement the
   agent loop; benefits from Anthropic's roadmap automatically.
4. **Workflow → Step → Run DAG with planned agent-authored edges via
   MCP.** Only Archon is in the same conceptual bucket, and Archon is a
   framework, not an app.
5. **MCP sidecar for agent ↔ harness signaling.** Clean structural
   channel; most others scrape transcripts or parse trailing JSON.
6. **Roadmapped visual graders + agent-authored test plans.**
   Multimodal-screenshot-as-grader is on nobody else's public roadmap I
   could find.
7. **Multi-trigger model** (issue, PR comment, CI failure, scheduled,
   rebase, manual) wired into one Job pipeline. Most competitors are
   issue→PR-only or PR-comment-only.

### What overlaps significantly

The issue→PR core flow (everyone) and parallel-worktree execution
(Composio AO, Archon, Claude Squad, several others — git worktrees
became table stakes around Q1 2026).

### Strategic risk

- **Composio AO is the closest existential threat** — if they pivot to
  multi-tenant deployable, add user accounts and BYOK, they're
  competing directly.
- **OpenHands** is the heavyweight if they ever ship cross-repo
  orchestration as a first-class concept.
- **Devin / Copilot Coding Agent** are the SaaS-incumbent threats — if
  Anthropic doesn't keep up on the agent itself, the BYOK angle weakens.

### Strategic moat worth leaning into

The *small-team self-host with real multi-tenancy* niche. Nobody is
serving that well right now. The roadmap items that double down on
this — sandboxing, per-user budgets, DAG v3 with agent-authored
extensions, visual graders — are exactly the bets that widen the gap.
Roadmap items that everyone else can ship in a quarter (basic worktree
isolation, basic CI-failure follow-up, basic PR-comment response) are
table stakes; ship them, but don't expect them to differentiate.

## Sources

- [Composio Agent Orchestrator (repo)](https://github.com/ComposioHQ/agent-orchestrator)
- [Composio AO competitive landscape vs T3 / Symphony / Cmux](https://github.com/ComposioHQ/agent-orchestrator/discussions/526)
- [MarkTechPost — Composio open sources Agent Orchestrator (Feb 2026)](https://www.marktechpost.com/2026/02/23/composio-open-sources-agent-orchestrator-to-help-ai-developers-build-scalable-multi-agent-workflows-beyond-the-traditional-react-loops/)
- [Archon — open-source harness builder](https://github.com/coleam00/archon)
- [Augment Code — 9 Open-Source Agent Orchestrators (2026)](https://www.augmentcode.com/tools/open-source-agent-orchestrators)
- [OpenHands (repo)](https://github.com/OpenHands/OpenHands)
- [OpenHands-Cloud (Helm charts)](https://github.com/All-Hands-AI/OpenHands-Cloud)
- [OpenHands platform site](https://www.openhands.dev/)
- [OpenHands Git provider integrations (DeepWiki)](https://deepwiki.com/All-Hands-AI/OpenHands/10-git-integration)
- [Sweep AI repo](https://github.com/sweepai/sweep)
- [Anthropic claude-code-action](https://github.com/anthropics/claude-code-action)
- [Claude Code GitHub Actions docs](https://code.claude.com/docs/en/github-actions)
- [GitHub Copilot Coding Agent docs](https://docs.github.com/en/copilot/concepts/agents/coding-agent/about-coding-agent)
- [GitHub Copilot Agent Mode press release](https://github.com/newsroom/press-releases/agent-mode)
- [Cognition — Introducing Devin](https://cognition.ai/blog/introducing-devin)
- [Devin Review 2026 — features & pricing](https://aitoolsdevpro.com/ai-tools/devin-guide/)
- [Gru.ai](https://gru.ai/)
- [Etienne harness](https://github.com/BulloRosso/etienne)
- [OpenHarness — HKUDS](https://github.com/HKUDS/OpenHarness)
- [Best Git Worktree Tools for AI Coding 2026](https://nimbalyst.com/blog/best-git-worktree-tools-ai-coding-2026/)
- [Claude Code BYOK via LiteLLM](https://docs.litellm.ai/docs/tutorials/claude_code_byok)
- [The Codegen Blog — update on Codegen (discontinuation)](https://codegen.com/an-update-on-codegen/)
- [Awesome Harness Engineering list](https://github.com/ai-boost/awesome-harness-engineering)
