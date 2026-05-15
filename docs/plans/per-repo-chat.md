# Per-repository chat — research, planning, proposal-driven Job filing

_Captured 2026-05-12. Implementation in 4 PRs (see Build order).
This plan covers the front-half of roadmap M1
(`syrus-as-dev-environment.md` §M1) — the chat exists, has its
own MCP sidecar, and produces proposals that become Syrus Jobs.
The "sessions become a unified pipeline entry-point" half of M1
(option (c)) stays out of scope here._

_Status check 2026-05-13: plan only. No `ChatSession`,
`ChatTurnJob`, chat MCP sidecar, proposal models, or chat UI are present
in the application yet._

## Context

Today's Syrus is one-shot: every conversation with the agent is
scoped to a single Job (issue → PR). There is no place to "talk
to" a repository — to ask architectural questions, sketch out a
multi-Job initiative, or iterate on a plan before filing
anything. The operator either files a fully-formed issue (and
discovers gaps mid-PR) or hand-rolls a plan in another tool
(Claude Code, notes, etc.) and copies the result over.

This plan adds a per-repository chat surface. The agent has its
own mutable checkout, a different MCP toolset than Job runs, and
a system prompt that points it at "research, plan, propose"
rather than "make changes." The chat's durable products are
proposals — drafts of issues that the operator reviews and files
(possibly in bulk, possibly with inter-Job dependencies).

This is the equivalent of what the operator currently does in a
detached Claude Code session: plan a thing, then ask Syrus to do
it. Folding that into Syrus closes the loop: the planning agent
sees Syrus state directly, and its output flows straight into the
Job pipeline.

## Decisions locked

1. **Process model: one-shot `claude --resume` per turn.** Each
   user message enqueues a `ChatTurnJob`; the worker spawns
   claude with `--resume <session_id>` (after the first turn),
   streams events back via Turbo, exits. Re-uses every piece of
   agent infrastructure already battle-tested by the Resume
   trigger kind. No long-lived agent processes to babysit.
2. **One mutable workspace per repository at
   `$SYRUS_DATA_ROOT/chats/<repository_id>/`.** Persistent across
   turns and across chat sessions on the same repo. The agent
   owns the workspace state — checkout, fetch, scratch branches
   are fine. Nothing is ever pushed or committed upstream because
   the chat sidecar exposes no write tools.
3. **No per-turn `git reset`.** The agent is responsible for
   keeping its checkout sensible (returning to the default
   branch after digressions, fetching before answering
   "what's on main now" questions). Operator has manual
   **Refresh repo** and **Reset workspace** buttons as recovery.
4. **No archive concept.** "New chat" is always available. Old
   chats persist in the DB; v1 only surfaces the most recently
   touched. v2 will add the previous-session picker.
5. **Proposals are repo-scoped, not chat-scoped, for the
   operator.** A repo-level **Proposals** tab aggregates every
   `pending` proposal across every chat. Proposals retain their
   `chat_session_id` for traceability + future "resume this chat"
   context, but the review/file/discard UI lives at the repo
   level so proposals outlive the visible chat.
6. **Proposals form a DAG with cascade-filing.** Each proposal
   has an agent-chosen `slug` unique within the session and an
   optional `depends_on` list of other slugs. The proposal
   dependency table mirrors `JobDependency` exactly. Filing a
   proposal also files its transitive upstream closure (with an
   operator confirmation modal); discarding cascades downstream
   (also with confirmation).
7. **Filing is strictly operator-gated.** The MCP sidecar can
   `propose_issue` but cannot file. Filing happens via the
   Proposals tab UI. Keeps proposals reviewable; agent's job is
   to draft, operator's job is to commit.
8. **Default proposal kind is `syrus_issue`.** Direct `Job`
   creation with `kind: direct`, prompt from the body. Faster
   loop than going through a GitHub issue. Agent can override
   with `kind: github_issue` per proposal when the work is for a
   human or wants a GH audit trail.
9. **No turn cap.** Chat is operator-driven. The Stop button is
   the only ceiling.
10. **Stop button non-negotiable** — `chat_sessions.stop_requested_at`
    DB flag + worker polling between stream-json events. ≤ 1
    event of latency.
11. **Broadcast every completed message, not every token.** One
    `ChatMessage` row per logical message (user / assistant text
    / tool_use / tool_result), flushed and Turbo-broadcast as it
    completes.
