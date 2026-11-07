# Connected Platforms

Connected Platforms lets an operator link their Syrus user account to an
external messaging identity. The `platform_identities` table stores the Syrus
user, platform slug, platform-stable external user id, optional external handle,
and link timestamp. `(platform, external_id)` is unique so one external account
maps to one Syrus account.

The account settings UI calls:

- `GET /api/v1/app/platform_identities` to list the current user's linked
  identities and supported platform availability.
- `POST /api/v1/app/platform_identities/linking_token` with
  `{ "platform": "telegram" }` to generate a 15-minute signed
  `:platform_linking` token for platform pollers to consume.
- `DELETE /api/v1/app/platform_identities/:id` to unlink an identity scoped to
  the current user.

Telegram is available only when `AppSetting.telegram_bot_handle` is present.
Slack is listed as a supported platform but disabled until its integration is
configured. Discord is provided by the `discord` plugin (`plugins/discord/`)
through the `:platform_delivery` extension point; it appears in the list once
the plugin is enabled, and becomes configured (linkable) once
`AppSetting.discord_bot_token` is also set (see
`config/syrus_docs/external_platforms.md`). When a platform poller creates a
`PlatformIdentity`, Syrus broadcasts `platform_identity_linked` on
`AppUserChannel` with the refreshed settings payload so the browser updates
without a page refresh.
