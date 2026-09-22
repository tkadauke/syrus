# MCP tool capability, agent roles, and memory policy

Captured July 18, 2026.

_Status check 2026-09-19: complete. `AgentRole` (`app/services/agent_role.rb`),
`McpToolPolicy`/`McpToolContext`, the `agent_insight` trigger kind and
`plugins/agent_insights` (`Suggestion` model, `submit_insight`/`list_insights`/
`read_insight`/`update_insight`/`retire_insight` tools), and the memory system
evolved into `plugins/agent_memory`'s `AgentMemory::Entry` with capability-gated
read/write/search/list/publish/unpublish/delete tools all shipped. Retained as
design history._

## Goal

Make Syrus deliberate about what an agent is allowed to know, remember,
inspect, and mutate.

This should be built in three layers that depend on each other:

1. **Memory system** - durable, scoped context that extends the memory
   primitives Syrus already has.
2. **Agent roles** - explicit execution profiles that decide which memory,
   repository context, objects, and MCP tools an agent may access.
3. **Insight jobs** - infrastructure jobs that use the first two layers to
   inspect agent struggles and propose improvements without overstepping.

The target outcome is that agents get enough context to be effective without
leaking data across users, repositories, jobs, epics, or unrelated chats.

## Why This Matters

Syrus now has several MCP tool surfaces:

- workflow tools under `SyrusMcp::Sidecar`;
- chat tools under `SyrusChatMcp::Sidecar`;
- deferred chat tools for larger reads;
- admin, local, and coding-mode tool subsets.

Those grew organically. Tool availability is currently too tied to which
sidecar binary happens to be running. The long-term model should be:

```ruby
AgentRole.resolve(context).allowed_capabilities
McpToolPolicy.for(context).allowed_tools
MemoryPolicy.for(context).allowed_scopes
```

Memory is the foundation. Roles decide what an agent may do with that memory
and which tools it receives. Insights are a consumer of those policies, not a
separate privileged side channel.

## Current Implementation Snapshot

This plan is not starting from zero. The current codebase already has pieces of
all three layers, but they are not yet organized behind one policy model.

### Existing Memory Surface

The current durable memory primitive is the `ChatMemory` Active Record model.
This plan should extend that existing primitive before introducing a parallel
model.

Current behavior:

- `ChatMemory` supports `global` and `repository` scopes.
- Supported kinds are `user_pref`, `project_fact`, `feedback`, `reference`,
  and `decision`.
- Memories belong to a `User`, can be soft-deleted, and repository memories
  can be published for other users who have the repository in scope.
- Chat prompts inject selected memories through `Prompts::MemoryContext`.
- Chat MCP exposes memory read/search/list/write/publish/unpublish/delete
  tools.
- Workflow MCP can read a memory by ID for the current Job's user.

Important delta:

- `ChatMemory` is currently the only durable memory record. It does not yet
  cover team, instance, or insight-scoped durable memory. Job, Workflow, Run,
  Epic, and Chat records already exist and should remain native context sources
  unless there is a specific learned fact worth promoting into durable memory.
- There is no provenance/confidence/freshness model beyond the existing
  ownership, publication, and soft-delete fields.
- Workflow agents cannot list/search scoped memory; they can only read a known
  memory ID.
- The chat system prompt currently describes a richer memory API than the
  actual `write_memory` tool supports. The prompt talks about
  `name`/`description` and kinds such as `user`/`project`, but the tool schema
  accepts only `content`, `kind`, `scope`, and `scope_id`, and the real kinds
  are `user_pref`/`project_fact`/`feedback`/`reference`/`decision`. This is the
  first concrete cleanup item because it can confuse chat agents today.

### Existing Tool Selection And Authorization

Current chat tool exposure is implemented in `SyrusChatMcp::Sidecar` through
hardcoded tool arrays:

- essential tools;
- deferred read tools;
- admin tools;
- walkthrough tools;
- coding-mode tools;
- local-mode tools.

`tools_for_session` filters those arrays by the current chat session's user,
feature flags, coding mode, and local mode. This gives a practical registration
filter, but it is not yet a reusable role/capability policy.

Call-time authorization exists for many chat tools through
`SyrusChatMcp::AuthorizationSupport`. It scopes Jobs, Epics, Workflows, and Runs
to the current chat user before returning them. That is the right defense-in-
depth shape, but the checks are still tool-local and user-ownership oriented,
not role/context oriented.

Workflow MCP has a fixed tool list in `SyrusMcp::Sidecar`. Implementation,
summary/test-plan, adversarial-reviewer, repair, rebase/conflict-resolution,
merge-train build, and manual workflow agent calls all receive the same
workflow MCP surface today. Configured graders do not receive MCP tools because
they are not agents; they are deterministic command runners.