12. **v1 is Claude-only.** Sidecar binary, MCP config format,
    and stream parser are Claude-flavored. Codex MCP support is
    a follow-up; this is an implementation choice, not a
    protocol constraint.
13. **Retry off.** `ChatTurnJob` does not auto-retry. If a turn
    fails (worker crash, claude error), the user message stays
    in the transcript with no assistant reply; operator decides
    whether to resend or stop.
14. **Token cost surfaced.** Cumulative cost on the chat header,
    updated per turn from the `result` event's `usage` field.
15. **First-clone is async-gated.** The chat UI renders
    immediately; the compose box is disabled until the workspace
    is ready. A system message lands ("Cloning <repo>… ready.")
    when the clone finishes.

## Components

### 1. Data model

```ruby
# db/migrate/<ts1>_create_chat_sessions.rb
create_table :chat_sessions do |t|
  t.references :repository,    null: false, foreign_key: true
  t.references :user,          null: false, foreign_key: true
  t.string  :title                                   # auto-derived from first user message; editable
  t.datetime :last_message_at
  t.datetime :stop_requested_at                       # set by web "Stop"; cleared on next turn start
  t.integer  :cumulative_input_tokens, default: 0,  null: false
  t.integer  :cumulative_output_tokens, default: 0, null: false
  t.timestamps
end
add_index :chat_sessions, [ :repository_id, :last_message_at ]

# db/migrate/<ts2>_create_chat_messages.rb
create_table :chat_messages do |t|
  t.references :chat_session, null: false, foreign_key: true
  t.string :role, null: false                         # user | assistant | tool_use | tool_result | system
  t.jsonb  :content, null: false                      # stream-json event for non-user rows; { text: "..." } for user
  t.string :tool_name                                 # populated for tool_use / tool_result
  t.string :tool_use_id                               # pairs tool_use → tool_result
  t.references :proposal, foreign_key: { to_table: :chat_proposals }  # set on the assistant turn that produced the proposal
  t.timestamps
end
add_index :chat_messages, [ :chat_session_id, :created_at ]

# db/migrate/<ts3>_create_chat_proposals.rb
create_table :chat_proposals do |t|
  t.references :chat_session, null: false, foreign_key: true
  t.string :slug,    null: false                      # agent-chosen, unique within session
  t.string :title,   null: false
  t.text   :body,    null: false
  t.string :kind,    null: false, default: "syrus_issue"  # syrus_issue | github_issue
  t.string :labels                                    # comma-separated; nil for kind=syrus_issue
  t.string :state,   null: false, default: "pending"  # pending | filed | discarded
  t.references :job,                foreign_key: true                 # set on file (kind=syrus_issue)
  t.integer    :github_issue_number                                   # set on file (kind=github_issue); paired with job_id once Syrus picks the issue up
  t.datetime :filed_at
  t.datetime :discarded_at
  t.timestamps
end
add_index :chat_proposals, [ :chat_session_id, :slug ], unique: true
add_index :chat_proposals, [ :chat_session_id, :state ]

# db/migrate/<ts4>_create_chat_proposal_dependencies.rb
create_table :chat_proposal_dependencies do |t|
  t.references :proposal,   null: false, foreign_key: { to_table: :chat_proposals }
  t.references :depends_on, null: false, foreign_key: { to_table: :chat_proposals }
  t.timestamps
end
add_index :chat_proposal_dependencies, [ :proposal_id, :depends_on_id ], unique: true

# db/migrate/<ts5>_make_claude_session_polymorphic.rb
# ClaudeSession currently belongs_to :run. Make it polymorphic so a
# ChatSession can own one too.
add_reference :claude_sessions, :resumable, polymorphic: true
# Backfill: UPDATE claude_sessions SET resumable_type='Run', resumable_id=run_id
remove_column :claude_sessions, :run_id   # AFTER backfill, in a separate migration
```

`ChatSession#cumulative_input_tokens` / `_output_tokens` are
updated by the ChatTurnJob from the stream-json `result` event's
`usage` payload at end-of-turn. UI multiplies by the provider's
per-token price to surface dollar cost.

### 2. Chat workspace

`app/services/chat_workspace.rb` (new), mirrors
`WorkflowWorkspace` but with different lifecycle rules:

- One per Repository (singleton): path is
  `$SYRUS_DATA_ROOT/chats/<repository_id>/`.
