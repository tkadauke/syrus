# Conventions

- **Public website/docs stay current.** Product-facing behavior changes
  must update `website/` in the same PR. If a change affects what Syrus
  is, why someone would use it, how to get started, a workflow, a feature,
  configuration, credentials, operations, schedules, chats/direct Jobs,
  troubleshooting, or an API surface, update the matching page under
  `website/src/app/` or `website/src/content/docs/`. Prefer updating an
  existing page over adding a parallel one; if the navigation contract
  changes, update `website/README.md` too. PRs that add product behavior
  while leaving the public docs stale are incomplete.
- **Detail pages graduate to tabs when sections are peer workflows.** Keep a
  detail page as one scrolling page when its content is a short, linear read
  or when a "tab" would only duplicate a single overview. Use shared underline
  tabs once the page has multiple peer workspaces operators revisit
  independently -- for example summary, review, workflows, timeline,
  attachments, artifacts, and source. Repository-like pseudo-tabs are only
  warranted when they route to distinct subpages; otherwise prefer normal
  sections on the detail page.
- **`chat_turn_orientation` vs `chat_prompt_injector`.** An injector adds a
  section to the chat *session's* system prompt and is asked once per turn
  whatever arrived. `chat_turn_orientation` is asked about a *specific incoming
  message* and may replace the user's text as the turn's final section — first
  non-nil wins. A walkthrough video is the motivating case: the video is posted
  as a real chat message, and the plugin that owns that message says how the
  agent should open the turn. A provider that claims a message is taking
  responsibility for telling the agent what to do with it.
- **A disabled plugin is not eager loaded.** Its `app/` dirs stay on the
  autoload path, so Zeitwerk resolves constants on demand and enabling needs no
  restart, but its code is skipped at eager load (`Syrus::PluginEagerLoad`,
  fails open if `plugin_records` is unreadable). Three states, not two:
  enabled runs `while_enabled` + `always` effects; disabled-but-enabled-before
  runs only `always` (the cleanup that keeps disabling from orphaning rows);
  never-enabled-here runs neither. `plugin_records.ever_enabled` is stamped by
  the model on any save while enabled and never cleared. Plugin migrations run
  at deploy time regardless of enabled state -- never from a runtime toggle.
- **A plugin can suggest itself.** `suggests_enabling(reason) { |signals| ... }`
  in the manifest is evaluated even for a plugin that is disabled and was never
  enabled -- the one tier that reaches an admin who does not know it exists. It
  returns evidence (a count, repo slugs) or falsy; no evidence, no nudge, and
  enabled plugins are never recommended. The block may only reach the plugin's
  `lib/` (required by the gem regardless of state), never its `app/` tree
  (not eager loaded while disabled). `Syrus::PluginSignals` supplies the facts;
  `repositories.plugin_signals` is stamped by `Steps::Prepare` from
  `RepoPluginDetector.observed_for`, which widens detection to installed-but-
  disabled plugins. Nudge-only -- it never gates a Step.
- **A plugin's docs live in the plugin.** Full documentation for a bundled
  plugin belongs at `plugins/<name>/docs/syrus_docs/*.md`, not in
  `config/syrus_docs/`, so deleting the plugin directory removes its docs too.
  Core docs may still mention a plugin; a doc whose whole subject is one plugin
  may not live in core. `search_syrus_docs` reads core's docs plus every
  *enabled* plugin's, and for an installed-but-disabled plugin emits one teaser
  generated from the manifest's `long_description` (no separate teaser file to
  drift), leading with the fact that it is disabled. Guarded by
  `spec/architecture/plugin_docs_live_in_plugins_spec.rb`.
- **Feature documentation is mandatory.** When adding or changing any
  operator-facing feature — configuration keys, feature flags, `AppSetting`
  columns, new step kinds, new trigger kinds, or changes to existing behavior
  — update the matching file under `config/syrus_docs/` in the same PR. New
  features that have no existing doc file should create one following the
  format in the existing files. PRs that add operator-facing behavior while
  leaving the docs stale are incomplete, same as public website docs.