Syrus also has one-shot LLM helpers that bypass MCP sidecars entirely:
ingestion classification, PR comment classification, chat title generation,
direct Job title generation, PR copy fallbacks, and video walkthrough analysis.
These should still be modeled as roles because they need memory policy, audit
metadata, and provider invocation policy, but their default tool surface should
be empty.

Important delta:

- There is no `McpToolContext`, `AgentRole`, `McpToolPolicy`, or centralized
  capability registry.
- Admin chat tools are enabled because the user is an admin, not because the
  chat has explicitly entered an admin diagnostic role.
- Mutation tools are not uniformly tagged as mutations.
- Read tools do not share one policy-aware payload/authorization layer.
- Workflow roles are not reflected in tool exposure.
- Helper LLM calls are not represented in the role system even though they can
  consume repository, job, chat, and user context.

### Existing Sidecar Shape

The chat sidecar is already partially unified:

- `bin/syrus-chat-sidecar` supports an essential and deferred tier.
- `bin/syrus-chat-deferred-sidecar` is a compatibility wrapper that delegates
  to `bin/syrus-chat-sidecar` while preserving the deferred server name.

The workflow sidecar remains separate:

- `bin/syrus-mcp-sidecar` handles workflow runs.

Both chat and workflow provider configs intentionally care about server name
stability. Claude-style MCP tool names are prefixed by the configured server
name, and resumed sessions can depend on those names. Any binary consolidation
must preserve logical server names and launcher names until all resume paths are
proven compatible.

Important delta:

- The binary unification work is smaller for chat than for workflow.
- The policy unification work is larger than the binary unification work.
- Compatibility wrappers should remain even if the implementation moves behind
  one executable.

### Existing Insight-Adjacent Infrastructure

Syrus already has infrastructure-job patterns:

- `main_grader` is a repository-scoped infrastructure Job kind.
- main-branch health checks and repair jobs already persist operational signal.
- chat MCP already has useful read tools such as `read_job`, `read_workflow`,
  `read_run_transcript`, `read_chat_messages`, `read_queue`, and search tools.

Important delta:

- There is no `agent_insight` Job kind, trigger kind, workflow, or role.
- There is no `InsightSuggestion` persistence model.
- There is no `submit_insight` MCP tool.
- Evidence selection does not exist as a first-class concept.
- Current transcript/log read tools are chat-current-user scoped; insight jobs
  need explicit repository/user/team/admin scopes without becoming broad admin
  agents.

## Layer 1: Memory System

The memory system is the base layer. It should make useful context durable and
retrievable while keeping scope, freshness, and provenance explicit.

This is an extension of what Syrus already has, but it should not collapse
every scoped object into one generic memory table. Syrus already has good
source-of-truth models for chat messages, bookmarks, attachments, Jobs,
Workflows, Runs, artifacts, summaries, test plans, grader output, failure
classifications, Epics, and repository configuration. Those are context
sources. They should stay in their native models and be exposed through
domain-specific read/search tools.

Durable memory is narrower: learned, reusable knowledge that should survive
past the object that produced it. That includes repository quirks, user
preferences, team conventions, operational runbooks, accepted decisions, and
insight-backed suggestions.

The default implementation path should be to evolve `ChatMemory` into the
broader durable-memory primitive where that remains clean. Add a separate model
only if the required scope/provenance semantics would make `ChatMemory`
ambiguous or backward-incompatible.

### Context And Memory Sources

| Source | Backing store | Purpose | Access path |
| --- | --- | --- | --- |
| Turn context | provider context window | Short-lived reasoning inside one agent turn | No Syrus tool; only the current provider invocation |
| Chat context | `ChatSession`, `ChatMessage`, attachments, bookmarks, queued messages, chat summary | Conversation-local facts and evidence | Chat-scoped tools such as `read_chat_messages`, attachment tools, and prompt injection |
| Job context | `Job`, `Workflow`, `Step`, `Run`, artifacts, transcripts, failure classifications, summaries, test plans | Handoffs, retry state, decisions, failure details | Job/workflow tools such as `read_job`, `read_workflow`, `read_run_transcript`, and `read_live_state` |
| Epic context | `Epic`, child Jobs, dependencies | Epic description, dependency shape, accepted scope, child-job state | Epic/job tools and prompt injection for Jobs in the Epic |
| Repository context | `Repository`, `.syrus.yml`, health checks, known GitHub state | Current repo configuration and operational signal | Repository tools and domain-specific read/search |
| Durable repository memory | `ChatMemory` today, future `Memory` if renamed | Learned setup quirks, flaky tests, architecture notes, preferred commands, known agent mistakes | Generic memory tools, scoped to repository |
| Durable user memory | `ChatMemory` global scope today | Operator preferences, provider choices, review strictness, UI choices | Generic memory tools, scoped to user |
| Durable team memory | future team/installation-scoped memory | Shared repository and process knowledge | Generic memory tools, explicitly shared |
| Durable instance memory | future admin-scoped memory | Operational knowledge, cluster constraints, release practices | Generic memory tools for admin/infrastructure roles |
| Insight suggestions | future `InsightSuggestion` | Evidence-backed recommendations generated by insight jobs | Insight UI/tools; optional promotion into durable memory |

