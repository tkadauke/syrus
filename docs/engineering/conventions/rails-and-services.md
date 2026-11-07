# Rails and services

Use these rules for Rails service boundaries, registries, APIs, credentials, and repository integrations.

- **Workflow/Step registries** — `Workflow::TriggerKind` and `Step::Kind`
  are the single source for trigger/step metadata: valid values, handler or
  template class, UI label/style, and whether a step is agentic. Add new
  trigger kinds or step kinds there instead of scattering constants in
  helpers/services.
- **Spending insights** live at `/insights/spending` and roll up `Run#cost_usd`
  plus `ChatSession#cumulative_cost_usd` by date window, Epic, user,
  repository, trigger kind, agent provider, trend, and top Runs. Non-admins
  only see their own spend; admins see instance-wide totals. Keep
  cost/accounting changes aligned with `SpendingInsights::Payload` (in the
  `spending_insights` plugin),
  `docs/current-user-scopes.md`, and public docs.
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
- **Syrus Epic issue markers are explicit machine markers.**
  `PollRepositoryJob` parses only Syrus-owned HTML comments from the GitHub
  issue body, not the title or natural-language prose. When filing a GitHub
  issue that should become a Syrus Epic, put `<!-- syrus-epic: <epic name> -->`
  near the top of the body. Child Jobs under an Epic need
  `<!-- syrus-epic: #<issue-number> -->`; use `owner/repo#<issue-number>` for
  cross-repository Epic references. A visible line such as `Epic: ...` is only
  issue text and will be ingested as a normal Job. Existing templates can
  migrate by wrapping the old line in a block comment:
  `<!-- syrus-epic\nEpic: #123\n-->`. When filing child issues immediately
  after an Epic issue, first verify the Epic exists through the admin API or
  create the Epic via the admin API; otherwise the children remain in
  `pending_epic_ref`.
- **UTF-8 byte truncation** — never call `String#byteslice` directly outside
  the `String#safe_byteslice` core extension. Use
  `text.safe_byteslice(start, length)` whenever truncating by bytes before
  persistence, logging, prompt rendering, or UI serialization so multibyte
  characters cannot be split into invalid UTF-8.
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