- **Prompts** all live under `app/services/prompts/`. Core workflow prompt
  classes include
  (`Prompts::Implement`, `Prompts::PrFeedback`, `Prompts::CiFailure`,
  `Prompts::AdversarialReview`, `Prompts::PullRequestSummary`,
  `Prompts::SubmitSummaryInstructions`, `Prompts::TestPlan`,
  `Prompts::ReviewPlan`,
  `Prompts::Rebase`, `Prompts::StackRebase`, `Prompts::PushRebase`,
  `Prompts::LandingFix`,
  `Prompts::ScheduledTask`, `Prompts::DirectJob`, `Prompts::EpicContext`,
  `Prompts::Skill`,
  `VideoWalkthroughs::Prompts::Analysis`, `VideoWalkthroughs::Prompts::Context`,
  `VideoWalkthroughs::Prompts::Report`, `VideoWalkthroughs::Prompts::Segment`).
  Each has a `to_s`. Compose by appending; never inline prompt text in
  jobs/services. Epic-aware prompts append `Prompts::EpicContext` as
  orientation only; it must not expand the current Job's implementation scope.
  `Prompts::Implement`, `Prompts::Rebase`, and `Prompts::StackRebase`
  render their static git-safety and phased-execution instructions through
  `Prompts::SkillLoader` from `.claude/skills/implement/SKILL.md` and
  `.claude/skills/rebase/SKILL.md`; those skill files are live prompt source
  of truth, not duplicate stale documentation.
- **Website/docs audit.** If no website/docs update is needed, the PR body
  must say why so reviewers can audit the call. `AGENTS.md` is a symlink to
  `CLAUDE.md`; preserve that relationship and edit the shared guidance through
  `CLAUDE.md`.
- **Feature flag descriptions are timeless.** `config/features.yml`
  descriptions must not reference PR numbers, issue numbers, or phrases like
  "Introduced in PR #123." or "Added in #456." That information is in git
  history; in the YAML it becomes stale and misleading once the flag is widely
  deployed. Describe only what the flag does and any operator requirements
  (e.g. "Requires a Gemini API key.").
- **A plugin sidebar page's `paths` is still the whole contract on the React
  side.** `config/routes.rb`'s blanket `get "*path", to: "spa#show"` route
  (see below) makes Rails-side reachability unconditional, so a plugin no
  longer needs to declare anything for a hard reload to reach `spa#show`. What
  `paths` still drives is React's OWN client-side route table
  (`usePluginSidebarPaths` in `app/frontend/pluginSidebarPages.tsx`): a page
  whose component branches on `useParams().id` must declare the detail path
  (`["/design_docs", "/design_docs/:id"]`), or client-side navigation to it
  renders nothing, because React has no route for it — the failure is silent,
  because Rails happily served the shell. `spec/architecture/plugin_sidebar_page_routing_spec.rb`
  guards this. The host used to run a separate, narrower
  `repositories/:repository_id/plugin/*path` route
  (`PluginRouteResolver.repo_page_tab_route?`) gating this specifically to
  paths a `repo_page_tab` provider declared; that route was folded into the
  blanket wildcard too, since the constraint no longer decided anything the
  wildcard didn't already serve.
- **SPA routing is derived, not duplicated.** `config/routes.rb` ends with
  `get "*path", to: "spa#show", constraints: ->(req) { !req.path.start_with?("/api", "/rails") }, format: false`
  — every path `app/frontend/routes/App.tsx` (and any nested route file it
  references) owns reaches `spa#show` automatically, declared or not, so a
  hard reload or direct navigation never 404s just because someone forgot to
  hand-write a matching Rails route. This retired the ~90-line hand-written
  `spa#show` list this file used to require in the same PR as a new React
  route; see `spec/requests/spa_spec.rb`'s "routes every React app route"
  example. `/api` is excluded so an unmatched API call still gets a JSON 404;
  `/rails` is excluded because Active Storage, Action Mailbox, and other
  Railtie-owned GET routes live in gem `config/routes.rb` files Rails loads
  AFTER this one (`Rails.application.routes_reloader.paths`), so they land
  BEHIND the wildcard in the final route set rather than in front of it — the
  wildcard would otherwise swallow blob downloads and the mailbox health
  check instead of losing to them "by declaration order" the way every
  same-file route does. A named route (`as:`) is still worth keeping when a
  Ruby `_path`/`_url` helper is actually called somewhere (dashboard payloads,
  job claims, repository summaries, mailer templates, redirects) — grep for a
  real call before adding or removing one, since a coincidentally-matching
  JSON payload field name is not a caller.
- **Frontend i18n** — all user-visible strings in the SPA use i18next. Use the
  `useT` hook (`app/frontend/hooks/useT.ts`, a re-export of `useTranslation`) and
  pick the right namespace (`common`, `nav`, `jobs`, `epics`, `dashboard`, `chat`,
  `settings`, `admin`). Locale files live under
  `app/frontend/i18n/locales/{en,de,la}/`. When adding new strings, add them to
  all three locales. Backend: `User#locale` drives `I18n.locale` per request via
  `ApplicationController#switch_locale`; `User::LOCALES` is the source of truth
  for valid values.