The first five rows are not generic memory records. They are narrow context
sources with existing ownership and lifecycle rules. The generic memory tool
family should operate on the durable-memory rows only.

### Memory Records

Every durable memory record should have enough metadata for an agent or
operator to decide whether to trust it. Domain context records should not be
copied into memory just to make them searchable; memory records should point to
source evidence instead.

- scope type and scope ID;
- source type: chat, job, workflow, run, manual, insight, admin;
- source object ID;
- author: user, system, or agent;
- confidence;
- created_at;
- last_verified_at;
- optional expires_at;
- evidence references;
- visibility: private, repository, team, instance.

Example:

```json
{
  "scope": "repository",
  "repository_id": 12,
  "source": { "type": "run", "id": 46063 },
  "author": "agent",
  "confidence": 0.86,
  "last_verified_at": "2026-07-18T12:00:00Z",
  "body": "The rspec grader can exceed 20 minutes with coverage enabled."
}
```

### Memory Capabilities

Memory access should be expressed as capabilities, separate from MCP tool names
and separate from domain context reads:

- `memory.search`;
- `memory.list`;
- `memory.read`;
- `memory.write.user`;
- `memory.write.repository`;
- `memory.propose.repository`;
- `memory.write.team`;
- `memory.propose.team`;
- `memory.write.instance`;
- `memory.propose.instance`;
- `memory.write.insight`.

Domain context access should use separate capabilities:

- `context.read.chat`;
- `context.search.chat`;
- `context.read.job`;
- `context.search.jobs`;
- `context.read.workflow`;
- `context.read.run`;
- `context.read.epic`;
- `context.read.repository`;
- `context.read.health`;
- `context.read.queue`;
- `context.read.transcripts`.

Most agents should read more than they can write.

Examples:

- implementation agents can read job, epic, run, and repository context, plus
  durable repository/user memory selected for that scope; they should write
  only job artifacts and structured handoff records;
- chat agents can read chat context, read/write durable user memories, and
  propose durable repository memory;
- insight agents can read scoped evidence and write insight suggestions, but
  cannot silently promote a suggestion into durable memory;
- admin infrastructure agents can read instance diagnostics, but mutations
  still need narrow, named capabilities.

### Tool Shape

The generic durable-memory MCP surface should stay small:

- `search_memory(query, scopes?, kinds?, limit?)` - relevance search across
  durable memories allowed by the role.
- `list_memory(scopes?, kinds?, limit?)` - deterministic browsing/debugging
  of durable memories allowed by the role.
- `read_memory(id)` - full record read after policy verifies access.
- `write_memory(scope, scope_id?, kind, content, visibility?, provenance?)` -
  direct writes only for roles that can mutate durable memory.
- `propose_memory(scope, scope_id?, kind, content, evidence_ids?)` - create a
  reviewable proposal instead of directly mutating durable memory.

Do not add `read_job_memory`, `read_epic_memory`, or similar wrappers unless
there is a specific ergonomics or safety reason. Job, Epic, Workflow, Run, and
Chat state should be read through their domain tools.

### Retrieval And Injection

Context and memory should not be dumped wholesale into prompts.

Use three tiers:

1. **Always injected:** current objective, user instruction, repository slug,
   job/workflow/run identity, and critical safety constraints.
2. **Relevant summary:** compact, high-confidence durable memory plus compact
   domain context selected by scope, recency, provenance, and current role.
3. **On-demand reads:** MCP tools that fetch full durable memory records,
   domain objects, evidence, transcripts, and logs when the agent chooses to
   inspect them.

This keeps prompts small while preserving a path to deeper context.

### Freshness

Repository memory should be invalidated or downranked when:

- `.syrus.yml` changes;
- dependency lockfiles change;
- build/test commands change;
- referenced file paths disappear;
- an operator marks it obsolete;
- recent runs contradict it.

Insight jobs can help identify stale memories, but should propose updates
rather than silently rewrite them.

### Safety Rules

- Cross-user memory is forbidden unless explicitly shared through team or
  admin scope.
- Cross-repository memory is opt-in and should be rare.
- Chat context is private to that chat unless exposed through a role-specific
  diagnostic flow. Durable memories created from chat context require an
  explicit write or promotion action.
- Insight jobs may propose memory promotion, but operators approve promotion.
- Memory writes must be structured and auditable.
- Memory is advisory. Current repo state, current tests, and explicit user
  instructions are authoritative.

