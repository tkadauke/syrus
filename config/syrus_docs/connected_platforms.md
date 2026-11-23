# Connected platforms

Connect a Syrus user to a Telegram or Discord identity with a linking token
that expires after 15 minutes. Telegram and Discord are provided by the
bundled `telegram` and `discord` plugins, which must be enabled for the
platform to appear. Telegram linking requires `telegram_bot_handle`; Discord
linking requires `discord_bot_token`.

For implementation details, see `docs/engineering/architecture/connected_platforms.md`.