- **Go CLI** lives under `cli/` and talks to the app-scoped JSON API
  (`/api/v1/app/*`). Keep CLI commands, API serializers/controllers, and
  `website/src/content/docs/api.md` aligned when changing terminal-visible
  behavior; `cli/.syrus.yml` owns the core CLI project metadata, while the
  root `.syrus.yml` keeps an executable Go-workspace backstop for core CLI
  paths, plugin-owned CLI modules, and release/desktop packaging paths until
  nested grader targets run directly. For local broad validation, run
  `go test $(go list -m -f '{{.Dir}}/...')` from the repo root,
  which covers the CLI module and every plugin-owned CLI module in `go.work`. The CLI covers
  chat plus Job, Epic, repository, schedule, checkout, inbox, test-plan,
  approval, and identity workflows; repo-aware commands should detect `origin`,
  scope to that repo by default, and refuse checkout changes when the local repo
  mismatches. Job and Epic identifiers are accepted as numeric IDs, `JOB-N`/`EPIC-N`
  prefixes, or human-readable slugs; use the `JobEpicRefFinder` concern
  (included in both app and admin base controllers) to resolve them server-side.
  Commands a bundled plugin owns live in that plugin's own Go module under
  `plugins/<name>/cli` and are wired into the root command in `cli/cmd/root.go`
  (`go.work` joins the modules). Go has no usable dynamic plugin loading for a
  single static binary, so they are compiled in rather than loaded; there is no
  runtime gating, because a disabled plugin's API routes already answer with a
  `plugin_disabled` error. A plugin module cannot reach `cli/internal/...`, so
  the helpers it may use are exported from `cli/pkg/cliplugin` (and
  `cliplugintest` for the test harness) -- keep that surface small and add to it
  deliberately, since it is API for plugin modules.
- **Desktop app** lives under `desktop/` as a separate Electron + React + Vite
  app. It uses Tailwind too, but it does not share the Rails web app's compiled
  CSS or components at runtime. Keep the desktop UI visually aligned with the
  web app's primitives: compact rows, restrained icon buttons, bordered white
  panels, terracotta primary actions (the brand accent, `#b6492e` at 600 —
  see the palette note below), emerald success pills, red failure/error
  pills, and slate/gray neutral text. Avoid broad element styling in
  `desktop/src/styles.css` (especially global `button` rules) because the tray
  surface relies on small, explicit controls. Prefer explicit local primitives
  such as `primary-button`, `secondary-button`, `icon-button`, and status pills.
  Ships on macOS (universal arm64+x64 DMG) and Windows (x64-only installer;
  Windows on ARM runs via built-in x64 emulation). Test desktop changes with
  `npm --prefix desktop run typecheck`, `npm --prefix desktop run build:renderer`,
  and `npm --prefix desktop run build:main`; run the desktop RSpec startup spec
  when Electron main/preload code changes. Local backend updates stream their
  progress over the existing shell-notice bridge: `updateBackend` parses the
  installer's `--json` NDJSON into `ShellNoticeState.backendUpdate` (phase
  `starting`/`downloading`/`migrating` + pull percent + `outage`), bounded by
  a 30-minute deadline that kills a wedged installer tree; the SPA renders it
  as a sidebar notice for the whole update, and `useBackendOutage` (in
  `useBackendUpdate.ts`, with a 5-minute staleness fuse) is the SPA's single
  choke point for "the backend is deliberately unreachable" — surfaces that
  read failed connectivity/credential checks must gate on it instead of
  rendering the unconfigured default ("GitHub not connected"). `outage` is
  true only from container recreation (`stack_up`) on; during the image pull
  the old backend still serves and nothing is gated.
- **Brand palette (terracotta).** The product accent is the terracotta of the
  winged-stylus brand mark (`#b6492e` at 600). `config/design_tokens/terracotta.json`
  is the single shared source for the scale — `config/tailwind.config.js`
  `require`s it directly and remaps Tailwind's `blue` scale onto the same
  values, so legacy `*-blue-*` utilities render the brand accent without a
  repo-wide rename. Use raw `terracotta-*`/`blue-*` accent utilities only for
  pre-auth web surfaces and desktop fixed-brand surfaces; authenticated in-app
  UI must use semantic theme tokens (`bg-brand`, `text-brand`, `border-brand`,
  `focus:ring-brand`, etc.) so it follows the signed-in user's selected theme.
  The desktop app's
  `@theme` block in `desktop/src/styles.css` imports a generated CSS partial
  (`desktop/src/styles/brand-tokens.generated.css`) instead of hand-copying
  the values a second time; after editing the JSON, regenerate it with
  `bin/generate-brand-tokens` (never hand-edit the generated file).
  `spec/desktop/brand_palette_spec.rb` validates both consumers against the
  shared JSON and fails if the generated file drifts. Don't reintroduce raw
  blue hexes for accents; semantically-blue user choices (annotation pen
  colors, tag label colors) are the exception and stay blue.