### Memory Work Plan

1. Fix the current durable-memory prompt/tool mismatch in chat so agents are
   told the real `write_memory` schema and real memory kinds.
2. Inventory existing context sources and durable memory sources:
   `ChatMemory`, chat messages, bookmarks, attachments, summaries, workflow
   artifacts, grader outputs, failure classifications, Epics, health checks,
   and repository notes.
3. Define which sources stay domain context and which become durable memory.
4. Evolve `ChatMemory` into the broader durable-memory abstraction where
   possible:
   additional scopes, provenance metadata, confidence/freshness fields, and
   policy-aware visibility.
5. Add a new model only if `ChatMemory` cannot carry a required scope or
   provenance rule cleanly without muddying existing behavior.
6. Add `MemoryPolicy`, durable memory capability names, and separate domain
   context capability names.
7. Build retrieval that returns compact summaries plus evidence IDs.
8. Extend workflow MCP from read-by-ID memory access to scoped read/search
   access where the role allows it.
9. Add domain search tools only where native context stores need search, such
   as transcripts, job history, or chat history.
10. Add proposal flow for repository/team memory promotion.
11. Add freshness/downranking rules for durable memory.
12. Add regression specs for cross-user, cross-repo, and stale-memory behavior.

## Layer 2: Agent Roles And Tool Capability Policy

Agent roles are the policy layer. A role answers:

- What is this agent trying to do?
- Which objects are in scope?
- Which memory scopes can it read or write?
- Which MCP tools can it see?
- Which MCP tools can mutate state?
- Which user permission profile applies?

This should replace sidecar-specific allowlists as the primary decision point.
Sidecars can still differ operationally, but they should ask the same role and
policy objects what to expose.

### Sidecar And Tool Name Stability

The target can be one unified MCP sidecar binary, but the MCP server name is
part of the agent-facing tool contract. Claude-style MCP clients prefix tool
names with the configured server name to avoid collisions, so moving a tool
from one sidecar/server name to another can silently change the tool name the
agent sees.

That means unifying the binary must not imply casually renaming the MCP server
entries. The safer migration shape is:

```bash
bin/syrus-mcp-sidecar --surface workflow --run-id 123
bin/syrus-mcp-sidecar --surface chat --chat-session-id 87
bin/syrus-mcp-sidecar --surface chat --profile deferred-read --chat-session-id 87
```

but provider MCP configs may still use stable logical server names such as:

- `syrus-mcp-sidecar`;
- `syrus-chat-sidecar`;
- `syrus-chat-deferred-sidecar`.

Compatibility wrappers can preserve those names while delegating to the unified
binary. Only after all prompts, provider configs, tests, and persisted session
resume paths no longer depend on the old server names should the wrappers or
logical names be removed.

Rules:

- treat MCP server names as public API;
- preserve tool names across binary consolidation;
- add compatibility aliases before moving tools between logical servers;
- test resumed sessions, not only fresh sessions, before removing aliases;
- audit prompt text for explicit tool-name references.

### Role Context

The role context should be explicit and serializable:

```ruby
{
  surface: "workflow",
  role: "implementation",
  user: user,
  repository: repository,
  epic: epic,
  job: job,
  workflow: workflow,
  run: run,
  allowed_job_ids: [...],
  allowed_workflow_ids: [...],
  allowed_run_ids: [...],
  allowed_chat_session_ids: [...],
  allowed_context_sources: [...],
  allowed_memory_scopes: [...]
}
```

The sidecar should derive tools from this context:

```ruby
context = McpToolContext.from_run(run)
tools = McpToolPolicy.for(context).allowed_tools
```

### Roles

The codebase has three different role-like systems today:

- chat roles/modes are inferred from `SyrusChatMcp::Sidecar` tool groups,
  feature flags, `chat_session.coding?`, `chat_session.mode`, and admin status;
- workflow roles are inferred from `Step::Kind.agentic_values` and a few
  per-step `required_mcp_tools`;
- helper roles are implicit one-shot LLM calls that classify, name, summarize,
  or analyze existing inputs without entering a full sidecar-backed agent
  session.

There is no grader agent. `grade`, `grader`, `grader_fanout`, and
`grader_collect` are registered with `agentic: false` and run configured
commands.

#### Chat Planner

Purpose: explore, plan, inspect repositories, and propose work.

Allowed:

- inspect attached repositories;
- read/search the current user's jobs, epics, workflows, and runs within
  allowed repository scope;
- read current chat history and bookmarked messages;
- create job/epic proposals;
- attach repositories/documents;
- read/write durable user memory visible in that chat context;
- propose durable repository memory.

Not allowed:

- arbitrary admin mutations;
- unrelated users' jobs or chats;
- direct workflow retry/cancel/approve unless exposed as an explicit
  user-facing action.

