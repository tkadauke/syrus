# Telegram

The `telegram` plugin (`plugins/telegram/`) adds Telegram as a chat-delivery
platform: it links a Telegram account to a Syrus user, long-polls the Telegram
Bot API for direct messages, routes them into the same chat pipeline as the web
UI, and delivers assistant replies back to Telegram. It is installed but
disabled by default (`default_enabled: false`, `disableable: true`, category
`platform_delivery`). Instances that already had a Telegram bot token when
Telegram moved out of core have the plugin (and the Connected accounts plugin it
now depends on) enabled automatically on upgrade, so existing setups keep
working with no action.

## Configuration

No `config_schema`. The bot token is an instance-owned **connected account**
(provider "Telegram bot"), managed by administrators on **Admin → Connected
accounts**; **Admin → Settings → Telegram** links there. To set or rotate it,
paste the token from @BotFather: Syrus checks it with Telegram's `getMe` call
before storing it, encrypted, and never shows it again. The account's label
defaults to the bot's @handle, which is how Syrus resolves the handle shown in
linking instructions. Rotation takes effect on the next poll or message;
disconnecting the account stops polling. Telegram has no token revocation call,
so disconnecting does not invalidate the token at Telegram: reset it with
@BotFather when needed.

The plugin reaches the token only through the Connected accounts broker, as a
named platform service with the instance-owned account in service mode. Every
use is audited with its purpose, and the token is held in memory for the length
of one API call only. (Long polling means one audit entry per poll; Connected
accounts' retention policy bounds how long they are kept.)

**Upgrading:** an existing token from the old application setting is copied into
a connected account on first use, verified with a live call, and only then
erased from the old setting. If the copy or verification fails, the old value
stays in place and keeps working, and the copy is retried every ten minutes. Once
a connected account exists the old setting is never read again.

`Telegram::PlatformConfig#configured?` gates the linking instructions under
**Settings → Connected Platforms** on the account being connected; the polling
connector starts only then too.

## Account linking

The web UI issues a signed linking token; `Telegram::PlatformConfig#instructions`
tells the user to send `/start <token>` to the bot. `Telegram::PollUpdatesJob`
verifies the token, resolves the `User`, creates or updates a `PlatformIdentity`
(`platform: "telegram"`), and confirms in chat. An invalid or expired token gets
a reply asking the user to generate a new one.

## Inbound: long polling

`Telegram::PollUpdatesJob` (a `PlatformPollingJob`, registered as the plugin's
`connector_job_class`) calls `Telegram::Client#get_updates` against
`getUpdates`, tracks `AppSetting.telegram_update_offset` as the cursor, and
routes non-`/start` messages through `InboundMessageRouter`. It re-enqueues
itself after each cycle and backs off after errors. An unlinked sender is told
to link from **Settings → Connected Platforms**.

## Outbound: reply delivery

`Telegram::PlatformAdapter` (`platform_key: "telegram"`) sends assistant text via
`Telegram::Client#send_message`, splitting long replies at Telegram's
4096-character limit on the last newline. Delivery errors are logged and
swallowed so a failed send never fails the chat turn.

## Operational notes

Disabling the plugin stops the connector and makes `telegram` an invalid
`PlatformIdentity` platform. The connector is re-primed by
`PlatformConnectorWatchdogJob` and `POST /api/v1/app/admin/platform_polling/start`;
see `config/syrus_docs/external_platforms.md`. The plugin's job runs on the
`plugin_telegram` queue.

## MCP tools

None.
