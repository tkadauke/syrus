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

The backend also intercepts raw `/goal ...` messages, so UI and API callers
get the same first-class goal command behavior.

## Continuation loop

Goal wakeups are deduplicated and dispatched only while the chat is idle; goal
continuation never starts a second chat turn while another is in flight.

Goal events are published for goal start/resume boundaries, goal-linked proposal
confirmation, goal-linked Job implementation/approval/close boundaries, and
goal-linked Epic completion or blocked archival. Goal continuation queued
messages carry a compact transcript `text` such as `Goal continuation started.`
or `Goal resumed. Continuing...`, and are promoted as `system` chat messages so
the operator sees a control message rather than an operator-authored user
bubble. The full agent instruction is stored separately as `internal_prompt` on
the message content for audit and for `ChatTurnJob#prompt_for`. For a goal start,
that internal prompt tells the agent to begin work immediately under the active
goal; later boundary prompts tell it to continue after the linked work event.
Each internal prompt includes the active goal, completion condition, mode
snapshot, policy fields, iteration number, recent provenance-linked
proposals/Jobs/Epics, and the triggering scoped event.

## Agent tools

Chat agents get two goal-evaluation tools:

- `mark_goal_completed(reason, details?)` marks the active goal `completed`.
- `mark_goal_blocked(reason, details?)` marks the active goal `blocked`.

Successful completion and blocked results include the goal id, previous and
new statuses, reason, structured details, and owning chat id, title, and path.
Their chat cards use that metadata to link the goal back to its conversation
and to show the recorded reason and details. Older transcript results without
the additional metadata remain readable.

Agents cannot pause, resume, stop, or cancel goals through MCP. Those state
changes remain operator/API actions unless a later explicit auto policy adds a
separate trusted path.

## Safeguards

Syrus records no-op goal continuation turns when a
continuation finishes without creating or updating provenance-linked goal work.
After repeated consecutive no-op iterations, the goal is marked blocked
and a system audit message is written to the chat. Repeated blocked wake events
are similarly counted by signature and block the goal after
repeated blocked events.