#### Chat Admin

Purpose: operator diagnostics from chat. This is currently an overlay applied
when `chat_session.user.admin?`, not an intent-specific chat mode.

Allowed:

- all chat planner reads;
- admin read tools;
- queue/system inspection;
- instance-level metrics and diagnostics.

Mutations remain narrow and named. Admin status should not mean "all tools,
all the time."

#### Chat Coding Mode

Purpose: implement code directly in a persistent chat checkout, then hand
control back to Syrus automation.

Allowed:

- local coding checkout reads and writes;
- shell commands in the coding checkout;
- completion handoff through `complete_implement_step`;
- coding-change submission through `submit_coding_changes`;
- current chat context plus durable memory already visible to that chat.

Not allowed:

- proposing automated Jobs instead of editing directly;
- writing outside the coding checkout;
- unrelated admin mutations.

#### Chat Local Mode

Purpose: let the chat agent operate through the local daemon when the operator
has explicitly put the session in local mode.

Allowed:

- local file reads, writes, listings, command execution, git status, and git
  diff through the daemon tunnel;
- creating a coding Job from the local context.

Not allowed:

- using local daemon tools from normal planning chats;
- daemon access when the feature is disabled or the daemon is disconnected.

#### Chat Walkthrough Analysis

Purpose: inspect uploaded video walkthrough frames when the walkthrough feature
is enabled.

Allowed:

- walkthrough analysis reads for the current chat/session scope.

Not allowed:

- arbitrary file or repository mutation;
- use when the feature flag is off.

#### Helper Roles

Purpose: short, one-shot model calls that transform existing evidence into a
classification, title, summary, or structured analysis.

Helper roles should be first-class `AgentRole`s, but they should receive no MCP
tools by default. The caller prepares the input and the helper returns a
bounded result. Any memory context must be selected by the caller through
`MemoryPolicy`; helpers should not be allowed to search broadly or pull
additional evidence themselves.

Current helper roles:

- **Issue ingestion helper** — `IngestionClassifier` with
  `Prompts::IngestionClassifier`. It classifies newly ingested GitHub issues.
  It may receive durable repository and team memory about triage conventions,
  Epic markers, ownership, and known duplicate patterns when the
  repository/user is already in scope.
- **PR comment classification helper** — `PrCommentClassifier` with
  `Prompts::CommentClassifier`. It classifies PR comments as feedback,
  approval, noise, or other workflow-relevant signals. It may receive compact
  job context, durable repository memory, and prior workflow summary context
  only for the PR being classified.
- **Chat title helper** — `ChatTitleGenerator` with `Prompts::ChatTitle`. It
  creates a display title from the first chat message and optional repository.
  It should usually receive no durable memory; the chat text itself is enough.
- **Direct Job title helper** — `DirectJobTitleGenerator` with
  `Prompts::DirectJobTitle`. It creates a concise Job title from an operator
  prompt. It may receive compact repository/Epic naming conventions when the
  direct Job is scoped to a repository or Epic.
- **PR copy helper** — `PrSummarizer` with `Prompts::PullRequestSummary` and
  the `Prompts::SummarizeFallback` path in `Steps::Summarize`. It synthesizes
  PR title/body/summary from the current Job, diff, and workflow artifacts when
  the normal `submit_summary` handoff is missing or unavailable. It may receive
  current job context, Epic context, and durable repository memory in read-only
  form.
- **Video walkthrough helpers** — `VideoWalkthroughAnalysisJob` with
  `Prompts::VideoWalkthroughAnalysis` and
  `SyrusChatMcp::AnalyzeWalkthroughSegmentTool` with
  `Prompts::VideoWalkthroughSegment`. They analyze video/frame evidence inside
  a chat. They may receive current chat context and durable repository memory
  already visible to that chat.

Not allowed:

- MCP tools;
- direct job, chat, repository, queue, or GitHub mutation;
- unrelated transcript or memory reads;
- broad admin context unless the caller is an explicit admin diagnostic flow.

#### Workflow Code Change Agent

Purpose: implement the current job.

Allowed:

- current job/workflow/run state;
- current repository workspace;
- dependency and epic context for the current job;
- read-only durable memory relevant to the current job/repository/user;
- submit summary;
- submit test plan;
- implementation tools provided by the agent provider.

Not allowed:

- unrelated chats;
- unrelated jobs;
- admin tools;
- mutation of other jobs or epics.

This role currently covers `implement`, `respond`, `analyze_and_fix`, and
`landing_fix` steps.

#### Workflow Rebase And Conflict Agent

Purpose: resolve conflicts that deterministic git operations could not resolve.

Allowed:

- current job/workflow/run state;
- current repository workspace;
- current PR branch, base branch, and conflict state;
- dependency graph relevant to the PR stack or Epic train;
- implementation tools provided by the agent provider.

