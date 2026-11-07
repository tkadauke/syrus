# Chat Scheduled Messages

Use `/schedule` to send a chat message later without invoking the agent at
scheduling time. Supply the time and message inline or fill them in through the
composer modal.

Supported time forms are `Xm`, `Xh`, `Xd`, `in 1 hour`, `tomorrow`, `tomorrow
9am`, and `HH:MM`. In a group chat, the scheduled message invokes Syrus only
when it contains an exact `@syrus` mention; otherwise it is delivered without
starting an agent turn. Editing and cancelling scheduled messages are not
supported.

Endpoint, persistence, and delivery-job internals live in [scheduled-message
architecture](../../docs/engineering/architecture/chat-scheduled-messages.md).
