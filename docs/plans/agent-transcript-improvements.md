# Agent transcript improvement plan

Captured June 4, 2026 from production admin API data.

## Goal

Make Syrus better at noticing where agents struggle, then remove the
highest-friction points in the agent environment. This plan is about
the agent-facing loop, not general UI polish.

The target outcome is that an operator can answer these questions from
Syrus itself:

- What failed in the last 24 hours?
- Was it an agent reasoning/tool-use failure, a grader/environment
  failure, a GitHub/platform failure, or a Syrus orchestration bug?
- What exact artifact should the next agent turn read?
- Which prompt/tool/environment change would have prevented the repeat?

## Evidence Collected

Sources used:

- `GET /api/v1/admin/runs?state=failed&since=2026-06-03T00:00:00Z`
- `GET /api/v1/admin/workflows/:id`
- `GET /api/v1/admin/runs/:id/artifacts`
- `GET /api/v1/admin/runs/:id/transcript`
- `GET /api/v1/admin/chats`
- `GET /api/v1/admin/chats/:id`

Recent failed-run sample, first 100 rows returned by the admin API:

| Category | Count |
|---|---:|
| `grader` | 64 |
| `grader_collect` | 27 |
| `auto_merge` | 3 |
| `stack_agent_rebase` | 3 |
| `agent_rebase` | 2 |
| `summarize_amend` | 1 |

Top repeated failure messages:

| Failure | Count |
|---|---:|
| `grader rspec failed (exit 1)` | 25 |
| `grader eager-load failed (exit 1)` | 19 |
| `required graders failed: eager-load, rspec, react-tests` | 13 |
| `grader react-tests failed (exit 127)` | 10 |
| Git fetch refused into checked-out branch for JOB-709 stack rebase | 3 |
| `worker_died` | 3 |
| GitHub merge 405: `This branch can't be rebased` | 2 |

Representative workflow observations:

- Workflow `5700` for JOB-702 shows `RetryUntil` behavior working:
  an initial `rspec` grader failed, `landing_fix` ran, graders passed,
  and the workflow reached push/auto-merge. The raw step list still
  reads like an unrolled sequence of anonymous `grader` steps rather
  than a compact loop with named graders and per-iteration summaries.
- Workflow `5677` for JOB-753 shows an agentic `respond` step followed
  by a failed grader, a second `respond`, successful graders, then a
  failed `summarize_amend` run. The failure message starts with a raw
  `git commit --amend -m ...` invocation, which is a system/tooling
  failure after the agent had already returned success.
- Workflows `5686` and `5680` show `agent_rebase` runs ending as
  `worker_died`. The admin API marks the run outcome, but the transcript
  endpoint has no parsed transcript for those runs.
- Runs `15383`, `15403`, `15610`, `15800`, `16155`, and similar grader
  failures expose only three artifact log lines: run start, command
  start, and generic `grader failed`. The actual stdout/stderr needed
  to fix the failure is not available through the admin artifact API.
- Recent agentic run transcript endpoints often return empty summaries:
  `total_tool_calls: 0`, no events, and no model/session metadata, even
  for successful agentic runs such as `15398`, `15407`, `15416`,
  `15802`, `16031`, `16054`, and `16172`.

Representative chat observations:

- Chat `5` had 200 returned messages: 90 tool uses, 91 tool results.
  Tools included `Bash` 27 times, `Read` 37 times, `Glob` 8 times,
  `Grep` 13 times, plus proposal/bookmark MCP tools. Several discovery
  calls returned `No files found`, and one Rails execution in a chat
  workspace failed because gems were not installed.
- Chat `6` had 200 returned messages: 85 tool uses, 88 tool results.
  It includes an explicit tool-shape error:
  `InputValidationError: Read failed ... unexpected parameter command`.
- Chat `6` also includes an MCP proposal error:
  `Error: epic_id was not found in tkadauke/gymassistant`. The error is
  true, but not actionable enough for the agent to know whether it used
  the wrong repository, wrong proposal id, stale context, or a missing
  lookup endpoint.
- Chat `2` used whiteboard tools heavily: 1 clear, 8 text draws,
  23 shape draws, and 26 arrow draws. This is a useful workload, but it
  shows the agent has to perform many low-level operations instead of
  submitting a higher-level scene batch with validation feedback.

## Diagnosis

There are four different problems mixed together today.

