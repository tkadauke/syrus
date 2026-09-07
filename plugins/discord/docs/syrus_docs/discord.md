# Discord

The `discord` plugin (`plugins/discord/`) adds Discord as a chat-delivery
platform: it links a Discord account to a Syrus user, listens for direct
messages over Discord's Gateway, routes them into the same chat pipeline as
the web UI, and delivers assistant replies back as Discord DMs. It is a
self-contained Rails engine plugin, installed but disabled by default
(`default_enabled: false`, `disableable: true`, category
`platform_delivery`). It behaves as another chat surface, not a separate
automation engine — there is no Discord-specific Job/Workflow/Epic model.

## Configuration

No `config_schema` — the only requirement is a single instance-wide
credential, `AppSetting.discord_bot_token` (encrypted `app_settings` column,
set from Admin Settings). `Discord::PlatformConfig#configured?` gates the
account-linking instructions shown under **Settings → Connected Platforms**
on whether that token is present.

## Account linking

Linking uses the same signed-token flow as other platform-delivery plugins:
the web UI issues a linking token (`Rails.application.message_verifier
(:platform_linking)`), and `Discord::PlatformConfig#instructions` tells the
user to DM `/link <token>` to the Syrus bot. `Discord::GatewayConnectionJob
#handle_linking` verifies the token, resolves the `User`, and creates/updates
a `PlatformIdentity` (`platform: "discord"`, keyed on the Discord user's
numeric `external_id`) with `linked_at` stamped — then confirms over DM. An
invalid or expired token gets a DM telling the user to generate a new one.

## Inbound: Gateway connection

`Discord::GatewayClient` is a from-scratch Gateway v10 WebSocket client (raw
`TCPSocket`/`OpenSSL::SSL::SSLSocket` plus the `websocket-driver` gem for
framing — no Discord SDK dependency): it IDENTIFYs with the
`DIRECT_MESSAGES | MESSAGE_CONTENT` intents (the minimum needed to read DM
text), answers Gateway heartbeats on the server-provided interval, and
RESUMEs a dropped session in place up to 5 attempts with linear backoff
before giving up and letting the caller reconnect from scratch. This is a
bot-initiated *outbound* connection — Syrus never opens an inbound HTTPS
endpoint for Discord, consistent with the rest of Syrus's no-inbound-webhook
design.

`Discord::GatewayConnectionJob` (a `PlatformPollingJob` subclass, registered
as the plugin's `platform_delivery` `connector_job_class`) owns exactly one
Gateway session per `#poll_once` call; when `GatewayClient#run` returns
(session exhausted or connection lost), the base class immediately
re-enqueues a fresh job, which opens a new connection — the same
self-healing pattern used for reconnection across worker restarts/deploys.
`PlatformDelivery::Registry.start_connectors!` starts/stops this job in step
with the plugin's enabled state (unlike core's Telegram adapter, which
starts unconditionally via `PlatformPollingJob.registry`).

For each `MESSAGE_CREATE` dispatch, the job:

- ignores anything that isn't a DM (`guild_id` present means a guild channel)
  and ignores bot-authored messages (including its own sends);
- treats a `/link <token>` message as account linking (see above);
- otherwise routes the text through `InboundMessageRouter` (`platform:
  "discord"`, keyed by the author's Discord user id/username) into the
  linked user's chat session; an unlinked sender gets a DM pointing them at
  **Settings → Connected Platforms**.

## Outbound: reply delivery

`Discord::PlatformAdapter` (registered as the plugin's `platform_delivery`
provider, `platform_key: "discord"`) implements the outbound half: given a
chat message and the recipient's `PlatformIdentity`, it extracts the text
content and calls `Discord::Client#send_dm`, which opens/reuses a DM channel
via `POST /users/@me/channels` and posts through `POST
/channels/:id/messages` using bot-token (`Authorization: Bot <token>`) REST
calls. Long replies are split on the last newline before Discord's 2000
character message cap (`DISCORD_MAX_CHARS`) rather than truncated, mirroring
the same chunking `PlatformDelivery::TelegramAdapter` does for Telegram's
4096-character cap. Delivery errors are logged and swallowed — a failed
Discord DM never fails the chat turn that produced the reply.

## Admin/sidebar pages

None. All Discord-specific UI is the existing generic **Settings → Connected
Platforms** page (`PlatformIdentity::PlatformConfig::Base.for` dispatches to
`Discord::PlatformConfig` once the plugin registers itself); there is no
Discord-specific admin page.

## MCP tools

None.

## Operational notes

This plugin depends on external Discord connectivity, a live Gateway
session, and a valid bot token — monitor it like any other long-lived
platform integration. A revoked or invalid `discord_bot_token` shows up as
`Discord::PlatformConfig#configured?` returning false (linking instructions
disappear) and `GatewayConnectionJob` logging connection errors on every
reconnect attempt.
