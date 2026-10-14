# Chat Scheduled Messages

The `/schedule` chat slash command lets an operator send a chat message later without involving the agent at scheduling time.

Command shape:

```ts
{ name: "/schedule", kind: "system", args: [{ name: "time", required: false }, { name: "message", required: false }] }
```

When both a time and message are present, the browser parses the time into an absolute UTC timestamp and posts it to:

```
POST /api/v1/app/chats/:chat_id/scheduled_messages
```

The endpoint creates a `ScheduledChatMessage` with `chat_session_id`, `user_id`, `body`, `fire_at`, and `sent_at`. The row enqueues `ScheduledChatMessageFireJob` for `fire_at`; `PollScheduledChatMessagesJob` also sweeps due unsent rows every minute as a resilience path. When the fire job runs, it creates a normal visible user chat message with `requested_by: "scheduled_message"` and marks the scheduled row sent. It applies the same mention gate as interactive messages: chats with 0-1 participants enqueue `ChatTurnJob` on the chat queue for every scheduled message, while chats with 2+ participants only enqueue a turn when the body contains a case-insensitive `@syrus` mention. An unmentioned group-chat message is still delivered without marking a turn in flight. The fire job is idempotent through `sent_at`.

If either the time or message is missing, the composer opens a modal with separate Time and Message fields. Supported client-side time forms are intentionally small: `Xm`, `Xh`, `Xd`, `in 1 hour`, `tomorrow`, `tomorrow 9am`, and `HH:MM`. Editing and cancelling scheduled messages are not part of this feature.