### 1. We cannot reliably mine agent transcripts yet

The admin API has transcript endpoints, but many production agent runs
return empty parsed transcripts. When transcripts are missing, we cannot
distinguish:

- the agent used a tool incorrectly,
- the agent never saw the right context,
- the provider failed before producing events,
- Syrus failed after the agent returned success,
- or the transcript parser cannot understand that provider's format.

This is the highest-leverage prerequisite.

### 2. Grader failures dominate, but grader evidence is not available

Most recent failures are graders or grader collection. The agent needs
the full grader output to fix these. Today the operator sees
`grader rspec failed (exit 1)`, while the useful content appears to be
stored elsewhere or pruned before the admin API can return it.

This makes RetryUntil less efficient: the next agent turn may know that
`rspec` failed, but not which spec, assertion, missing command, or stack
trace caused the failure.

### 3. Tool contracts need stronger affordances

Observed examples:

- `Read` was invoked with a `command` parameter.
- Proposal tools returned opaque `epic_id was not found` errors.
- Whiteboard work required many low-level calls and has previously hit
  unsupported element-type errors.

The fix is not only prompt text. Tools should return repair hints,
schemas, and lookup options when a call is malformed.

### 4. The agent runtime needs an environment snapshot

Agents in chats and runs repeatedly inspect filesystem layout,
workspace paths, Rails dependencies, package scripts, and git state by
hand. When the environment is unprepared, the agent discovers it through
a failed command after spending turns searching.

Syrus already knows much of this:

- repository slug and workspace path,
- current branch and base branch,
- whether prepare ran and what it installed,
- `.syrus.yml` commands and graders,
- provider/model,
- PR number and mergeability,
- active workflow/step/iteration.

We should expose that directly to the agent and the operator.

## Plan

### M1 - Make transcript capture complete

1. Normalize transcript ingestion across Claude, Codex, and chat runs.
   Every agentic `Run` should expose:
   - provider and model,
   - session id,
   - cwd,
   - available tools at init,
   - tool-call counts,
   - tool-call failures,
   - exit reason,
   - provider stderr or transport error,
   - total turns and cost when available.

2. Add a regression spec that creates representative Claude, Codex, and
   chat transcript payloads and verifies `Admin::Transcripts::Payload`
   emits non-empty summaries and events.

3. Add an admin API endpoint or filter that lists "agentic runs with no
   parsed transcript" so gaps are visible after deploy.

4. Preserve raw transcript pointers separately from parsed transcript
   status. If the workspace has been pruned, the API should say:
   - raw transcript unavailable,
   - reason,
   - pruned at,
   - retention policy,
   - related run/workflow/job ids.

Acceptance:

- Recent successful agentic runs no longer report empty transcript
  summaries unless no raw transcript exists.
- Empty transcript responses include a concrete reason.

### M2 - Store and expose complete grader logs

1. Capture grader stdout/stderr as first-class run artifacts, not only
   high-level `JobLog` rows.

2. Add `GET /api/v1/admin/runs/:id/grader_log` or extend artifacts with:
   - command,
   - exit status,
   - duration,
   - stdout tail,
   - stderr tail,
   - full log download path if large,
   - parsed failure summary when possible.

3. Feed the failed grader summary into the next RetryUntil agent prompt.
   The agent should see the exact failing command and relevant output
   before it edits files.

4. In workflow UI/admin serializers, show grader display names
   (`rspec`, `react-tests`, `eager-load`, `build-test`) instead of
   generic `grader`.

Acceptance:

- A failed `rspec` grader can be diagnosed from the admin API without
  shelling into production.
- The first agent turn after a grader failure receives the failure log.

### M3 - Add an agent trouble report

Add a production-safe report endpoint:

`GET /api/v1/admin/agent_trouble_report?since=...`

The report should aggregate:

- failed runs by step kind, trigger kind, repo, and provider,
- top normalized error messages,
- agentic runs with missing transcripts,
- tool-call failure counts by tool name,
- chat MCP tool errors,
- whiteboard tool errors by error type,
- grader failures by grader name and exit code,
- worker deaths and subprocess kill/timeout reasons,
- repeated failures on the same job/workflow.

This should be available both as JSON and as a compact text block that
can be pasted into a planning chat.

Acceptance:

- The report can reproduce the June 4 findings above without ad hoc
  shell/jq work.