- **Spending insights** live at `/insights/spending` and roll up `Run#cost_usd`
  plus `ChatSession#cumulative_cost_usd` by date window, Epic, user,
  repository, trigger kind, agent provider, trend, and top Runs. Non-admins
  only see their own spend; admins see instance-wide totals. Keep
  cost/accounting changes aligned with `SpendingInsights::Payload` (in the
  `spending_insights` plugin),
  `docs/current-user-scopes.md`, and public docs.
- **Workflow/Step registries** — `Workflow::TriggerKind` and `Step::Kind`
  are the single source for trigger/step metadata: valid values, handler or
  template class, UI label/style, and whether a step is agentic. Add new
  trigger kinds or step kinds there instead of scattering constants in
  helpers/services.
- **Encrypted attributes** — `User#github_token`, `User#claude_oauth_token`
  use Active Record Encryption. Means `RAILS_MASTER_KEY` is required in
  any process that touches them. Smoke tests inside containers without
  the key will fail at User creation — by design. Production may supply
  `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`,
  `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, and
  `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` instead of credentials;
  set all three together or boot fails.
- **Single-host Docker distribution** — `install.sh --docker` pulls
  `ghcr.io/tkadauke/syrus-backend` and starts the Compose stack; `bin/compose-up`
  builds the same stack locally. Keep `compose.env.example`, `.env.example`,
  and bootstrap payload expectations in sync when adding required env. Never
  regenerate `.env` over an existing `syrus_syrus-data` volume — those
  Active Record encryption keys must match the persisted DB. Test image-level
  changes with `bin/test-docker`; publish only through `bin/publish-image`,
  which builds, runs that integration gate, then pushes. Docker image scripts
  share common build/login/cache helpers in `bin/docker-image-lib`; extend that
  helper instead of copying Dockerfile target, GHCR login, pushed-manifest
  validation, Docker/GHCR plumbing, or registry cache logic between
  `bin/deploy`, `bin/publish-image`, and `bin/compose-up`.
  `SYRUS_DOCKER_REGISTRY_CACHE=1` opts local compose/publish builds into the
  registry BuildKit cache, and `SYRUS_DOCKER_CACHE_REF` overrides the cache tag.
  For desktop-app iteration against unpublished backend changes, `bin/build-local-image`
  builds `syrus-backend:dev-<sha>` from the working tree; stage it into the DMG
  with `SYRUS_BACKEND_IMAGE=<ref> npm --prefix desktop run build`. The
  registry is selected by data, not code: manifest.json carries the
  fully-qualified ref, install.sh pulls it verbatim, release builds pin
  `ghcr.io/tkadauke/...`. Local-only tags survive only until Docker is wiped;
  for wipe-everything install testing use `GHCR_USER=<you> bin/build-local-image
  --push`, which pushes `ghcr.io/<you>/syrus-backend:dev-<sha>` to the fork's
  GHCR (needs `write:packages` in `GHCR_TOKEN` or `~/.config/syrus/ghcr-token`;
  make that package public once so installs need no docker login). Never
  stage a published ref you don't control — a successful pull would clobber
  what you meant to test. install.sh classifies pull failures: exit 30
  network/other, 31 access denied, 32 tag not found.
- **AASM events on Run** — call `start!`, `succeed!`, `fail!`, `cancel!`,
  always followed by `save!` (callbacks set timestamps but don't persist).
  See `Run` model.
- **A failed Workflow must leave a failed Job.** `Job#mark_failed` only
  transitions `from: :running`, so a Workflow whose first Run fails *before the
  Workflow starts* (`started_at` nil, Job never left `:queued`) hit
  `return unless job.may_mark_failed?` and silently propagated nothing —
  leaving Workflow `failed` / Job `queued`. That pair is invisible to the
  operator: the "Just failed" folder is `scope.where(state: "failed")` on the
  **Job**, so it reads healthy while nothing works on it and anything stacked
  behind it stays blocked (the queued-workflow lifecycle regression, fifteen hours, three Jobs waiting).
  `Workflows::JobLifecyclePropagation#fail!` now starts a queued Job whose
  Workflow never started before failing it, and `ReconcileJobStatesJob::Plan`
  carries the `["queued", "failed"]` pair — the one drift pair from `queued`
  that was missing — as the safety net.
