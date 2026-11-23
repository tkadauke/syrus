# Telegram

The `telegram` plugin (`plugins/telegram/`) adds Telegram as a chat-delivery
platform: it links a Telegram account to a Syrus user, long-polls the Telegram
Bot API for direct messages, routes them into the same chat pipeline as the web
UI, and delivers assistant replies back to Telegram. It is installed but
disabled by default (`default_enabled: false`, `disableable: true`, category
`platform_delivery`). Instances that already had a Telegram bot token when
Telegram moved out of core have the plugin enabled automatically on upgrade, so
existing setups keep working with no action.

## Configuration

No `config_schema`. Telegram uses instance-wide settings on **Admin → Settings**:
`AppSetting.telegram_bot_token` (encrypted) and `AppSetting.telegram_bot_handle`.
`Telegram::PlatformConfig#configured?` gates the linking instructions under
**Settings → Connected Platforms** on the handle being present; the polling
connector starts only when a token is present.

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
