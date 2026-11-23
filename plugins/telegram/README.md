# Telegram

Telegram adds a platform-delivery channel for Syrus chat. It links Telegram users to Syrus accounts, long-polls the Telegram Bot API for direct messages, and delivers chat replies back to Telegram so operators can interact with Syrus away from the web UI.

The plugin is disabled by default for new instances because it requires a Telegram bot token. Instances that already had a Telegram bot token configured when the plugin was introduced have it enabled automatically on upgrade.

## What It Adds

- Telegram account linking (`/start <token>`).
- Long-polling ingestion of direct messages.
- Message delivery from Syrus chats back to Telegram.

## Settings

The bot token, bot handle and update offset still live in the core `AppSetting` registry, the same way Discord's token does. Moving credentials onto connected accounts is a separate piece of work.

## When To Enable

Enable Telegram when operators should be able to use Syrus from Telegram. Keep it disabled on installations that use only the web app or desktop app.
