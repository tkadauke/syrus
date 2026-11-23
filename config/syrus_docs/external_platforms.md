# External Platform Integrations

Syrus supports Telegram and Discord chat delivery through bundled plugins
(`telegram` and `discord`).
Users link their identity under **Settings → Connected Platforms**. External
chat sessions use `speak_when_spoken_to`, so Syrus replies to inbound user
messages rather than speaking proactively. Discord replies are split at its
2,000-character message limit.

Each platform is configured with a bot token held as an instance-owned
connected account: add it on **Admin → Connected accounts** (provider
"Discord bot" or "Telegram bot"), and enable the corresponding plugin. Both
plugins depend on the Connected accounts plugin (and through it Credential
Store); enabling them enables those. The token is validated against the
platform before it is stored, encrypted, never displayed again, and used only
for the duration of each call (Discord's long-lived Gateway connection holds it
in memory for the life of the connection). To rotate a token, paste the new one
on the same page: Discord's Gateway reconnects with it within about a minute
(one heartbeat), and Telegram's next poll or message uses it. Disconnecting
the account stops the connector. Bot tokens are not OAuth, so Syrus cannot
revoke them at the platform; reset the token with the platform (Discord
developer portal, @BotFather) when it should stop working everywhere.
Instances that already had a token configured as an application setting have
it carried over automatically, and the plugins (with their dependencies) are
enabled on upgrade, so existing setups keep working.

Gateway, polling, watchdog, and identity internals live in [external-platform
architecture](../../docs/engineering/architecture/external-platforms.md).
Plugin authors should use the [platform extension guidance](../../docs/engineering/conventions/plugins/authoring.md).
