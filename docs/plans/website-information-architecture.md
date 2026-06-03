# Website information architecture and content inventory

_Created 2026-06-02 for epic #813. This is the navigation and content
contract for the public/product docs experience under `website/`._

## Goals

The public site should answer three questions quickly:

1. **What is Syrus?** A self-hosted, multi-user, BYOK harness that turns
   issues, review feedback, schedules, retries, and rebases into agentic
   pull-request work.
2. **Can I evaluate it?** Yes: start with the local evaluation path, then
   move to Docker Compose for the full GitHub issue-to-PR loop.
3. **Can I operate it?** Yes, with explicit deployment, configuration,
   architecture, troubleshooting, and API references.

Keep the first-level IA small. The product has a lot of internal machinery,
but visitors should never have to understand every poller or state machine
before finding the right next page.

## Primary audiences

| Audience | Needs | Primary pages |
| --- | --- | --- |
| Evaluator | Understand the pitch, run one local diff, decide whether to deploy | `/`, `/evaluate`, `/docs/getting-started`, `/docs/deployment/try-it-locally` |
| Small-team operator | Run Syrus for real, configure credentials and repositories, debug the first PR | `/docs/deployment`, `/docs/deployment/docker-compose`, `/docs/configuration`, `/docs/troubleshooting` |
| Infrastructure owner | Deploy to k3s/k8s, reason about secrets, storage, queues, rollouts, backups | `/docs/deployment/kubernetes`, `/docs/architecture`, `/docs/configuration`, `/docs/troubleshooting` |
| Contributor / integrator | Understand Job/Workflow/Step/Run, workflow templates, source files, API surface | `/docs/concepts`, `/docs/workflows`, `/docs/architecture`, `/docs/api` |

## Top-level IA

Use four top-level website areas:

| Area | Route | Purpose | Navigation treatment |
| --- | --- | --- | --- |
| Home | `/` | Public pitch, proof, and path selection | Header brand link and primary landing route |
| Evaluate | `/evaluate` | The shortest local evaluation flow | Primary CTA from home and docs |
| Docs | `/docs/*` | Product documentation and operational reference | Main docs sidebar |
| About | `/about` | Naming story, project history, maintainer contact | Footer and secondary nav |

Do not add more top-level routes before launch. New durable product content
should normally land under `/docs/*`; marketing or narrative content should
be justified in `docs/plans/website.md` first.

## Docs IA

The docs sidebar should be ordered by the path a new operator follows, not
by implementation internals.

| Order | Target page | Job for later agents | Page promise |
| --- | --- | --- | --- |
| 1 | `/docs/getting-started` | Polish as onboarding index | Explain what Syrus is, choose an evaluation/deployment path, introduce the tiny glossary |
| 2 | `/docs/concepts` | Keep as product mental model | Define Job, Workflow, Step, Run, trigger kinds, and state shape |
| 3 | `/docs/deployment` | Keep as deployment chooser | Compare local eval, Docker Compose, and Kubernetes |
| 3.1 | `/docs/deployment/try-it-locally` | Keep in sync with `/evaluate` | Document the local-dev Docker path and troubleshooting |
| 3.2 | `/docs/deployment/docker-compose` | Fill when Compose packaging ships | Full web + worker + MySQL install path |
| 3.3 | `/docs/deployment/kubernetes` | Fill when Helm/manifests ship | Production/k3s install path, secrets, storage, rollouts |
| 4 | `/docs/configuration` | Keep as settings reference | `.syrus.yml`, env vars, per-user settings, per-repo settings, secrets |
| 5 | `/docs/workflows` | Keep as workflow-template reference | Built-in templates, Step kinds, template selection, future DAG direction |
| 6 | `/docs/architecture` | Keep as skimmable architecture | Public architecture overview with links to source and canonical deep dive |
| 7 | `/docs/api` | Replace stub when public API ships | REST auth, endpoints, schemas, idempotency, rate limits |
| 8 | `/docs/recipes` | Expand from real use cases | Task-oriented how-tos for CI failure, PR feedback, scheduled jobs, custom templates |
| 9 | `/docs/troubleshooting` | Keep operational and searchable | Symptom-first debugging for pollers, CI feedback, no diff, PR creation, credentials |
| 10 | `/docs/faq` | Populate near launch | Product/security/comparison questions that do not belong in setup docs |

This order keeps "what is this?" and "how do I run it?" before
implementation detail, while still preserving deep references for people who
need them.

## Page contracts

### `/`

Status: stub markdown; should become `index.astro` when Starlight lands.

Use the home-page structure already defined in `docs/plans/website.md`:
hero, issue-to-PR visual, 30-second flow, moat cards, product screenshots,
honest status, deployment CTAs, footer. Keep the lede focused on
self-hosted, multi-tenant, BYOK, deterministic issue-to-PR plumbing.

Source content:

- Preserve the Publilius epigraph and short pitch from `README.md`.
- Pull competitive positioning from `docs/plans/website.md`, not directly
  from `docs/competitive-landscape-2026-05-10.md`.