- **AASM event guards: ALWAYS `may_X?` before `state_X!`.** The Job
  (and Workflow, and Step) AASM machines run with
  `whiny_transitions: false` — `job.approve!` on a non-approvable Job
  silently no-ops. That made the auto-approval bug (`7fb6aae`)
  invisible until a Job got stuck. Pattern:
  ```ruby
  job.approve!(via: "operator", by_user: user) if job.may_approve?
  ```
  When you need the transition to be definite (not "skip silently if
  not legal"), wrap it in a service that re-checks state and dispatches
  side effects — `LandingQueueProcessor.try_land!` is the canonical
  example. The State machine surface for Job is documented in
  `docs/job-state-audit.md`.
- **Per-Job concurrency** — `RunJob` uses Solid Queue's `limits_concurrency`
  keyed on `job_id` so two Workflows on the same Job never overlap. (Was
  per-repo; changed because the shared WorkflowWorkspace path is per-Workflow-id,
  so the collision risk is within a Job, not across repos.)
- **SolidQueue queues** — `runs` for heavy workflow RunJobs, including
  implementation, response, graders, and main-branch graders; `merges`
  for auto-merge, rebase, and stack-rebase workflow roots; `chat`
  (dedicated low-concurrency worker) for ChatTurnJob and ChatWorkspaceJob;
  `videos` (low-concurrency) for VideoWalkthroughAnalysisJob, whose
  multi-minute Gemini uploads/polling would otherwise pin default threads;
  `control_plane` (the `ApplicationJob` default) for schedulers, landing
  admission, reconciliation, and retry dispatch; `polling` for the
  per-repository/per-PR poll fan-out; `indexing` for search-index writes;
  `cleanup` for pruning; `low_priority_maintenance` for enrichment;
  `connectivity` for plugin daemon lifecycle. Splitting prevents long
  RunJobs from starving landing, chat, the reaper, and UI broadcasts.
  **`default` is NOT consumed by any worker** — nothing in `config/queue.yml`
  lists it, so anything enqueued there is never claimed and accumulates
  silently. `ApplicationJob` sets `queue_as :control_plane` so Syrus jobs are
  safe, but framework jobs that subclass `ActiveJob::Base` directly (Active
  Storage, Action Mailer) must be routed explicitly in `config/application.rb`.
  `spec/config/queue_partitioning_spec.rb` guards both cases.
- **Per-user max-turns** — `User#agent_max_turns` (default 200, range
  0–1000). `0` means no `--max-turns` flag is passed to claude (the
  per-run 90-minute wall-clock timeout still bounds runaway loops). A
  separate 20-minute no-output timeout treats a silent agent subprocess as
  wedged rather than merely slow. Threaded through RunJob → AgentInvocation
  for both regular and rebase runs.
- **Plugin architecture** — Agent providers, chat providers, MCP tool sets,
  input sources, and source-control providers are registered as plugin gems
  via `Syrus::PluginRegistry`. Bundled plugins live under `plugins/` (e.g.
  `plugins/claude_agent`, `plugins/codex_agent`, `plugins/github_source`,
  `plugins/scheduled_tasks` — recurring/one-shot prompts,
  `plugins/syrus_dev` — development diagnostics/tooling, including the admin
  Performance UI's SQL explain and request/phase drilldowns,
  `plugins/video_walkthroughs` — narrated-screen-recording intake, Gemini
  analysis, and the chat handoff).
  `AgentProviders.for(provider)` resolves providers from the registry.
  When adding a new agent provider or MCP tool set, implement it as a plugin
  gem that calls `Syrus::PluginRegistry.register` in its engine initializer;
  don't add the class directly to `app/services/agent_providers/`.
- **Core specs must not enumerate plugin-provided things.** A bundled plugin is
  deletable — `bin/plugin-boundary-audit <name>` proves it by physically
  removing the plugin and running the suite in the copy — so a core spec that
  pins a plugin's MCP tool names, search types, smart-folder counts, or
  migration paths makes that plugin undeletable in practice. Subtract the
  plugin contribution and assert core's own set (`sidecar_registry_tool_names`
  in `spec/services/mcp_tool_registry_spec.rb` is the pattern), or move the
  example into the plugin that owns it. Specs that genuinely need a git working
  tree are tagged `:requires_git_checkout`. Same rule between plugins: a
  plugin spec may only name tools from a plugin it declares `depends_on`.
  See `config/syrus_docs/plugins.md` for the audit recipe.
- **Agent provider selection** — `User#agent_provider` defaults new Jobs
  and direct Jobs; `Repository#agent_provider` overrides it for that repo
  and drives repository-level bulk retries. Per-Job actions and new direct
  Jobs can explicitly choose a configured provider. Always pass the chosen
  provider through to the new Workflow/Run instead of relying on later inference.
- **GitHub credentials** — repositories prefer an active GitHub App
  `Installation`; `GithubClient.for` falls back to the user's PAT if the
  installation is removed or absent. Repository owner changes relink through
  `InstallationLinker`; Jobs persist the resulting `credential_mode` for
  operator visibility.