Not allowed:

- unrelated job mutation;
- unrelated chat history;
- unrelated repositories;
- broad GitHub mutation outside the scoped branch/PR.

This role currently covers `agent_rebase`, `stack_agent_rebase`,
`push_agent_rebase`, and the agentic conflict-resolution path inside
`merge_train_build`.

#### Workflow Summary And Test-Plan Agent

Purpose: convert the completed workflow into reviewer-facing PR copy and a
test plan.

Allowed:

- current job/workflow/run state;
- current workflow artifacts and diff;
- `submit_summary` for summary steps;
- `submit_test_plan` for test-plan steps.

Not allowed:

- code changes;
- job approval/cancellation/retry;
- memory writes;
- unrelated workflow transcripts.

#### Workflow Adversarial Reviewer

Purpose: inspect the implementation from a skeptical reviewer perspective and
produce structured approval or concern feedback for the current workflow loop.

This is not the same as a grader. Graders answer "did configured checks pass?"
The adversarial reviewer answers "does this change actually satisfy the task,
avoid obvious regressions, and deserve another implementation pass?"

Allowed:

- current job/workflow/run state;
- current repository workspace;
- implementation diff for the current workflow;
- summaries, test plans, grader outputs, and failure details for the current
  workflow;
- relevant job/Epic context and durable repository memory in read-only form;
- `submit_adversarial_review`;
- `report_main_concern` where the role is being used for main-branch repair or
  health review.

Not allowed:

- code changes;
- PR mutation;
- job approval/cancellation/retry;
- memory writes;
- unrelated chats, jobs, workflows, or run transcripts.

#### Workflow Manual Agent

Purpose: run an operator-supplied manual workflow prompt when a manual/resume
path is used.

Allowed:

- current job/workflow/run state;
- current repository workspace;
- the operator-supplied prompt.

Not allowed:

- implicit admin access;
- unrelated jobs/chats/repos unless the prompt has explicitly scoped them and
  policy permits it.

#### Infrastructure Main Repair

Purpose: fix a broken main branch when the repository policy allows automatic
repair jobs.

Allowed:

- repository checkout at the broken SHA;
- attachments containing CI and grader logs;
- current main branch health records;
- implementation tools;
- normal summary/test-plan handoff.

Not allowed:

- starting from a stale broken SHA;
- ignoring newer green health;
- mutating unrelated jobs.

#### Infrastructure Agent Insight

Purpose: inspect transcripts and logs for repeated agent struggles and propose
improvements.

Allowed:

- assigned repository checkout;
- scoped transcripts/logs/jobs/chats;
- repo metadata;
- queue/run diagnostics relevant to the insight window;
- read-only memory relevant to the repository and user/team;
- `submit_insight`.

Not allowed:

- arbitrary cross-repo transcript reads;
- job mutation;
- GitHub mutation;
- broad admin mutation;
- user-private memories unless explicitly in scope.

This role does not exist yet. It is the proposed role for the insight-job
system.

### Non-Agent Execution Contexts

These are important execution contexts, but they should not be modeled as
agent roles:

- **Configured graders** — `grade`, `grader`, `grader_fanout`, and
  `grader_collect` are deterministic command execution and aggregation steps.
  They write run/workflow artifacts and health signals, but they do not invoke
  `run_agent`.
- **Infrastructure main grader** — `Job#kind == "main_grader"` and
  `Workflows::MainGrader` run `prepare → grader_fanout → grader_collect`
  against the default branch SHA. This is a repository-scoped infrastructure
  job that produces health signal, not an agent.
- **Deterministic workflow plumbing** — `prepare`, `pr_open`, `push`,
  `push_after_rebase`, `auto_rebase`, `force_push`, `stack_auto_rebase`,
  `stack_force_push`, `mergeability_preflight`, `apply_suggestions`,
  `auto_merge`, `merge_train_assemble`, `merge_train_land`,
  `merge_train_rebase`, `merge_train_land_after_rebase`, `coverage_analyze`,
  and `coverage_pr_comment` are service steps. They need authorization and
  audit boundaries, but not MCP agent-tool roles.

### Capability Matrix