- `ChatWorkspace.ensure!(repository)`:
  - First call: shallow-clone the repo via the same `GitRunner`
    path used by `WorkflowWorkspace`. Adds `.syrus/` to
    `.git/info/exclude` for consistency with the grade-output
    convention.
  - Subsequent calls: no-op if workspace exists.
- `ChatWorkspace#reset!(repository)`: removes the workspace and
  re-creates it. Used by the operator's "Reset workspace" button.
- `ChatWorkspace#refresh!(repository)`: runs `git fetch --all
  --prune` against origin. Used by the "Refresh repo" button.
- **No periodic prune.** Unlike workflow workspaces, chat
  workspaces are long-lived. The only cleanup trigger is
  `Repository#destroy` (cascading via a model callback that
  calls `ChatWorkspace.destroy!(repository)`).
- **Concurrency:** all writes are serialized at the
  `ChatTurnJob` level via Solid Queue's `limits_concurrency`
  keyed on `chat:<repository_id>`. The "Refresh repo" and "Reset
  workspace" operator actions also acquire that lock (run
  through a small `ChatWorkspaceJob` that does the same `key`).

### 3. MCP sidecar — `bin/syrus-chat-sidecar`

New binary at `bin/syrus-chat-sidecar`. Implementation in
`app/services/syrus_chat_mcp/` mirroring `app/services/syrus_mcp/`'s
structure:

- `SyrusChatMcp::Sidecar` (boots `MCP::Server`, SIGTERM trap,
  stdio transport).
- One Ruby file per tool.

The sidecar receives the `chat_session_id` via env var
(`SYRUS_CHAT_SESSION_ID`) injected by `ChatTurnJob` when it
writes the per-turn mcp.json. Tool calls look up the session
and mutate `ChatProposal` rows directly. Same DB connection
pattern as the existing sidecar.

**Tools:**

| Tool | Purpose |
|---|---|
| `propose_issue(slug, title, body, kind?, labels?, depends_on?)` | Create or update a `ChatProposal` row. Idempotent on `slug`. Validates `depends_on` slugs exist in this session at call time. Rejects cycles. |
| `list_proposals()` | Returns all proposals on this session (pending/filed/discarded) with their full content + dependency graph. Lets the agent re-orient after context summary. |
| `delete_proposal(slug)` | Marks the proposal `discarded`. Cascade-discards downstream dependents (returns the cascade list so the agent can mention it). |
| `read_job(job_id)` | Pulls Job metadata + summary + transcript head/tail. Lets the agent cite prior work. |
| `list_jobs(state?, label?, limit?)` | Query Syrus's own state. Defaults to `state: open`, `limit: 20`. |
| `read_pr(pr_number)` | Fetches a PR's title/body/diff from GitHub via the user's `GithubClient`. |
| `repo_info()` | Returns repo metadata (default branch, recent commits on default, list of branches with HEAD shas) — saves the agent shell turns. |

Explicitly NOT exposed: `submit_summary`, `file_proposal`, any
write-to-workspace tool. The sidecar config sets `alwaysLoad:
true` per the existing convention so tools survive `--resume`.

### 4. `ChatTurnJob`

`app/jobs/chat_turn_job.rb`:

```ruby
class ChatTurnJob < ApplicationJob
  queue_as :default
  # Retries OFF — chat failures should be visible to the operator,
  # not silently retried.
  discard_on StandardError

  limits_concurrency to: 1, key: -> (chat_session_id, _msg_id) {
    chat = ChatSession.find(chat_session_id)
    "chat:#{chat.repository_id}"
  }, duration: 30.minutes

  def perform(chat_session_id, user_message_id)
    chat = ChatSession.find(chat_session_id)
    # 1. clear any stale stop request (new turn starting fresh)
    chat.update!(stop_requested_at: nil)
    # 2. ensure workspace exists (may block on first clone — broadcast a
    #    system message before/after)
    # 3. write the chat sidecar's mcp.json to a tempfile
    # 4. compose the prompt: this turn's user content + system prompt
    #    only on first turn (subsequent turns rely on --resume to carry
    #    system context)
    # 5. spawn AgentInvocation with --resume <session_id> if present,
    #    NO --max-turns
    # 6. stream events:
    #     - on each completed assistant / tool_use / tool_result,
    #       create a ChatMessage row, broadcast via Turbo Streams
    #     - between events, check chat.reload.stop_requested_at;
    #       if set, SIGTERM the subprocess and record a system
    #       "cancelled by user" message
    # 7. on exit: persist ClaudeSession (polymorphic attach to chat),
    #    update chat.last_message_at + cumulative tokens
  end
end
```