- **Clean-rebase grade carry-forward** — `Repository#trust_clean_rebase_grade`
  is off by default. When enabled, a clean `rebase` Workflow may record a prior
  green landing validation for the new head/base pair instead of forcing
  auto-merge to re-run required graders. Required grader success is recorded
  via `LandingValidationCache`, and later auto-merge or merge-train retries may
  skip revalidation only when the artifact matches the exact PR/integration
  head SHA being landed.
- **GitHub issue actions** — Repository pages can list GitHub issues and
  comment, close, delegate (add the trigger label), or bulk delegate/close
  them through `GithubClient`. Keep single and bulk paths in sync.
- **Syrus Epic issue markers are body-only.** `PollRepositoryJob` parses
  `Epic:` markers from the GitHub issue body, not from the title. When filing
  a GitHub issue that should become a Syrus Epic, put a standalone
  `Epic: <epic name>` line near the top of the body. A title like
  `Epic: ...` is only display text and will be ingested as a normal Job. Child
  Jobs under an Epic need a standalone `Epic: #<issue-number>` body line. When
  filing child issues immediately after an Epic issue, first verify the Epic
  exists through the admin API or create the Epic via the admin API; otherwise
  the children remain in `pending_epic_ref`.
- **GitHub identifiers are links.** Whenever the UI renders a GitHub issue
  or pull request identifier (`#123`, `PR #123`, `owner/repo#123`), make it
  clickable to the matching GitHub page when a URL can be derived. Plain
  identifiers are only acceptable when the target is genuinely unknown.
- **UTF-8 byte truncation** — never call `String#byteslice` directly outside
  the `String#safe_byteslice` core extension. Use
  `text.safe_byteslice(start, length)` whenever truncating by bytes before
  persistence, logging, prompt rendering, or UI serialization so multibyte
  characters cannot be split into invalid UTF-8.
- **Form validation UI** — React forms should use native validity
  attributes plus route-local error rendering.
- **Toolbar dropdown controls** — interactive toolbar controls that offer a small
  set of choices (like chat mode, model, or effort) use a custom button+listbox
  pattern, not a native `<select>`. The pattern is: a `<button>` with
  `aria-haspopup="listbox"` and `aria-expanded`, paired with an absolutely
  positioned `<div role="listbox">` containing `<button role="option">` items.
  Use `useRef` for the button and dropdown, and a `pointerdown` listener in a
  `useEffect` to close on outside clicks. See `ChatModeSelector`,
  `ChatModelSelector`, and `ChatEffortSelector` in `Compose.tsx` for the
  canonical implementation. Native `<select>` is only for form fields (settings
  pages, edit forms) where browser-native styling and keyboard navigation are
  sufficient.
- **Close icons** — React close/dismiss/remove controls should render the
  shared `CloseIcon` component (`app/frontend/components/CloseIcon.tsx`),
  not a literal `x` or `×` text node. Keep the accessible label explicit
  (`Dismiss notification`, `Close`, `Remove <thing>`, etc.) and size the icon
  with the component's `className` prop.
- **Per-user scheduling pause** — `User#scheduling_paused` (boolean).
  `PollScheduledTasksJob` skips paused users entirely. Operator can toggle
  via admin UI; user can toggle in `/credentials/edit`.
- **Per-Job priority** — `Job#priority` is `high` / `medium` (default) /
  `low`. Converted to SolidQueue integers at enqueue time via
  `Job#solid_queue_priority` (high→0, medium→10, low→20); the
  `Run#enqueue_run_job` path and paused-run re-enqueue in `RunJob` both
  use it. Admin API exposes `priority` on job list and detail responses.
- **Execution ownership** — `Workflow#user_id` and `Run#user_id` must match
  the parent Job owner. Creation paths default from `job.user`; tests and
  manual records should do the same because `RunJob` refuses mismatched
  execution graphs.
- **Job/Epic ownership** — `owner_user_id` is the durable assignee used
  by dashboard scopes, admin APIs, and Epic-owned child Jobs. Job
  `claimed_by_user_id` / `claimed_at` is a lightweight app claim shown in
  the dashboard and Job detail; only the current claimant can release it.
  Keep `mine`, `team`, `claimable`, and explicit `user` scopes aligned
  across dashboard payloads, API serializers, and React filters.
- **Pagination standard** — all paginated list views use the same UI:
  "Showing X–Y of Z" counter on the left; bordered pill buttons
  (`px-3 py-1 border border-gray-300 rounded hover:bg-gray-50`) for
  Previous/Next on the right with `gap-2` between them; disabled
  direction rendered as a grayed `<span>` with `border-gray-200
  text-gray-300` (never hidden). Wrapper: `flex items-center
  justify-between text-sm text-gray-600`. The controller exposes
  `@total_<collection>` and reads `PER_PAGE` from the controller constant;
  the view computes `first_item`/`last_item` inline. Only show the
  pagination block when `total_pages > 1`.
