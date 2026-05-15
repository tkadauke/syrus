# Syrus → contained dev environment

_Status check 2026-05-15: partially implemented. M1 and M2 are no
longer only roadmap text: per-repo chat has shipped as
`ChatSession` / `ChatTurnJob` / `ChatWorkspace` plus chat MCP tools,
repo-scoped proposals, cascade filing, and a chat/proposals UI; Job
dependencies are first-class and block workflow dispatch when
unresolved. The native CI slice of M3 has also started: local `grade`
steps, loop iterations, `.syrus.yml` grader config, and iteration UI are
present. Still future: a fully configurable arbitrary pipeline, browser
tooling, adversarial review, repo scaffolding, preview environments,
continuous deploy, team roles, Codex-backed chat, and the larger
"unified session + issue pipeline" architecture. See
`per-repo-chat.md` for chat follow-ups and `syrus-native-ci.md` Build
order step 4 for the remaining `ci_failure` cleanup._

The current Syrus is "issue → PR automation harness." The next
Syrus is "the place where a small team (or a solo operator) builds
and runs an entire app, with agents as first-class collaborators."

Captured 2026-05-10. Personal-use OSS — single-org trust model,
homelab K3s as the substrate, no SaaS multi-tenancy.

## What changes vs today

| Capability | Today | Target |
|---|---|---|
| Repo lifecycle | Operates on existing repos | Create + scaffold via agent |
| Iteration | Job dependencies are first-class; one Workflow still runs at a time per Job | DAG of Jobs the operator (or agent) plans |
| Implementer toolkit | Editor, shell, git, local grade output | + Playwright/headless browser |
| Quality gate | Local `grade` loops for initial/retry/pr_comment; legacy `ci_failure` check-run path still present | Tests, formatters, browser tests, adversarial review (configurable in `.syrus.yml`) |
| Delivery | Stops at "PR opened" | CI → preview env per PR → CD on merge |
| Interactivity | Persistent per-repo chat with proposals; Job Runs still use the headless transcript model | Persistent multi-session per-repo agent in the browser |
| Collaboration | Single-tenant + admin tier | Per-repo roles for a small team |

## Decisions locked

1. **Host, don't orchestrate.** Preview + prod envs run on the
   homelab K3s cluster, not on Fly/Heroku/etc. (Reconsider if
   moving to SaaS.)
2. **Persistent agent sessions are separate from the issue pipeline.**
   Multi-session per repo. Operator can have several conversations
   in flight (e.g. "plan the auth rewrite" + "debug staging").
   *Future:* the issue pipeline becomes one entry-point into the
   same session graph (option (c) from the brainstorm).
3. **Pipeline is configurable per-repo via `.syrus.yml`.** Today's
   hardcoded chain (prepare → implement → summarize → pr_open)
   becomes the default, but every repo can extend with browser
   tests, formatters, adversarial-review steps, etc.
4. **Decomposition is on-demand inside a session.** When the
   operator says "build me an auth system," the agent in the
   persistent session breaks it down and files Jobs (with
   dependencies); it doesn't auto-decompose every issue.
5. **Job dependencies are first-class.** Job 42 won't dispatch
   until Job 14 has merged. DAG, not just chain.

## Decide-as-we-go

- **Browser-tool delivery**: probably an MCP server wrapping
  Playwright (so the agent invokes `browse`, `screenshot`,
  `click`, `evaluate`) — vs giving it shell access to a CLI.
  MCP is cleaner. Lock in M3.
- **Decomposition output**: GitHub issues + Syrus Jobs, or just
  Syrus Jobs? Probably Jobs (with optional GH issue creation as
  a side effect). Lock in M2.
- **Preview-env teardown trigger**: PR closed (any reason) vs
  PR merged + 24h grace. Lock in M6.

## Milestones

Ordered highest-leverage-first. Each milestone should be
deployable on its own; later milestones build on earlier ones.

### M1 — Persistent agent sessions

The unlock. Once we have a long-lived chat the operator can talk
to, decomposition (M2), repo creation (M5), and the eventual
unification (option (c)) all hang off it.

- New model `AgentSession`, `belongs_to :repository`,
  `has_many :messages`. Multiple concurrent per repo.
- New table `agent_messages`: turn-by-turn conversation log.
- `--resume` threading via existing `ClaudeSession` infrastructure
  (already battle-tested by the workflow chains).
- Browser UI: full-page session view with streamed turns, tool-use
  cards, attach-file. Stimulus controller for the streaming side;
  Turbo Streams for new-message pushes.
