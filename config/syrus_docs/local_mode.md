# Local Mode

Local Mode lets a chat agent read and write files, run commands, and inspect
git state directly on an operator's own machine over a reverse WebSocket
tunnel — no server-side clone required. It is a labs feature (`local_mode`),
disabled by default.

## Enabling

```ruby
Feature.find_by(slug: 'local_mode').update(enabled: true)
```

Once enabled, chats can be switched to Local mode from the chat mode
selector, and the `syrus local` CLI subcommand becomes usable.

## Pairing flow

Local Mode requires pairing the CLI to a specific chat session before the
tunnel can be authorized. The flow is:

1. **The frontend mints a pairing session.** While a chat is in `local` mode
   and not yet connected, `LocalDaemonBanner` calls
   `POST /api/v1/app/chats/:chat_id/local_daemon_session`
   (`Api::V1::App::LocalDaemonSessionsController#create`), which creates (or
   reactivates) a `LocalDaemonSession` and returns its `chat_session_id` and
   `auth_token`. The banner renders these interpolated into a copyable
   command: `syrus local --chat <chat_session_id> --token <auth_token>`.
2. **The operator runs the command** in their local repository checkout.
3. **The CLI subscribes to `LocalTunnelChannel`** over Action Cable, sending
   `chat_session_id` and `tunnel_token` (the pairing session's `auth_token`)
   in the subscribe identifier. `LocalTunnelChannel#subscribed` looks up a
   connected `LocalDaemonSession` owned by the current user with a matching
   token and rejects the subscription (`reject_subscription`) if none is
   found — for example when the values were copied incorrectly, the session
   has expired, or `local_mode` is disabled.
4. **On a confirmed subscription**, the CLI sends a `connect` message with
   the local repository's slug and current branch; the channel replies
   `connected` and marks the session live, which the chat UI reflects via
   `local_daemon_state`.

## Wire protocol

Once connected, `LocalTunnelChannel` and the CLI exchange typed JSON frames
over the Action Cable subscription:

| Direction | Type | Fields |
|---|---|---|
| CLI → server | `connect` | `repo`, `branch` |
| CLI → server | `pong` | — (heartbeat reply) |
| CLI → server | `tool_result` | `tool_use_id`, `content` |
| server → CLI | `connected` | — |
| server → CLI | `ping` | — (heartbeat, every 15s) |
| server → CLI | `tool_call` | `tool_use_id`, `tool`, `input` |
| server → CLI | `disconnected` | `reason` (e.g. `heartbeat_timeout`) |

The server disconnects a daemon session that misses heartbeats for 45
seconds (`LocalDaemonSession::HEARTBEAT_TIMEOUT`); the CLI must reply to
every `ping` with a `pong` to stay connected. A session that drops this way
needs a fresh pairing command from the chat UI to reconnect — the CLI does
not currently re-pair automatically.

## Tools

The daemon executes `read_file`, `write_file`, `list_files`, `run_command`,
`git_diff`, `git_diff_staged`, and `git_status` against the paired repository
root (`cli/cmd/local.go`). Paths are resolved and rejected if they escape the
repository root.

## Limitations

- One daemon session per chat.
- The auth token in the pairing command is sensitive — it authorizes file
  and command access to the operator's machine for the paired chat.
- Losing the connection past the heartbeat timeout requires reloading the
  chat UI to mint (or reactivate) a pairing session and re-running the
  copied command.