- **Migration timestamps come from the generator. No exceptions.**
  Always create migrations with `bin/rails generate migration <Name>`.
  Never hand-write a `db/migrate/YYYYMMDDHHMMSS_*.rb` filename, never
  copy a sibling migration and bump the digits, never reuse a timestamp
  you saw in another branch's PR. Hand-rolled timestamps collide:
  two branches that both pick `20260513120100` produce identical
  `schema_migrations` rows on the first environment to merge them, and
  the second branch's file then crashes the deploy with
  `Mysql2::Error: Table 'X' already exists`. Recovery is manual
  `UPDATE schema_migrations SET version = '<new>' WHERE version =
  '<old>'` SQL in every environment (dev, test, staging, production) —
  we have paid for this several times. This applies to backfills,
  schema-version bumps, no-op migrations, every kind. If you regret a
  hand-written file you already committed, delete it, regenerate via
  the generator, and rewrite the diff onto the new file before
  pushing.
- **Migrations are idempotent.** Wrap every `add_column`,
  `remove_column`, `add_reference`, `remove_reference`, and
  `add_index` in an existence guard:

  ```ruby
  def up
    add_column :jobs, :approved_at, :datetime unless column_exists?(:jobs, :approved_at)
    add_reference :jobs, :approved_by_user, null: true, index: true unless column_exists?(:jobs, :approved_by_user_id)
    add_index :jobs, :approved_at unless index_exists?(:jobs, :approved_at)
  end
  ```

  Why: production migrations occasionally crash partway through (OOM,
  pod eviction, transient lock contention, etc.) and don't record the
  version in `schema_migrations`. On retry the bare `add_column` dies
  with `Mysql2::Error: Duplicate column name`, the init container
  loops, the deploy hangs. Idempotent migrations recover instead. The
  same applies to `down`: guard with `if column_exists?` so a rollback
  on a partial-state DB doesn't crash. `add_table` / `drop_table` are
  less critical (table creation is more atomic) but follow the pattern
  anyway — `create_table :foo do |t|` becomes `create_table :foo,
  if_not_exists: true do |t|` with no behavior change.
- **JSON columns can't have defaults on MySQL 8.** `add_column :jobs,
  :payload, :json, default: {}, null: false` runs fine on SQLite (dev /
  test) and crashes the production migration with `BLOB, TEXT, GEOMETRY
  or JSON column 'payload' can't have a default value`. The pattern
  that works:

  ```ruby
  add_column :jobs, :payload, :json
  execute "UPDATE jobs SET payload = '{}' WHERE payload IS NULL"
  change_column_null :jobs, :payload, false
  ```

  Add an `after_initialize` callback on the model that seeds `{}` for
  new records so the column stays non-null going forward without a DB
  default. Copy an existing guarded JSON-column pattern.
- **Nontrivial backfills are maintenance tasks, not ad hoc jobs.** When a
  change needs historical data reclassified/reconciled/backfilled at
  more-than-trivial scale, implement it as a `MaintenanceTasks::Definitions::Base`
  subclass (`app/services/maintenance_tasks/definitions/`), registered in
  `MaintenanceTasks::Registry`, not as a bare `ApplicationJob` an operator has
  to remember to `perform_later` by hand. The framework gives it a discovered
  pending state (`MaintenanceTasks::Discovery`), operator start/pause/resume/
  cancel controls (`MaintenanceTasks::Actions`), checkpointed batch resumption
  (`MaintenanceTasks::Runner`), and admin/MCP visibility
  (`admin_maintenance_tasks` MCP tool, Maintenance Tasks admin page) for free.
  A plugin-owned backfill keeps its actual query/update logic in the plugin
  (a plain service object with `.pending_count` and `#call`); the Definition
  subclass itself lives in core and references the plugin service by string
  via `safe_constantize`, mirroring
  `MaintenanceTasks::Definitions::StaleInsightBacklogRetirement` — never a
  hard `require`/constant reference from core into a disableable plugin, since
  that breaks the plugin's deletability (`bin/plugin-boundary-audit`). A
  one-off migration-time backfill that touches only a handful of rows, or one
  that must run synchronously inside the migration itself, doesn't need this —
  use judgment on "nontrivial."
- **Three-dot diffs only** — `git diff <base>...HEAD`, never two-dot.
  Lesson learned the hard way (commit `67b2bf9`).
- **Clones live outside the repo** — under `$SYRUS_DATA_ROOT` (default
  `~/.syrus`). The agent's `chdir` MUST NOT be inside the operator's
  checkout. (Lesson from commit `ced3a65`.)
