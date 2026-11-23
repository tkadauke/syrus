# External Platform Integrations

Syrus supports Telegram and Discord chat delivery through bundled plugins.
Users link their identity under **Settings → Connected Platforms**. External
chat sessions use `speak_when_spoken_to`, so Syrus replies to inbound user
messages rather than speaking proactively. Discord replies are split at its
2,000-character message limit.

Discord is configured with `AppSetting.discord_bot_token` and Telegram with
`AppSetting.telegram_bot_token` plus `telegram_bot_handle`; the corresponding
`discord` or `telegram` plugin must be enabled. The `telegram` plugin is
disabled by default, but upgrading an instance that already has a Telegram bot
token enables it automatically, so existing Telegram setups keep working.

Gateway, polling, watchdog, and identity internals live in [external-platform
architecture](../../docs/engineering/architecture/external-platforms.md).
Plugin authors should use the [platform extension guidance](../../docs/engineering/conventions/plugins/authoring.md).