- Sessions can spawn Jobs ("file this as Job, run it in the
  background"). The MCP sidecar gains a `create_job` tool.
- Sessions are scoped to a repo but visible to all repo
  collaborators (M8).

### M2 — Job dependencies (DAG)

Without dependencies, the agent decomposing into N Jobs is useless
— they'd all dispatch at once and step on each other.

- New table `job_dependencies(job_id, depends_on_job_id)`.
- `Job#ready_to_dispatch?` requires every `depends_on` Job to be
  merged.
- `JobDispatcher.advance_from(job)` re-evaluates downstream Jobs
  on merge.
- UI: dependency graph on Job#show + the persistent session view.
- The MCP `create_job` tool from M1 grows a `depends_on:` arg.

### M3 — Pluggable `.syrus.yml` pipeline + browser tool

Today the chain is fixed. Move to a config the agent (and
operator) can extend.

- `.syrus.yml` schema: each step is `{ kind, run, on_failure }`.
  Built-in kinds: `prepare`, `implement`, `test`, `format`,
  `browser_test`, `review`, `deploy_preview`, `summarize`,
  `pr_open`.
- `Workflows::Custom.from_yaml` builds a dynamic chain.
- New `Steps::BrowserTest` runs Playwright/Cypress as configured.
- Implementer gets a browser MCP tool: `browse(url)`,
  `screenshot()`, `click(selector)`, `fill(selector, text)`,
  `evaluate(js)`. Backed by Playwright in the worker pod (or a
  separate "browser worker" pool if memory pressure is real).

### M4 — Adversarial review step

A second agent (configurable model — opus, sonnet, GPT-5, etc.)
reviews the implementer's diff against the issue's acceptance
criteria. Output goes onto the PR as inline comments. If the
reviewer flags blockers, the workflow fails and the implementer
gets to try again with the feedback as input (loops back to
implement, capped at N retries).

- New `Steps::Review` step kind.
- `.syrus.yml` per-repo config: which model, what criteria.
- Reviewer's tool list is read-only (no `Edit`, no `Bash`).
- Loop semantics: review-fail → re-implement with feedback;
  abort after N rounds, surface as a normal Workflow failure.

### M5 — Repo creation + scaffolding

The operator can ask a session "create me a Rails app with auth
and a dashboard." That session:

1. Creates a new GitHub repo via API.
2. Picks (or generates) a scaffold via the implementer.
3. Decomposes the rest into Jobs with dependencies (M2).
4. Watches them through; reports progress in the chat.

- `RepositoryCreator` service: GH API + initial-commit Workflow.
- Template registry: empty, "Rails 8 + Tailwind", "Next.js +
  Prisma", "Python FastAPI", etc. (Probably maintained as
  separate repos that get cloned + customized.)
- The persistent session for the new repo gets created in the
  same transaction.

### M6 — Hosted preview environments

The big infra swing. Each open PR gets a running deployment at
`pr-N.<repo>.<your-domain>`.

- Per-repo K8s namespace (Syrus creates it on repo bootstrap).
- Build pipeline detection: Dockerfile present → use it; else
  generate one from framework signals (Gemfile + bin/rails →
  Rails image, package.json + next.config.js → Next.js image,
  etc.).
- `Steps::DeployPreview` builds, pushes to a per-repo image
  registry, applies a Helm chart, waits for ready.
- Lifecycle controller: PR closed → namespace cleanup. Cap on
  concurrent preview envs per repo.
- Browser tests in M3 can target the preview URL directly,
  closing the loop.

### M7 — Continuous deploy on merge

Same build pipeline as preview, target is the prod env.
`<repo>.<your-domain>`. Configurable strategies in `.syrus.yml`:

```yaml
deploy:
  strategy: auto       # | manual_approval | blue_green
  on_branch: main
  rollback: previous_image
```

- `Workflows::Deploy` triggered on PR merge.
- AdminAction-style audit of every prod deploy.
- One-click rollback in the UI.

### M8 — Team support

Last because nothing in M1–M7 needs hard auth boundaries; the
trust model in OSS personal-use is small + trusted. But once
multiple humans are touching the same repo, a few primitives
help:

- `repository_collaborators(repository_id, user_id, role)` —
  owner | contributor | viewer.
- Invitation flow extension (already exists for admin signup).
- Per-repo permission checks on Job + Session creation.
- Presence indicators (who's currently viewing this Job /
  Session) — nice-to-have, defer unless needed.

### Future (not on the roadmap yet)

- **Unify session + issue pipeline** (option (c) from brainstorm).
  An issue's Run becomes a thread in the persistent session, so
  the operator can interject mid-Run, ask the agent to pause,
  inspect intermediate state, etc. Big architectural shift —
  the Run loop becomes a chat-step rather than a one-shot
  subprocess. Worth its own plan doc when M1–M3 settle.
- **SaaS mode**. If you ever want to host this for others,
  introduce real auth boundaries, billing, multi-tenant
  isolation. Cleanly separable from the homelab path.

## Things that stay sacred

- The "agents own the work, humans own the policy" division.
  Operators don't pair-program the agent; they file work and
  review it.
- One-Workflow-at-a-time per Job concurrency on RunJob. DAG
  changes scheduling, not execution.
- The admin diagnostics surface (built up over the last two
  weeks) is what makes any of this safely investigatable.
  Every new milestone needs to think about "how does the
  operator debug this when it goes wrong" upfront.

## Opening questions (not blocking M1)

- M3 — browser tool: ship as MCP or shell-out CLI? Default
  vote: MCP, for parity with the existing submit_summary
  pattern. Decide before implementing the implementer step.
- M6 — does Syrus run its own image registry, or push to
  GHCR? Default vote: push to GHCR (already authenticated, no
  new infra). Decide when the preview-deploy step is wired up.
- M4 — review failure backpressure: how do we keep the
  implementer-reviewer loop from running forever? Need a hard
  cap (e.g. 3 review rounds → escalate to human).
