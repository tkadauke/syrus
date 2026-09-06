# Agent Conversation

The **Agent Conversation** tab on the Job Detail page
(`app/frontend/routes/jobDetail/AgentConversation.tsx`) renders an explicit
node/edge causal graph of everything that fed into a Job's implementation --
agent sessions, deterministic checks, and external triggers -- statically
scoped to the current Job (no job picker; the Job is already the page
context). It is core, not a plugin, and is a different surface from the
`agent_activity` plugin's sessions-only feed (see `agent_activity.md`): this
tab additionally shows *why* an attempt started and *what checked it*, not
just what an agent session said.

This is a causal graph, not a time-scaled Gantt/waterfall -- order only, no
time axis. It intentionally does not reuse the `worker_timeline` plugin's
timeline/bar components.

## Backend: `App::AgentConversationPayload`

`GET /api/v1/app/jobs/:job_id/agent_conversation`
(`Api::V1::App::JobsController#agent_conversation`) renders
`App::AgentConversationPayload.build(job:)`. It walks the Job's Workflows in
chronological order and, within each, its Steps (and each agentic Step's
Runs), emitting three node kinds:

- `agent_session` -- one per agentic Run. `role` comes structurally from
  `AgentRole.for_step_kind(step.kind)` (never inferred from transcript text,
  same derivation the `agent_activity` plugin uses), `summary`/`detail.verdict`
  come from `submit_summary`/`submit_adversarial_review`/`submit_visual_review`
  the same way `AgentActivity::OutcomeSummary` reads them.
- `deterministic_check` -- one per non-agentic, outcome-bearing Step
  (`grader`, `format`, `generate`, `dependency_audit`). `detail` is that
  Step's own `details` hash (or, for `dependency_audit`, the Workflow's
  `dependency_audit` artifact) -- the same raw `output`/`command`/
  `*_failures` fields graders already capture, not a new capture path.
- `external_trigger` -- one per Workflow whose `trigger_kind` is
  `pr_comment`, `chat_feedback`, or `ci_failure`, sourced from the artifact
  that caused the Workflow to fire (`pr_comments`, `chat_feedback`,
  `failed_checks`).

Edges within a Workflow are read off each Step's own graph edges
(`depends_on_step_ids`, falling back to the `previous_step` chain) rather
than recomputed from Step order -- this is what makes a `grader_fanout`'s
parallel `grader` Steps fan out from one predecessor and fan back into one
successor with no kind-specific graph code. `WorkflowGraphBuilder` skips
non-outcome-bearing Steps (`prepare`, `grader_fanout`, `grader_collect`,
`pr_open`, `push`, ...) as nodes but resolves *through* them so upstream/
downstream real nodes still connect.

## Frontend

`agentConversationGraph.ts` holds the pure layout/label logic, kept separate
from rendering so it can be unit tested without mounting React:

- `buildConversationRows` groups adjacent `deterministic_check` nodes that
  share the exact same predecessor-id set into one row -- this is what a
  `grader_fanout`'s parallel checks look like in the node list. Every other
  node kind always gets its own row. This is also what keeps a connector's
  label out of a fixed-width column gap: the whole tab renders as a single
  vertical thread (one row per line), not side-by-side columns, so a
  connector's label lives in normal document flow between two rows and wraps
  to however much height it needs instead of being squeezed into a narrow
  midpoint gap.
- `edgeLabel`/`connectorLabel` generate a short handoff description from the
  node/edge data (kind, label, `state`, `detail.verdict`) -- e.g. "rspec
  failed — Landing fix repair requested" -- never a hardcoded string keyed on
  a specific step or grader name, so a new grader or step kind gets a
  sensible label for free. A fan-in row (multiple checks merging into one
  next node) aggregates to `"N/M checks passed — ..."`; a fan-out row
  (one predecessor spawning multiple checks) aggregates to
  `"... — N checks started"`.
- `avatarColorClass` assigns each `agent_session` a distinct avatar color by
  `AgentRole` bucket (implement uses the semantic `bg-brand` token; other
  roles use small distinct Tailwind hues, matching the categorical-color
  precedent already used for tags/proposals elsewhere in the app) so a
  reader can tell participants apart at a glance, the same way a chat
  thread's avatars do.

Clicking an `agent_session` card reuses the exact same transcript mechanism
as the `agent_activity` plugin's sessions feed: `RunTranscriptLogs` fed by
`GET /api/v1/app/jobs/:job_id/runs/:run_id/artifacts`. Clicking a
`deterministic_check` card shows only its captured raw command output/
command line (`detail.output`, `detail.command`, or a `format`/`generate`
step's `*_failures` entries) -- no "reasoning" framing, since there is no
agent turn to show for a deterministic step. An `external_trigger` node
renders as a full-width dashed banner spanning the thread (not a card in a
row), showing the triggering content and linking to its source (the PR, or
the failing CI check's `html_url`) where a source URL can be derived; chat
feedback triggers have no linkable source today.
