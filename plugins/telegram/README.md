# Telegram

Telegram adds a platform-delivery channel for Syrus chat. It links Telegram users to Syrus accounts, long-polls the Telegram Bot API for direct messages, and delivers chat replies back to Telegram.

The plugin is disabled by default on new instances because it requires a Telegram bot token. Instances that already had a bot token when Telegram was extracted from core have it enabled automatically on upgrade.

## What It Adds

- Telegram account linking (`/start <token>`).
- Long-polling ingestion of direct messages.
- Message delivery from Syrus chats back to Telegram.

## Operational Notes

The bot token and handle are instance settings on Admin → Settings. Monitor the long-lived poller like any other platform integration.