`AgentInvocation` already handles `--resume <session_id>`,
stream-json parsing, `--mcp-config`, and SIGTERM cleanup. The
only new wiring is the chat-specific mcp.json content (pointing
at `bin/syrus-chat-sidecar` instead of `bin/syrus-mcp-sidecar`)
and the chat-specific event handling.

The Turbo broadcast target is `chat_session_#{chat.id}_messages`;
the chat UI subscribes to that stream.

### 5. Stop button

`POST /repositories/:repo_id/chats/:chat_id/stop` action sets
`chat_session.stop_requested_at = Time.current` and broadcasts a
button-state update. The worker's stream-json loop already
reloads the chat between events (it's reading message rows
anyway); a `stop_requested_at > turn_started_at` check is added
on each iteration.

When stop is detected:

1. SIGTERM the claude subprocess.
2. Wait briefly for it to exit (≤ 2s); SIGKILL if still alive.
3. Persist whatever ChatMessage rows already landed.
4. Write a `role: system, content: { text: "Cancelled by
   operator." }` ChatMessage.
5. Update `chat.last_message_at`, capture partial ClaudeSession
   if any was written to disk.
6. Release concurrency lock.

The chat UI shows the partial response + the cancellation marker;
operator's next compose-and-send starts a fresh turn (which
clears `stop_requested_at` at step 1 of `ChatTurnJob#perform`).

### 6. Proposals tab + filing UI

`app/controllers/repositories/proposals_controller.rb` (new):

- `index` — list all `ChatProposal.where(state: "pending")` on
  the repo (with toggle to also show recently filed/discarded),
  ordered by DAG layer (roots first). Renders the proposal card
  list with the action buttons.
- `update` — edit title/body/labels.
- `destroy` — discard a proposal, cascading downstream.
- `file` — file a single proposal + its transitive upstream
  closure (single ID + optional cascade flag).
- `file_bulk` — file multiple selected proposals + the union of
  their transitive upstream closures.

Filing implementation (`app/services/chat_proposal_filer.rb`):

```ruby
class ChatProposalFiler
  def initialize(user:, repository:)
    @user = user; @repo = repository
  end

  def file!(selected_proposals)
    closure = transitive_upstream_closure(selected_proposals)
    ordered = topological_sort(closure)
    ApplicationRecord.transaction do
      job_by_proposal = {}
      ordered.each do |prop|
        job = create_job_for(prop)
        prop.update!(state: "filed", job: job, filed_at: Time.current)
        job_by_proposal[prop.id] = job
        prop.dependencies.each do |dep|
          next unless job_by_proposal[dep.id]
          JobDependency.create!(dependent: job, depends_on: job_by_proposal[dep.id])
        end
      end
    end
  end

  private

  def create_job_for(prop)
    case prop.kind
    when "syrus_issue" then create_direct_job(prop)
    when "github_issue" then file_github_issue_then_direct_job(prop)  # see note
    end
  end
end
```

**Note on github_issue filing:** the simplest implementation
files the GH issue with the trigger label and lets normal polling
discover it as a Job. But then the proposal → Job link is
deferred until polling. Two options:

  a. **File GH issue + return; let polling create the Job.**
     ChatProposal stores `github_issue_number`; `job_id` filled
     in later by a small reconciliation job. Simple, asynchronous.
  b. **File GH issue + immediately create the Job with the GH
     issue number attached.** Bypasses polling for these
     proposals. Faster, but duplicates Job-creation logic.

Recommend **(a)** for v1 — re-uses the polling path, which is
where bugs would be the most expensive. `JobDependency` rows
between filed proposals where one is `github_issue` and not yet
polled need to be created against placeholder Jobs OR deferred
until both Jobs exist. Cleanest: only support cross-proposal
dependencies where all involved proposals are `syrus_issue`.
For github_issue proposals with deps, surface a warning in the
file modal: "this proposal depends on others; we recommend
filing as `syrus_issue` for inline dependency wiring, or filing
them separately."

UI:

- **List view** at `/repositories/:slug/proposals` — grouped by
  DAG layer with indentation showing dependencies.
- **Proposal card**: title, body excerpt (expandable), kind
  badge, dependency chips, action buttons (Edit / Discard /
  File this).
- **Selection mode** — checkboxes + sticky bottom bar with
  "File selected (N)" and "Discard selected (N)" once any are
  checked.
- **File modal**: shows the transitive closure that will be
  filed, lets the operator review the body of each before
  confirming.
- **Edit modal**: inline title + body editor.

### 7. Chat UI

`app/controllers/repositories/chats_controller.rb` (new):

- `show` — renders the current chat for this repo (newest
  ChatSession by `last_message_at`, or an empty "new chat" view
  if none exist yet).
- `create` — called by the compose form when the chat is still
  ephemeral (no row yet). Creates the ChatSession + first
  ChatMessage + enqueues ChatTurnJob. Returns a redirect to
  `show`.
- `message` — called by compose form when a chat already
  exists. Creates a ChatMessage + enqueues ChatTurnJob.
- `stop` — sets `stop_requested_at`.
- `refresh` — enqueues a `ChatWorkspaceJob(action: :refresh)`.
- `reset` — enqueues `ChatWorkspaceJob(action: :reset)`.

The chat page (`app/views/repositories/chats/show.html.erb`):

```
+-------------------------------------------------+
| Chat — Repository <slug>            [New chat]  |
| Tokens: 12.4k in / 3.2k out · $0.04             |
+-------------------------------------------------+
| (turbo-streamed message rows)                   |
| user: ...                                       |
| assistant: ...                                  |
| tool_use: propose_issue (slug: "add-auth")      |
|   → ChatProposal #42 created (pending)          |
| assistant: ...                                  |
+-------------------------------------------------+
| [Compose textarea]              [Send] [Stop]   |
| [Refresh repo]  [Reset workspace]   gear ⚙     |
+-------------------------------------------------+
```

A Stimulus controller (`chat_controller.js`) handles:

- Auto-scroll-to-bottom on new message arrival (unless the user
  has scrolled up, in which case show a "new messages ↓" pill).
- Compose box enable/disable based on `data-turn-in-flight`.
- "New chat" button — POSTs to `create` with an empty body, then
  navigates to the new chat.

`tool_use` and `tool_result` rows are collapsible cards rendered
in monospace; default-collapsed for noise tools (`list_jobs`,
`repo_info`), default-expanded for proposal-related ones.

### 8. System prompt

`app/services/prompts/chat_system.rb`:

```ruby
module Prompts
  class ChatSystem
    def initialize(repository:)
      @repository = repository
    end

    def to_s
      <<~PROMPT
        You are an embedded research and planning assistant for the
        #{@repository.slug} repository. Your role is to help the
        operator inspect the code, think through changes, and draft
        Syrus Jobs — NOT to make code changes yourself.

        Your environment:

          - Your cwd is a persistent local checkout of the repository.
            It is yours to navigate as you see fit: checkout branches,
            fetch, diff, grep, anything that helps you answer the
            operator's questions.
          - The workspace is isolated. Nothing you do is ever pushed,
            committed upstream, or seen by any other process. No
            commit or push tool is available to you here.
          - The workspace persists across turns. If you check out a
            feature branch to investigate, the next turn starts there
            — switch back to the default branch when you're done with
            the digression.
          - The workspace may drift behind origin. Run `git fetch`
            (or use the `repo_info` tool) when you need a current
            view, especially when answering "what's on main right
            now" questions.

        Your output:

          - The only durable products of this session are the proposals
            you draft via the `propose_issue` MCP tool. The operator
            reviews proposals in a separate UI; they choose what to
            file and when. You are a drafter, not a dispatcher.
          - Use unique, stable, descriptive `slug`s — they identify
            proposals across your turns and across operator UI.
          - Express dependencies between proposals when they exist
            ("Add user model" before "Add auth endpoints"). The
            operator can cascade-file a proposal and have all its
            upstream proposals filed in order.
          - Default `kind: "syrus_issue"` — direct Job creation.
            Use `kind: "github_issue"` only when the work is for a
            human or wants a public GitHub audit trail.

        How to be helpful:

          - Recommend; don't decide. Surface tradeoffs. Ask clarifying
            questions when the operator's intent is ambiguous.
          - Cite specific files and line numbers. "I saw X at app/
            services/foo.rb:42" beats "there's a thing in services."
          - Inspect prior Jobs (`list_jobs`, `read_job`) when the
            operator references past work or when you suspect a
            proposal duplicates something already in flight.
      PROMPT
    end
  end
end
```