| Role | Read context | Read durable memory | Write durable memory | Read transcripts | Create proposals | Mutate jobs | Mutate GitHub |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Chat planner | chat, attached repos, current-user jobs | user, attached repo | user; propose repo | scoped current user | yes | no | no |
| Chat admin | chat, repo, queue, instance diagnostics | user, repo, instance | user; propose repo/instance | admin scoped | yes | explicit only | explicit only |
| Chat coding mode | chat, attached checkout, coding job | user, attached repo | user; job handoff artifacts | attached coding context | no | attached coding job only | branch push through handoff |
| Chat local mode | chat, local checkout | user, attached repo | user/local artifacts | scoped current user | optional coding job | local-session scoped | no |
| Chat walkthrough | chat, walkthrough frames | chat-visible durable memory | no | current walkthrough only | no | no | no |
| Workflow code change | job, workflow, run, epic, repo workspace | repo, user-selected | no | current job only | no | current workflow only | branch/PR through workflow steps |
| Workflow rebase/conflict | job, workflow, run, stack/epic, repo workspace | repo, user-selected | no | current branch/stack only | no | current workflow only | scoped branch push |
| Summary/test plan | job, workflow, run, diff, artifacts | repo, user-selected | no | current workflow only | no | current workflow only | no |
| Adversarial reviewer | job, workflow, run, diff, grader output | repo, user-selected | no | current workflow only | no | no | no |
| Helper roles | caller-scoped input only | caller-selected optional | no | caller-provided evidence only | no | no | no |
| Main repair | repo, health evidence, job context | repo, instance-selected | no | attached evidence | no | current job only | branch/PR through workflow |
| Agent insight | repo, scoped jobs/chats/runs | repo, scoped user/team | insight suggestions only | scoped evidence IDs | suggested prompts only | no | no |

### Shared Read Tools To Reuse

The chat side already has useful read tools. Their payload builders should be
shared, but authorization should be enforced by role context.

Candidates:

- `read_job`;
- `list_job_workflows`;
- `read_workflow`;
- `read_run_transcript`;
- `get_job_diff`;
- `search_jobs`;
- `list_jobs`;
- `read_chat_messages`;
- `search_chats`;
- `list_chats`;
- `repo_info`;
- `read_pr`;
- `list_open_prs`;
- `list_open_issues`;
- `read_queue`;
- `get_spending`;
- `search_syrus_docs`.

### Mutation Tools

Mutation tools should be separately tagged and should require explicit role
capabilities:

- approve/cancel/retry/rebase/update job;
- create proposal/job/epic;
- mutate dependencies;
- pause/resume queues;
- admin mutations;
- GitHub write operations;
- local shell/write tools outside the assigned workspace.

Insight jobs should not receive these. They should write only structured
insight records.

### Defense In Depth

Filtering tools at registration time is not enough. Every tool must validate
requested IDs against the current context.

Bad:

```ruby
register_tool(ReadRunTranscriptTool) if role.agent_insight?
```

Good:

```ruby
register_tool(ReadRunTranscriptTool)
ReadRunTranscriptTool.call(run_id:) # rejects unless run_id is in scope
```

This matters for tools like `read_run_transcript`, where arbitrary IDs could
otherwise leak unrelated user or repository history.

### Role Work Plan

1. Add `McpToolContext` with constructors for chat sessions, workflow runs,
   and future infrastructure/insight jobs.
2. Add `AgentRole` definitions with stable role names.
3. Add `McpToolPolicy.for(context)` and map today's chat sidecar arrays onto
   it without changing exposed tools.
4. Move chat sidecar allowlists into the policy.
5. Map the current fixed workflow MCP tool list onto workflow roles without
   changing behavior.
6. Add helper role definitions for one-shot LLM calls and classify current
   helpers with `allowed_tools: []`.
7. Tag tools with capabilities, scope requirements, and mutation level.
8. Extract shared read payload builders from chat tools.
9. Move call-time authorization from ad hoc current-user lookups toward
   context-scoped allowed IDs, while keeping existing ownership protections.
10. Add negative tests for unrelated job/run/chat/repository IDs.
11. Add helper memory-policy specs: title helpers get no durable memory by
    default; classifier, PR-copy, direct-title, and walkthrough helpers get
    only caller-scoped compact memory.
12. Add admin vs non-admin role specs, including "admin user, non-admin chat
    intent" behavior.
13. Add a unified sidecar binary behind compatibility wrappers that preserve
    existing MCP logical server names.
14. Add fresh-session and resumed-session tests proving tool names remain
    available during migration.

## Layer 3: Insight Jobs

Insight jobs are an application of memory and roles. They should be normal
Syrus infrastructure jobs that inspect evidence, find patterns, and produce
suggestions.

They are intentionally not general admin agents. They do not mutate queues,
retry jobs, edit repository memory directly, or open PRs. Their output is a
structured set of suggestions that an operator can review.

### Job Shape

`main_grader` is the closest existing pattern:

- represented as a normal `Job`;
- infrastructure-flavored;
- repository-scoped;
- produces signal instead of commits;
- does not open PRs;
- auto-closes when complete;
- has queue/concurrency rules separate from normal implementation work.

`agent_insight` should follow that shape.

### Inputs

An insight job should receive:

- repository;
- time window;
- sampled job IDs;
- sampled workflow IDs;
- sampled run IDs;
- sampled chat session IDs;
- recent failure classifications;
- relevant performance logs;
- queue/run diagnostics;
- memory summaries;
- repository checkout.

