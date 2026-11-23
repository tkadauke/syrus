# External Platform Integrations

Syrus supports Telegram and Discord chat delivery through bundled plugins
(`telegram` and `discord`).
Users link their identity under **Settings → Connected Platforms**. External
chat sessions use `speak_when_spoken_to`, so Syrus replies to inbound user
messages rather than speaking proactively. Discord replies are split at its
2,000-character message limit.

Discord is configured with `AppSetting.discord_bot_token`; the corresponding
plugin must be enabled. Telegram is configured with
`AppSetting.telegram_bot_token` and `AppSetting.telegram_bot_handle`; the
`telegram` plugin must be enabled. It is disabled by default, but instances
that already had a Telegram bot token when Telegram moved out of core have it
enabled automatically on upgrade, so existing setups keep working.

Gateway, polling, watchdog, and identity internals live in [external-platform
architecture](../../docs/engineering/architecture/external-platforms.md).
Plugin authors should use the [platform extension guidance](../../docs/engineering/conventions/plugins/authoring.md).