The system prompt is included only on the first turn; subsequent
turns rely on `--resume` to carry it forward.

### 9. Repository wiring

`app/models/repository.rb`:

- `has_many :chat_sessions, dependent: :destroy`
- `has_many :chat_proposals, through: :chat_sessions`
- `def current_chat_session = chat_sessions.order(last_message_at: :desc).first`
- Callback: `before_destroy :destroy_chat_workspace`

`app/models/chat_session.rb`:

- `has_many :messages, class_name: "ChatMessage", dependent: :destroy`
- `has_many :proposals, class_name: "ChatProposal", dependent: :destroy`
- `has_one :claude_session, as: :resumable, dependent: :destroy`
- Methods: `#cumulative_cost`, `#in_progress?` (truthy while a
  ChatTurnJob is running — derived from "most recent user message
  has no following assistant or system message").

### 10. Provider gate

`app/views/repositories/show.html.erb` (Chats tab):

- If `Current.user.agent_provider == "codex"`, show:
  > Chat requires Claude. Switch your agent provider to Claude
  > in [Credentials](/credentials/edit) to enable per-repo chat.
- If no Claude credential at all, show a similar onboarding card.

The provider check happens at the Chats tab level + at compose
submit time (`ChatTurnJob` errors out if the user has no Claude
credential).

## Files to create / modify

**New:**

- `app/services/chat_workspace.rb`
- `app/services/chat_proposal_filer.rb`
- `app/services/prompts/chat_system.rb`
- `app/services/syrus_chat_mcp/sidecar.rb`
- `app/services/syrus_chat_mcp/propose_issue_tool.rb`
- `app/services/syrus_chat_mcp/list_proposals_tool.rb`
- `app/services/syrus_chat_mcp/delete_proposal_tool.rb`
- `app/services/syrus_chat_mcp/read_job_tool.rb`
- `app/services/syrus_chat_mcp/list_jobs_tool.rb`
- `app/services/syrus_chat_mcp/read_pr_tool.rb`
- `app/services/syrus_chat_mcp/repo_info_tool.rb`
- `app/jobs/chat_turn_job.rb`
- `app/jobs/chat_workspace_job.rb`
- `app/models/chat_session.rb`
- `app/models/chat_message.rb`
- `app/models/chat_proposal.rb`
- `app/models/chat_proposal_dependency.rb`
- `app/controllers/repositories/chats_controller.rb`
- `app/controllers/repositories/proposals_controller.rb`
- `app/views/repositories/chats/show.html.erb` + partials
- `app/views/repositories/proposals/index.html.erb` + partials
- `app/javascript/controllers/chat_controller.js`
- `bin/syrus-chat-sidecar`
- 5 migrations (see §1)
- Specs for every new service, model, job, controller, and
  sidecar tool.

**Modified:**

- `app/models/claude_session.rb` — polymorphic
  `belongs_to :resumable`. Existing `Run#claude_session` becomes
  `has_one :claude_session, as: :resumable, dependent: :destroy`.
- `app/models/repository.rb` — chat associations + workspace
  destroy callback.
- `app/views/repositories/show.html.erb` — Chats + Proposals
  tabs added to the nav strip.
- `config/routes.rb` — nested routes under repositories for
  chats, proposals.
- `app/services/agent_invocation.rb` — verify no changes needed;
  the existing `--resume` + `--mcp-config` paths cover this.
  Document the chat use case in the class comment.
- `README.md` — short blurb on per-repo chat in the feature list.
- `CLAUDE.md` — agent guide entry for the chat sidecar +
  workspace conventions.

## Build order

Ship as 4 PRs:

1. **Data model + ChatWorkspace.** Migrations,
   `ChatSession` / `ChatMessage` / `ChatProposal` /
   `ChatProposalDependency` models, polymorphic `ClaudeSession`
   migration + backfill, `ChatWorkspace` service. No UI yet.
   Tests cover model validations, workspace lifecycle, DAG
   topo sort + cycle rejection.
2. **MCP sidecar + ChatTurnJob.** `bin/syrus-chat-sidecar` and
   all its tools, `ChatTurnJob`, `Prompts::ChatSystem`. Tested
   end-to-end via stubbed `AgentInvocation.runner`. No UI yet —
   exercise the turn loop from rspec.
3. **Chat UI + workspace ops UI.** Chats tab on repository
   page, chat show view with Turbo streaming, compose form,
   Stop / Refresh / Reset buttons + their jobs, system message
   for "Cloning…" state. End-to-end browser test via Capybara
   (or equivalent) for the happy path: open chat → send message
   → see assistant response stream in → click Stop mid-turn.
4. **Proposals tab + filing UI.** Repo-scoped Proposals tab,
   list/edit/discard/file flows, cascade modals, integration
   with `JobDependency`. End-to-end test: chat creates 3
   proposals with deps → operator files the leaf → 3 Jobs
   created with 2 JobDependency rows.

## Verification

1. **Unit:** full spec suite green; new specs cover topo sort,
   cycle rejection, cascade discard, proposal filing closure,
   chat turn happy path, stop button mid-turn, workspace
   lifecycle, sidecar tool behavior under stubbed DB.
2. **End-to-end on syrus-test:**
   a. Open the Chats tab on `syrus-test`. Send "What's the
      Workflow chain for `pr_comment` initial?" Confirm the
      agent inspects `app/services/workflows/pr_feedback.rb` and
      answers without proposing anything.
   b. Send "Draft three issues to add a `cron_template`
      duplication button — model change first, controller next,
      view last. Make the controller and view depend on the
      model." Confirm 3 proposals land with the right
      `depends_on` chain. Confirm they appear in the Proposals
      tab grouped by layer.
   c. From the Proposals tab, click File on the leaf (view
      proposal). Confirm the cascade modal lists all 3.
      Confirm 3 Jobs created with 2 JobDependency rows wired in
      topological order.
   d. While a turn is mid-flight, click Stop. Confirm partial
      assistant output is preserved, "Cancelled by operator."
      system message appears, compose box re-enables.
   e. Click Refresh repo; confirm the chat workspace's
      `git fetch` runs without affecting the conversation.
   f. Open a new chat. Confirm the previous chat's pending
      proposals are still in the Proposals tab.
3. **Cost surface:** after a few turns, confirm cumulative
   token counts match `claude_session.transcript_jsonl` parsed
   for `usage.input_tokens` / `usage.output_tokens`.
4. **Codex user gate:** flip the user's `agent_provider` to
   `codex`. Reload Chats tab; confirm the "requires Claude"
   notice replaces the chat view.

## Things to flag, not blockers

- **Conversation drift across operator edits.** When the
  operator edits a proposal's body, the agent's next turn sees
  the edit via `list_proposals` — but the agent's session JSONL
  still contains the original. No correctness issue (the agent
  can read the current state), but the agent may briefly be
  surprised if the operator's edit is large. Acceptable.
- **First-clone duration on large repos.** Shallow clone helps;
  worst case is ~30s for a big repo. The async-gated UI handles
  the wait gracefully but the operator's first impression of a
  large repo is "the compose box is grayed out."
- **Cross-proposal dependencies for github_issue proposals.**
  Deferred to v2 — for now the file UI warns the operator and
  recommends `kind: syrus_issue` for any DAGs.
- **Token cost surfacing is post-turn.** No mid-turn cost meter
  because stream-json doesn't report incremental usage; the
  `result` event lands once at end-of-turn. Acceptable.
- **Workspace bloat over time.** A long-lived chat workspace
  accumulates fetched objects, scratch branches, etc. No
  automatic gc here; if operator notices bloat, they hit
  "Reset workspace." Could add a periodic `git gc --auto` later.
- **Idle-session token usage in Anthropic's caching window.**
  --resume should benefit from prompt caching across turns
  within 5 minutes of each other. Long pauses between turns
  pay the full cost on the next turn. Document but don't
  mitigate.
- **Pricing constants.** Cost surface hard-codes Claude's
  current input/output token prices. When prices change or new
  models are added, update `app/models/chat_session.rb#cost_per_token`.
  Don't reach for a dynamic price API.
- **Stop button while workspace is being refreshed.** The
  `ChatWorkspaceJob` doesn't check `stop_requested_at`. Refresh
  / Reset operations run to completion regardless. Acceptable —
  they're short.
