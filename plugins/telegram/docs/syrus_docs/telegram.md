# Telegram

The `telegram` plugin (`plugins/telegram/`) adds Telegram as a chat-delivery
platform: it links a Telegram account to a Syrus user, long-polls the Telegram
Bot API for direct messages, routes them into the same chat pipeline as the web
UI, and delivers assistant replies back to the Telegram chat. It is a
self-contained Rails engine plugin (`default_enabled: false`, `disableable:
true`, category `platform_delivery`) and behaves as another chat surface, not a
separate automation engine.

## Enablement and upgrades

New instances start with the plugin disabled. Instances that already had a
Telegram bot token configured when Telegram moved out of core have the plugin
enabled automatically by a migration, so existing Telegram setups keep working
with no operator action. Instances without a token are left disabled; enable it
from **Admin → Plugins**.

## Configuration

No `config_schema`. Telegram uses three instance-wide settings, edited in Admin
Settings: `telegram_bot_token` (encrypted), `telegram_bot_handle` (the public
`@handle` shown in linking instructions), and the internal
`telegram_update_offset` polling cursor. They are unchanged from before the
extraction. `Telegram::PlatformConfig#configured?` gates the linking
instructions under **Settings → Connected Platforms** on the handle.

## Account linking

The web UI issues a signed linking token (valid 15 minutes) and tells the user
to send `/start <token>` to the bot. `Telegram::PollUpdatesJob` verifies the
token, creates or updates a `PlatformIdentity` (`platform: "telegram"`, keyed
on the Telegram user's numeric id) and confirms in the chat. An invalid or
expired token gets a reply asking the user to generate a new one. Messages from
unlinked users get a pointer to Settings → Connected Platforms.

## Delivery and polling

`Telegram::PollUpdatesJob` runs on the `plugin_telegram` queue, long-polls
`getUpdates`, advances the stored offset after each update, and re-enqueues
itself; the connector watchdog and the admin **Start polling** action re-prime
it like any other platform connector. `Telegram::PlatformAdapter` delivers
assistant replies, split at Telegram's 4096-character message limit.
