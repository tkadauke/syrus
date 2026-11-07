# External Platform Integrations

Syrus supports Telegram and Discord chat delivery through bundled plugins.
Users link their identity under **Settings → Connected Platforms**. External
chat sessions use `speak_when_spoken_to`, so Syrus replies to inbound user
messages rather than speaking proactively. Discord replies are split at its
2,000-character message limit.

Discord is configured with `AppSetting.discord_bot_token`; the corresponding
plugin must be enabled. Telegram has its own plugin configuration.

Gateway, polling, watchdog, and identity internals live in [external-platform
architecture](../../docs/engineering/architecture/external-platforms.md).
Plugin authors should use the [platform extension guidance](../../docs/engineering/conventions/plugins/authoring.md).
