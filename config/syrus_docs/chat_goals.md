# Chat goals

Chat goals are chat-scoped continuation loops. A non-terminal `ChatGoal`
records the operator's objective, optional completion condition, mode snapshot,
approval/submission policy, loop iteration count, and durable safeguards for
repeated no-op or blocked iterations.

## Slash commands

`/goal <objective>` starts or replaces the active goal objective for the chat.
`/goal edit <objective>` edits the active goal. `/goal pause`, `/goal resume`,
and `/goal stop` call the same backend goal lifecycle used by the app API, not a
prompt sent to the model. Starting a new goal, or resuming a paused goal through
the start/upsert path, records a `goal_started` event and queues a continuation
turn when the chat is idle. `resume` records a goal control event and queues a
continuation turn when the chat is idle. Editing an already-active goal does not
queue another continuation.

The backend also intercepts raw `/goal ...` messages in
`Api::V1::App::ChatsController#message`, so API callers that bypass the React
composer still get first-class goal command behavior.

## Continuation loop

Goal wakeups use `ChatScopedEvent.record!` for dedupe and provenance and
`ChatQueuedMessagePromoter.deliver_one_if_idle!` for dispatch. This keeps
`stop_requested_at`, `turn_in_flight?`, and `agent_busy?` as the shared
concurrency gate; goal code does not start a second chat turn when another one
is in flight.

Goal events are published for goal start/resume boundaries, goal-linked proposal
confirmation, goal-linked Job implementation/approval/close boundaries, and
goal-linked Epic completion or blocked archival. The queued continuation prompt
for a goal start tells the agent to begin work immediately under the active
goal; later boundary prompts tell it to continue after the linked work event.
Each prompt includes the active goal,
completion condition, mode snapshot, policy fields, iteration number, recent
provenance-linked proposals/Jobs/Epics, and the triggering scoped event.

## Agent tools

Chat agents get two goal-evaluation tools:

- `mark_goal_completed(reason, details?)` marks the active goal `completed`.
- `mark_goal_blocked(reason, details?)` marks the active goal `blocked`.

Agents cannot pause, resume, stop, or cancel goals through MCP. Those state
changes remain operator/API actions unless a later explicit auto policy adds a
separate trusted path.

## Safeguards

`ChatGoalIterationAuditor` records no-op goal continuation turns when a
continuation finishes without creating or updating provenance-linked goal work.
After `ChatGoal::MAX_CONSECUTIVE_NO_OP_ITERATIONS`, the goal is marked blocked
and a system audit message is written to the chat. Repeated blocked wake events
are similarly counted by signature and block the goal after
`ChatGoal::MAX_CONSECUTIVE_BLOCKED_EVENTS`.