- **Tests** — RSpec, no FactoryBot. Lightweight `Factories` module in
  `spec/support/`. WebMock + VCR for GitHub. The agent runner is stubbed
  via `RunJob.agent_runner` and `PrSummarizer.runner` test seams; never
  shell out to real `claude` from tests.
- **Per-instance version tracking (`InstanceVersion`)** — Every
  web pod and worker pod registers a row in `instance_versions` on
  boot via `InstanceVersionSupervisor` (started from a
  `to_prepare` initializer when `ENV["SYRUS_ROLE"]` is set —
  manifest-driven, skipped in local/test/console). The row carries
  hostname, role, git SHA (from `ENV["GIT_SHA"]` baked into the
  image by `bin/deploy`), started_at, and a heartbeat thread bumps
  `last_heartbeat_at` every 30s. `at_exit` stamps `finished_at`
  on graceful SIGTERM; `ReapStaleInstanceVersionsJob` (every
  minute) finalizes rows whose heartbeat hasn't moved for 5+ min
  (SIGKILL / OOMKill / node eviction). `GET /api/v1/admin/version`
  returns the request handler's identity plus every fresh
  instance — useful for confirming a deploy has finished rolling
  (during a deploy you see both old + new SHAs in the
  `instances` array until the old pods drain).
- **REST Admin API** — `GET /api/v1/admin/overview`, `/stuck`, `/jobs`
  (filterable by `pr_number`, `issue_number`, `repo`, `state`, `user`,
  `has_active_workflow`, `failed_in_last_24h`), `/jobs/:id`, `/workflows/:id`,
  `/runs` (cross-Job flat list; filterable by `state`, `trigger_kind`, `job_id`,
  `since`), `/queue`, `/processes` (subprocess inventory; filters
  `state=running|finished|all`, `kind`, `hostname`, `run_id`, `workflow_id`,
  `since`; `POST /processes/:id/kill` stamps `kill_requested_at` for the
  cross-pod kill switch), etc. Bearer-token auth via `User#api_token`
  (deterministic-encrypted column). Nested serializers are resilient — a single
  bad row emits `{ error_serializing: "..." }` rather than 500ing the whole
  response (`Admin::JobStateSerializer`). See `app/controllers/api/` and
  `app/services/admin/`.
- **Subprocess inventory (`SpawnedProcess`)** — every subprocess spawned
  through `ProcessRunner` (agent CLIs, graders, git, prepare) registers a
  row, heartbeats on every output chunk, and finalizes on exit. `kind`
  is a strict CONSTANT enum (`SpawnedProcess::KINDS`) — new spawn sites
  must register a kind. The operator-facing list lives at `/admin/processes`
  with kind/hostname/run filters + per-row Kill button. Kill stamps
  `kill_requested_at`; the owning worker's `ProcessRunner` polls the row
  once per second and terminates the local pid. `SpawnedProcess#host_metrics`
  reads `/proc/<pid>/{status,stat}` on Linux for live CPU/RSS readout.
  Two-layer cleanup catches orphans without timeout-based guessing:
  `SpawnedProcessSupervisor` is an in-process ticker thread that
  ProcessRunner.new lazy-starts on first call; every 30s it walks
  own-hostname rows and finalizes any whose pid is gone (detects
  Ruby-thread death / OOM-killed subprocesses inside an otherwise-
  alive pod). `ReapOrphanedSpawnedProcessesJob` (every minute) handles
  the cross-hostname case — finalizes rows whose hostname isn't in
  the current `SolidQueue::Process.distinct.pluck(:hostname)` set
  (detects dead pods within ~5 min of SQ pruning the worker). Both
  paths use conditional `update_all(WHERE finished_at IS NULL)` so
  they race safely with each other and with ProcessRunner's own
  finalize call. `SpawnedProcessPruneJob` (daily 3:20am) deletes
  finished rows past 7 days. `SpawnedProcess` optionally belongs to a
  `chat_session` alongside its existing `run`/`workflow` associations —
  `ChatTurnJob` sets `Thread.current[:syrus_current_chat_session]` around
  the agent invocation (mirroring `RunJob`'s `:syrus_current_run`) so
  `ClaudeInvocation`/`CodexInvocation` can attribute chat-turn `agent`
  processes to their chat, and `ChatWorkspacePrepareJob` attributes
  `chat_prepare` processes the same way. `Admin::SpawnedProcesses::Payload`
  derives a best-effort `owner` summary (`type`/`label`/`path`) from
  `workflow` (→ Job), `chat_session`, or — for `preview` processes, which
  are spawned directly by `PreviewService` rather than through
  `ProcessRunner` — the `job_id` already carried in `resource_attribution`.
  Coverage isn't exhaustive (e.g. `credential_probe`/`chat_stt` processes
  still resolve to no owner); the admin Processes list and detail page
  render `owner` as a link when present.