- The endpoint has request specs covering serializer resilience on bad
  rows.

### M4 - Improve tool contracts and recovery hints

1. Add schema-aware error responses to chat MCP tools:
   - wrong parameter name,
   - missing foreign key,
   - stale proposal id,
   - unsupported whiteboard element,
   - invalid repository scope.

2. Make FK lookup tools return next-step options. Example:
   `epic_id was not found` should return candidate epics/proposals in
   the active repo and say whether the id was a database id, proposal
   id, slug, or bookmark id.

3. Give whiteboard tools a `describe_capabilities` response in the chat
   system prompt and MCP server metadata:
   - supported element kinds,
   - required fields,
   - common aliases,
   - max batch size,
   - examples for shapes, arrows, images, text, grouping, and scene
     updates.

4. Add a higher-level whiteboard batch tool for common diagrams. It
   should validate the whole scene before mutating, and return a list of
   invalid elements with repair hints.

Acceptance:

- The `Read`-with-`command` shape error class has a regression test at
  the tool adapter boundary.
- Proposal FK errors include actionable candidates.
- Whiteboard unsupported-element errors include supported alternatives.

### M5 - Provide an environment snapshot to every agent turn

Create a compact `AgentEnvironmentSnapshot` service used by job runs and
chat turns. Include:

- repo slug, workspace path, and current cwd,
- provider/model,
- workflow id, step kind, trigger kind, and loop iteration,
- branch name, base branch, PR number, mergeability, and remote SHA
  when known,
- prepare status and command results,
- available graders and exact commands,
- package scripts and common test commands,
- whether dependencies are installed,
- whether git fetch/pull is allowed and recommended,
- relevant admin API links for the job/workflow/run.

Use it in:

- `Prompts::Implement`,
- `Prompts::PrFeedback`,
- `Prompts::Rebase`,
- `Prompts::DirectJob`,
- chat system prompt/context.

Acceptance:

- Agents stop rediscovering `.syrus.yml`, package scripts, and workspace
  branch state through multiple shell calls.
- Chat and workflow prompts explicitly say that the agent may `git fetch`
  or `git pull` when current repository state matters.

### M6 - Separate platform failures from agent failures

Classify failures before they reach the agent:

- GitHub API merge/rebase limitations,
- local git worktree corruption or checked-out-branch conflicts,
- worker death or pod restart,
- missing dependencies,
- command not found,
- provider auth/model errors,
- actual test failures,
- agent tool misuse.

Use the classification in:

- workflow state details,
- landing queue blockers,
- RetryUntil prompts,
- admin trouble report,
- operator notifications.

Acceptance:

- A GitHub 405 `This branch can't be rebased` is classified as a
  platform/merge-path problem, not as an agent failure.
- A `worker_died` run links to subprocess/pod/version evidence.
- `react-tests failed (exit 127)` is identified as command/environment
  failure until stdout/stderr proves otherwise.

### M7 - Add evals for recurring struggle patterns

Create a small regression corpus from real production cases:

- missing grader output after `rspec` failure,
- malformed `Read` call,
- stale or wrong `epic_id` in proposal tools,
- whiteboard unsupported element type,
- GitHub merge 405 requiring rebase workflow,
- git fetch refused into checked-out branch,
- worker death during `agent_rebase`.

Each case should have:

- fixture input,
- expected classification,
- expected prompt/tool recovery hint,
- expected admin API summary.

Acceptance:

- `bin/rspec` covers backend classification and serializers.
- `bin/test-react` covers UI rendering for compact loop/iteration and
  missing-log states where relevant.

## Build Order

1. M1 transcript completeness and missing-transcript reporting.
2. M2 grader log capture and prompt injection.
3. M3 trouble report endpoint.
4. M4 tool-contract repair hints.
5. M5 environment snapshot prompt block.
6. M6 failure classification.
7. M7 eval corpus.

M1 and M2 should be first because they turn future debugging from
forensics into normal product behavior. M4 and M5 reduce the agent's
tool mistakes and redundant exploration. M6 and M7 make the system
harder to regress.

## Non-goals

- Do not replace the admin API with kubectl or Rails runner workflows.
  Those remain emergency fallbacks.
- Do not hide raw logs from admins. Summaries are useful, but raw
  evidence must stay accessible.
- Do not make agents responsible for fixing platform failures that
  Syrus can classify and route deterministically.
