# Telegram

Telegram adds a platform-delivery channel for Syrus chat. It links Telegram users to Syrus accounts, long-polls the Telegram Bot API for direct messages, and delivers chat replies back to Telegram.

The plugin is disabled by default on new instances because it requires a Telegram bot token. Instances that already had a bot token when Telegram was extracted from core have it enabled automatically on upgrade, along with the Connected accounts plugin it depends on. The plugin is experimental (it relies on that experimental plugin), so beta mode must be on; the upgrade enables it for those instances.

## What It Adds

- Telegram account linking (`/start <token>`).
- Long-polling ingestion of direct messages.
- Message delivery from Syrus chats back to Telegram.

## Operational Notes

The bot token is an instance-owned connected account (provider "Telegram bot") managed on Admin → Connected accounts; the bot handle is read from Telegram itself. Monitor the long-lived poller like any other platform integration.
