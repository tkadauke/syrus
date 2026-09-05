# Agent Activity

The `agent_activity` plugin (`plugins/agent_activity/`) is a live feed of
agent **sessions** -- one card per `Run` whose `Step#kind` is agentic
(`Step::AGENTIC_KINDS`), headlined by what that session actually decided, not
a scheduling/timeline view. It is a self-contained Rails engine plugin,
installed and enabled by default (category `observability`; unlike
`worker_timeline`/`mysql_db_browser` it has no separate feature gate --
`PluginRecord.enabled` is the only toggle). It replaces an earlier
time-scaled Gantt/waterfall design for this data (that metaphor belongs to
`worker_timeline`, which visualizes scheduling/overlap, not session
content).

Sessions only, deliberately: no checks (graders/format/generate) and no
external triggers (chat/PR feedback, CI failures) appear here -- those are
covered by a separate per-Job "Agent Conversation" causal graph from the
same Epic (EPIC-307), not by this feed.

## Role and outcome, never inferred from transcript text

- **Role/label** come structurally from the `Step::Kind` registry
  (`app/models/step/kind.rb`): `AgentRole.for_step_kind(step.kind)` (shared
  with `McpToolContext.from_run`, which uses the same derivation to pick an
  agent's MCP role) and `Step::Kind.label_for(step.kind)`. A plugin-owned
  agentic step kind that declares `agent_role:` on its `Step::Kind` entry
  (e.g. `agent_insights`' `agent_insight_run`) is honored the same way core
  kinds are.
- **Outcome summary** (`AgentActivity::OutcomeSummary`) is whatever that
  specific session actually submitted: `submit_summary` lands directly on
  the `Run` (`agent_summary`/`agent_pr_title`), read as-is.
  `submit_adversarial_review`/`submit_visual_review` land on the shared
  `Workflow#artifacts` iterations array, tagged with the submitting Step's
  `iteration` -- `OutcomeSummary` matches that back to the specific Run's own
  iteration (a Workflow can run several adversarial/visual review rounds,
  one Run each) so a card never shows another iteration's verdict. A session
  that submitted nothing yet (still running, or a plain `implement`/`respond`
  step with no dedicated submit tool) shows no headline rather than a
  fabricated one.

## Visibility scopes

`AgentActivity::SessionsQuery` takes a `scope:`:

- `:mine` -- repositories the current user belongs to
  (`Current.user.repositories.active`) plus Jobs they effectively own
  (`Job.effectively_owned_by`, `app/models/job.rb`), unioned. Backs
  `GET /api/v1/app/agent_activity/sessions`
  (`Api::V1::App::AgentActivityController`).
- `:admin` -- every session on the instance, no repository restriction.
  Backs `GET /api/v1/app/admin/agent_activity/sessions`
  (`Api::V1::App::Admin::AgentActivityController`, inheriting
  `Api::V1::App::Admin::BaseController#require_admin`).

"Active" means the `Run` is in the `running` AASM state, not `queued` --
`running_count` in both responses reflects that within the visibility scope,
independent of whatever filter chips are currently applied (a "N running
now" status indicator, not a filtered count).

Both endpoints paginate (`page`/`per`, default 25, max 100) and accept the
same shared FilterBar `?q=<base64 filter tree>` wire format
(`AgentActivity::Filter`, subject `:agent_activity`), compiled straight
through the normal `Filters::Compiler` since the underlying query is a single
`Run` relation (unlike `worker_timeline`'s hand-parsed fixed field set).
Chips: `repository_id`/`job_id` (fk), `step_kind` (labeled "Role" in the UI,
values are `Step::AGENTIC_KINDS`), `agent_provider` (enum, `User
.agent_providers`), `status` (enum, Run states), `window` (date, `started_at`).

## Transcript reuse

Clicking a session card opens a transcript drawer that reuses the existing
log-chunk transcript rendering (`RunTranscriptLogs`,
`app/frontend/routes/jobDetail/components.tsx`) rather than duplicating
`AdminTranscript.tsx`'s live-tail raw-event viewer (a different data shape
meant for deep diagnostic drilling, not a session feed). Each session row
carries its own `transcript_path`:

- `:mine` sessions point at the existing repository-ownership-scoped
  `GET /api/v1/app/jobs/:job_id/runs/:run_id/artifacts` route -- no new
  route needed, since that endpoint is already scoped the right way.
- `:admin` sessions point at
  `GET /api/v1/app/admin/agent_activity/sessions/:run_id/artifacts`, a new
  admin-gated route returning the same JSON shape (`job_id`, `workflow_id`,
  `run_id`, `base_ref`/`head_ref`, `agent_diff`, `logs`), because the admin
  feed can list sessions on repositories the admin has no membership on and
  so cannot reuse the ownership-scoped Jobs route.

## Frontend

Two `sidebar_page` registrations share one component
(`AgentActivityFeed.tsx`, parameterized by `scope`):

- `agent_activity.mine` (`/agent_activity`) -- any signed-in user.
- `agent_activity.admin` (`/admin/agent_activity`) -- admin-gated in
  `AgentActivity::SidebarPages`; the route itself is additionally protected
  by `SpaController#admin_spa_path?` (any `/admin/*` path requires admin) and
  by the admin API controller's own `require_admin`.

Both render a pulsing "N running now" indicator, three quick-filter pills
(Running now / Needs work / All history -- fixed local presets, not
user-defined `SmartFolder`s; this pass intentionally scoped smart folders
out, see the Epic), the shared `FilterBar`, and a card-per-session feed
where each card leads with the session's own submitted outcome text/verdict.
