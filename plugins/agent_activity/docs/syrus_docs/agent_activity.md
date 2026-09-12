# Agent Activity

The `agent_activity` plugin (`plugins/agent_activity/`) is a live feed of
agent **sessions** -- one card per `Agent` with at least one
`SpawnedProcess(kind: "agent")`, headlined by what that session actually
decided, not a scheduling/timeline view. Workflow-backed cards still represent
agentic Runs (`Step::AGENTIC_KINDS`); chat-backed cards represent a whole
`ChatSession` and collapse multiple turns into one card via the shared
`agent_id`; design-doc-backed cards represent one `DesignDocs::DesignDocAgentRun`.
It is a self-contained Rails engine plugin, installed and enabled by default
(category `observability`; unlike `worker_timeline`/`mysql_db_browser` it has
no separate feature gate -- `PluginRecord.enabled` is the only toggle).
It replaces an earlier time-scaled Gantt/waterfall design for this data (that
metaphor belongs to `worker_timeline`, which visualizes scheduling/overlap,
not session content).

Agent processes only, deliberately: no checks (graders/format/generate) and no
non-agent subprocesses appear here. Workflow PR feedback and CI repair appear
only when they launch an agentic Run; chat turns and design-doc mentions appear
through their own Agent records. The per-Job "Agent Conversation" causal graph
remains separate. See `agent_conversation.md`.

## Role and outcome, never inferred from transcript text

- **Role/label** come structurally from the Agent's resumable:
  `Step::Kind`/`AgentRole.for_step_kind` for workflow Runs,
  `ChatSession#mode` for chat sessions, and design-doc/thread context for
  design-doc agent runs. A plugin-owned agentic workflow step kind that
  declares `agent_role:` on its `Step::Kind` entry is honored the same way
  core kinds are.
- **Outcome summary** (`AgentActivity::OutcomeSummary`) is whatever that
  workflow session actually submitted: `submit_summary` lands directly on
  the `Run` (`agent_summary`/`agent_pr_title`), read as-is.
  `submit_adversarial_review`/`submit_visual_review` land on the shared
  `Workflow#artifacts` iterations array, tagged with the submitting Step's
  `iteration` -- `OutcomeSummary` matches that back to the specific Run's own
  iteration (a Workflow can run several adversarial/visual review rounds,
  one Run each) so a card never shows another iteration's verdict. Chat cards
  currently show no fabricated summary; design-doc cards show the document
  identifier/title as their context.

## Visibility scopes

`AgentActivity::SessionsQuery` takes a `scope:`:

- `:mine` -- workflow-backed Agents whose Jobs are visible through
  `Job.accessible_to(user)` or `Job.effectively_owned_by(user)`, chat-backed
  Agents whose `ChatSession#user_id` is the current user, and design-doc
  Agents whose document is visible through `DesignDocs::DesignDoc.visible_to`.
  Backs `GET /api/v1/app/agent_activity/sessions`
  (`Api::V1::App::AgentActivityController`).
- `:admin` -- every workflow-backed and design-doc-backed Agent on the
  instance, but chat-backed Agents remain self-scoped to the requesting admin.
  Backs `GET /api/v1/app/admin/agent_activity/sessions`
  (`Api::V1::App::Admin::AgentActivityController`, inheriting
  `Api::V1::App::Admin::BaseController#require_admin`).

"Active" means the Agent has at least one unfinished
`SpawnedProcess(kind: "agent")`; it is not a cached column on `agents`.
`running_count` in both responses reflects that within the visibility scope,
independent of whatever filter chips are currently applied. The built-in
`Failed` SmartFolder is likewise process-derived: the Agent's most recent
spawned agent process must have `outcome = "failed"`.

Both endpoints paginate (`page`/`per`, default 20, max 100) and accept the
same shared FilterBar `?q=<base64 filter tree>` wire format
(`AgentActivity::Filter`, subject `:agent_activity`), compiled straight
through the normal `Filters::Compiler` since the underlying query is a single
`Agent` relation (unlike `worker_timeline`'s hand-parsed fixed field set).
Chips: `repository_id` (workflow Job repository, chat attached repository, or
design-doc linked repository), `job_id` (workflow-backed rows only),
`step_kind` (labeled "Role" in the UI; workflow step kinds, chat modes, and
`design_doc`), `agent_provider` (workflow/design-doc provider or chat
provider), `status` (running/latest process outcome), `window` (latest
spawned agent process start time).

## Transcript reuse

Clicking a workflow-backed session card opens a transcript drawer that reuses
the existing log-chunk transcript rendering (`RunTranscriptLogs`,
`app/frontend/routes/jobDetail/components.tsx`) rather than duplicating
`AdminTranscript.tsx`'s live-tail raw-event viewer (a different data shape
meant for deep diagnostic drilling, not a session feed). Workflow rows carry
their own `transcript_path`:

- `:mine` sessions point at the existing repository-ownership-scoped
  `GET /api/v1/app/jobs/:job_id/runs/:run_id/artifacts` route -- no new
  route needed, since that endpoint is already scoped the right way.
- `:admin` sessions point at
  `GET /api/v1/app/admin/agent_activity/sessions/:run_id/artifacts`, a new
  admin-gated route, because the admin feed can list sessions on
  repositories the admin has no membership on and so cannot reuse the
  ownership-scoped Jobs route. Both routes render their JSON through the
  shared `App::RunArtifactsPayload.build(run:)` (`app/services/app/`), so
  the payload shape (`job_id`, `workflow_id`, `run_id`, `base_ref`/
  `head_ref`, `agent_diff`, `logs`) can't drift between the two routes --
  only the authorization/lookup path differs.

Chat-backed session cards do not open an inline transcript drawer. They carry
`chat_path: "/chats/:chat_session_id"` and deep-link to the live chat UI
instead, because a chat transcript is an ongoing multi-turn conversation better
served by the full chat surface than by a single-invocation log drawer.

Design-doc cards render without a transcript drawer until that surface has a
native transcript/artifact route with an equivalent payload.

## Frontend

The primary `sidebar_page` registration and admin `admin_page` registration share one component
(`AgentActivityFeed.tsx`, parameterized by `scope`):

- `agent_activity.mine` (`/agent_activity`) -- any signed-in user.
- `agent_activity.admin` (`/admin/agent_activity`) -- admin-gated in
  `AgentActivity::AdminPages`; the route itself is additionally protected
  by `SpaController#admin_spa_path?` (any `/admin/*` path requires admin) and
  by the admin API controller's own `require_admin`.

Both render a pulsing "N running now" indicator, the shared `FilterBar`, and a
card-per-session feed where each card leads with the session's own submitted
outcome text/verdict. Workflow cards toggle their transcript drawer from that
headline; chat cards make the headline and secondary action links to the live
chat. Agent Activity's built-in `SmartFolder`s are `All`,
`Running`, and `Failed`; bare visits to `/agent_activity` and
`/admin/agent_activity` default to the `Running` folder unless a `q` filter or
explicit `smart_folder_id` parameter is present. Links that need the all-history
feed use `smart_folder_id=` as an explicit no-folder escape hatch. The operator
page exposes the folders through the normal app sidebar, while the admin page
renders the same folders in an in-page `AdminSmartFolderNav` column because
admin plugin pages do not have a nested sidebar hook.