The important part is that these inputs are selected by Syrus before the agent
runs. The agent can inspect deeper evidence through scoped MCP tools, but it
cannot ask for arbitrary unrelated transcripts.

### Outputs

Insight jobs should write structured suggestions:

```json
{
  "title": "RSpec timeouts are repeatedly treated as broken main",
  "category": "grader_timeout_policy",
  "severity": "high",
  "repository_id": 12,
  "evidence": [
    { "run_id": 46063, "kind": "transcript" },
    { "job_id": 1642, "kind": "failure" }
  ],
  "suggested_prompt": "Update .syrus.yml so the rspec grader timeout is 40 minutes...",
  "memory_suggestion": "Coverage-enabled rspec can exceed 20 minutes in this repository.",
  "confidence": 0.82
}
```

If the repository is `tkadauke/syrus`, the suggested prompt may target Syrus
itself. If the repository is `tkadauke/raytracer`, the suggestion should
usually target that repository's `.syrus.yml`, docs, tests, or setup
configuration.

### Operator Workflow

The first UI should be review-first:

1. Operator opens an insight suggestion list by repository.
2. Each suggestion shows title, severity, confidence, and evidence links.
3. The proposed prompt is collapsed by default.
4. Expanding shows the full suggested job prompt.
5. Accepting creates a normal Syrus job or epic proposal.
6. Dismissing records feedback.
7. Promoting memory creates or updates repository memory with provenance.

Editing suggested prompts can come later. The first version can accept or
dismiss.

### Scheduling

Insight jobs can be triggered three ways:

- manually from a repository/admin page;
- after repeated similar failures;
- on a low-frequency schedule.

The initial implementation should be manual or admin-triggered. Automatic
scheduling should wait until the suggestion quality is good enough.

### Insight Work Plan

1. Add an `agent_insight` Job kind and trigger kind modeled after
   `main_grader`: infrastructure-flavored, repository-scoped, no commits, no
   PR, auto-close on success.
2. Add an `agent_insight` role with read-only scoped evidence tools and
   `submit_insight`.
3. Extract or reuse payload builders behind `read_job`, `read_workflow`,
   `read_run_transcript`, `read_chat_messages`, and queue/search tools.
4. Add evidence selection: repository, time window, object IDs, and caps.
5. Add `InsightSuggestion` persistence.
6. Add `submit_insight` validation and audit logs.
7. Add repository/admin UI for suggestions.
8. Add accept/dismiss actions.
9. Add "create job from suggestion."
10. Add optional memory promotion.
11. Add automatic triggers only after manual flow is useful.

## Rollout Sequence

### Phase 1: Make Memory Explicit

- Inventory existing context sources and durable memories.
- Mark each source as either native context, durable memory, or insight
  suggestion.
- Add durable memory scopes and provenance.
- Add read-only scoped durable memory retrieval.
- Keep domain context reads on domain tools.
- Update prompts to inject compact context plus compact memory summaries.

### Phase 2: Introduce Roles Without Behavior Changes

- Add `McpToolContext`, `AgentRole`, and `McpToolPolicy`.
- Map existing chat/workflow/admin behavior onto roles.
- Keep existing tools working.
- Add tests that assert current tools are still available where expected.

### Phase 3: Enforce Scope

- Move shared read tools behind role-aware authorization.
- Add negative tests for unrelated IDs.
- Make mutation tools require explicit capabilities.
- Log denied tool calls with role/context metadata.

### Phase 4: Build Insight Jobs

- Add `agent_insight` infrastructure workflow.
- Add scoped evidence tools.
- Add `submit_insight`.
- Persist suggestions.

### Phase 5: Close The Loop

- Add operator UI for suggestions.
- Create jobs from accepted suggestions.
- Promote accepted suggestions into repository memory.
- Add feedback data for insight quality.

## Open Questions

- Should repository memory be editable directly by operators, or only through
  accepted suggestions?
- Should insight jobs run manually first, or should we immediately trigger them
  after repeated failures?
- What is the default evidence cap for insight jobs?
- Do admin insight jobs ever get instance-wide transcript access, or should
  they still be repository-scoped by default?
- Should memory promotion require admin permission, repository ownership, or
  either?
- How aggressively should stale memory be hidden vs merely downranked?
- Should roles be stored in code only, or should some role settings become
  admin-configurable later?

## Success Criteria

- A reader can understand memory, roles, and insights as separate layers.
- Every MCP tool is granted by role and independently validates scope.
- Agents get useful memory without prompt bloat.
- Insight jobs can inspect relevant evidence without cross-user or cross-repo
  leakage.
- Operators can turn repeated agent struggles into concrete jobs or memory
  updates.