- Use real product screenshots when available; do not document UI features
  in prose as a substitute for proof.

### `/evaluate`

Status: partially written.

This page is a product CTA, not a docs reference. Keep it to exactly the
three-step local evaluation path plus sample output and a next link to
Docker Compose. The detailed local-dev explanation and troubleshooting live
under `/docs/deployment/try-it-locally`.

Source content:

- Merge command details from `website/src/content/docs/deployment/try-it-locally.md`.
- Keep the "no Ruby, no database, no GitHub setup" framing from
  `docs/plans/website.md`.

### `/about`

Status: mostly written.

Keep this as the human narrative page: naming story, project origin, and
maintainer contact. Do not turn it into product docs.

Source content:

- Preserve the naming section from `website/src/pages/about.md`.
- Preserve the shorter naming paragraph in `README.md` as the compact
  version for home/footer contexts.

### `/docs/getting-started`

Status: mostly written.

This page should be the docs landing page for people who clicked "Docs"
instead of "Try it locally." Keep it short, path-oriented, and glossary-led.

Source content:

- Preserve current page structure.
- Merge only the MVP surface bullets from `README.md` that clarify first-run
  expectations. Detailed workflow internals belong in `/docs/workflows`.

### `/docs/concepts`

Status: mostly written.

This page is the product vocabulary reference. Keep it less detailed than
`ARCHITECTURE.md`, but complete enough that UI labels make sense.

Source content:

- Preserve current Job/Workflow/Step/Run sections.
- Merge trigger-kind updates from `ARCHITECTURE.md` when the model changes.
- Do not duplicate poller implementation details; link to `/docs/architecture`.

### `/docs/deployment/*`

Status: deployment index and local evaluation are mostly written; Compose and
Kubernetes are target flows until packaging lands.

Deployment docs should be honest about availability. If a path is not
copy-pasteable from the current checkout, say so at the top of that page.

Source content:

- Preserve the three-path framing from `docs/plans/website.md`.
- Merge production env var details from `README.md` into
  `/docs/configuration`, then link from deployment pages instead of repeating
  the full list.
- Preserve Kubernetes debugging detail from `AGENTS.md` for internal operator
  docs only; public Kubernetes docs should focus on deployment shape and
  operational responsibilities.
- Keep `docs/deployment/bot-authored-commits.md` as a source for a future
  deployment/security subsection if bot commit identity becomes public-facing.

### `/docs/configuration`

Status: mostly written.

This is the durable reference for setup knobs.

Source content:

- Preserve current `.syrus.yml`, per-user, per-repo, worker env, and secret
  management sections.
- Merge production configuration from `README.md`.
- Merge scheduling pause and max-turns detail from `ARCHITECTURE.md` only as
  operator-facing settings, not as implementation history.

### `/docs/workflows`

Status: mostly written.

This page explains built-in templates and Step kinds. Keep future DAG content
as a short "what is next" section; do not let roadmap speculation dominate
the current docs.

Source content:

- Preserve current built-in template and Step-kind tables.
- Merge current workflow chain definitions from `AGENTS.md` and
  `ARCHITECTURE.md` when implementation changes.
- Link to the roadmap for future DAGs rather than copying the full roadmap.

### `/docs/architecture`

Status: mostly written.

This page is the public architecture overview. It should link to
`ARCHITECTURE.md` for the maintainer-level reference, but it should not expose
every internal debugging recipe.

Source content:

- Preserve the current architecture diagram and core-file table.
- Merge "why polling" and "trust boundary" material from `ARCHITECTURE.md`.
- Keep source links stable and update them when code moves.

### `/docs/api`

Status: explicit stub.

Leave as "coming soon" until the public REST API ships. When it ships, replace
the stub with a real reference.

Target sections:

- Authentication and token rotation.
- Admin API vs app/user API distinction.
- Job creation and lifecycle endpoints.
- Repository, scheduled task, workflow, run, queue, process, and version
  endpoints.
- Request/response schemas.
- Idempotency and retry behavior.
- Rate limits and permission errors.

Source content:

- Preserve endpoint inventory from `AGENTS.md` and API controllers.
- Use request specs as examples once the API is public.

### `/docs/recipes`

Status: good first version.

Recipes should be task-oriented and copy-pasteable. Keep each recipe scoped
to one job-to-be-done with expected outcome and troubleshooting links.

Source content:

- Preserve current recipes for CI failure, PR feedback, scheduled tasks,
  custom workflows, ad-hoc jobs, budgets, and PR opt-out.
- Add future recipes only when the referenced product path exists.

### `/docs/troubleshooting`

Status: good first version.

Keep this symptom-first. It should help operators debug without requiring
them to read architecture first.

Source content:

- Preserve current troubleshooting topics.
- Merge public-safe diagnostics from `AGENTS.md` only when they apply to
  common deployed environments.
- Do not include token-bearing log examples or internal-only recovery scripts.

### `/docs/faq`

Status: needs launch copy.

Use this for cross-cutting questions that would interrupt setup docs.

Target questions:

- How is Syrus different from Devin, Copilot Coding Agent, OpenHands, and
  generic agent CLIs?
- Why polling instead of GitHub webhooks?
- Does Syrus require Anthropic? What about Codex?
- What does BYOK mean in practice?
- Where do credentials live?
- Is the worker sandboxed?
- What does multi-user mean?
- What does Syrus cost to run?
- Can I run it without Kubernetes?
- What is intentionally out of scope?

Source content:

- Use `README.md` for security posture.
- Use `docs/plans/website.md` for competitive framing.
- Treat `docs/competitive-landscape-2026-05-10.md` as internal strategy, not
  copy-ready FAQ material.

## Existing content inventory

| Source | Public target | Disposition | Notes |
| --- | --- | --- | --- |
| `README.md` | `/`, `/docs/getting-started`, `/docs/configuration`, `/docs/faq` | Merge | Keep root README contributor/operator-focused; use website for public onboarding |
| `ARCHITECTURE.md` | `/docs/concepts`, `/docs/workflows`, `/docs/architecture` | Preserve and distill | Remains canonical maintainer reference; website gets skimmable public version |
| `ROADMAP.md` | `/docs/workflows`, `/docs/faq` | Link and selectively summarize | Do not copy long future sections into product docs |
| `CLAUDE.md` / `AGENTS.md` | `/docs/workflows`, `/docs/troubleshooting`, internal agent docs | Preserve internal | Public docs may borrow product facts, not agent instructions or secret-handling recipes |
| `docs/plans/website.md` | Website plan and this IA doc | Preserve | Strategic plan remains; this doc is the concrete IA/inventory |
| `docs/competitive-landscape-2026-05-10.md` | Home positioning and FAQ, indirectly | Keep internal | Sanitize before any public use |
| `docs/deployment/bot-authored-commits.md` | Future deployment/security docs | Preserve | Use when documenting bot identity or commit-signing expectations |
| `docs/job-state-audit.md` | `/docs/concepts` or internal maintainer docs | Preserve internal-first | Public docs need the state summary, not the audit trail |
| `docs/release_notes.md` | Future `/docs/release-notes` or changelog | Preserve for now | Do not add route until launch/update workflow exists |
| `docs/issues/sluggish-then-unreachable-on-staging.md` | None | Preserve internal | Incident note; not public docs |
| `docs/plans/complete/*` | None | Preserve internal/archive | Completed implementation plans should not appear in public IA |
| `docs/plans/react-spa-route-inventory.md` | None | Preserve internal | App UI inventory, not public website content |
| `docs/plans/*magic-constants*` | `/docs/configuration`, if settings remain user-facing | Selectively merge | Only expose current configurable settings |
| `docs/plans/per-repo-chat*.md` | Future docs if feature is public | Preserve internal | Not in launch IA |
| `docs/plans/gh-stack-integration.md` | Future workflows/recipes | Preserve internal | Not in launch IA unless feature ships |
| `docs/plans/syrus-as-dev-environment.md` | `/evaluate`, `/docs/deployment/try-it-locally` | Selectively merge | Use only current local-dev behavior |
| `docs/plans/syrus-native-ci.md` | Future workflows/recipes | Preserve internal | Not launch docs |
| `docs/plans/epic-filters.md` | Future app/admin docs | Preserve internal | Not public product docs unless admin docs expand |
| `docs/plans/lenient-prepare.md` | `/docs/configuration`, `/docs/troubleshooting` | Selectively merge | Use for prepare behavior if current |
| `lib/agent_skills/*.md` | Future recipes or extension docs | Preserve | Not part of launch IA |
| `website/src/pages/*` | Public top-level pages | Preserve and polish | Current files define route contracts |
| `website/src/content/docs/*` | Public docs | Preserve and polish | Current files are the target IA |

## Content rules for later jobs

- Every website content job should name its target route in the issue title or
  body.
- If a job moves or removes content, update the inventory table in this file.
- Use source docs for facts, but write public pages for the audience at that
  route.
- Keep launch docs honest about unavailable packaging or APIs.
- Avoid duplicating long operational reference blocks across pages; put shared
  configuration in `/docs/configuration` and link to it.
- Keep internal diagnostics, token-redaction warnings, and deployment-specific
  kube recipes out of public pages unless they have been sanitized.

## Open follow-up jobs

These are the natural implementation jobs after IA approval:

| Target | Work |
| --- | --- |
| `/` | Convert `website/src/pages/index.md` to a custom Astro home page with the planned hero, proof visual, screenshots, and CTAs |
| `/evaluate` | Convert to a polished CTA page with exactly three commands, sample output, and a Docker Compose next step |
| `/docs/faq` | Write launch FAQ from the target questions above |
| `/docs/api` | Replace the stub when the public API is finalized |
| `/docs/deployment/docker-compose` | Update commands once Compose packaging is present |
| `/docs/deployment/kubernetes` | Update commands once Helm or publishable manifests are present |
| `website` build | Add Starlight/Astro config, sidebar order matching this IA, package scripts, and GitHub Pages deploy workflow |
