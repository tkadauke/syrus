# iOS push notifications (APNs)

The first-party iOS app registers its APNs device token with Syrus via
`POST /api/v1/app/mobile_devices` (and removes it with `DELETE`). Tokens are
associated with the signed-in user and session; signing out or revoking the
session disables the device. Delivery runs in a background job and uses
token-based (`.p8`) APNs authentication over HTTP/2. Devices that APNs reports
as invalid (`410`, `BadDeviceToken`, `Unregistered`) are disabled automatically.

## Operator settings

Set these environment variables on web and worker processes. No secret is
stored in the database. A process restart is needed after changing them.

| Variable | Purpose |
| --- | --- |
| `SYRUS_APNS_TEAM_ID` | Apple Developer Team ID (required) |
| `SYRUS_APNS_KEY_ID` | Key ID of the APNs auth key (required) |
| `SYRUS_APNS_AUTH_KEY` | PEM contents of the `.p8` key; `\n` escapes allowed |
| `SYRUS_APNS_AUTH_KEY_PATH` | Path to the `.p8` file, used when `SYRUS_APNS_AUTH_KEY` is unset |
| `SYRUS_APNS_TOPIC` | Default bundle id (`apns-topic`) for devices that do not report one (optional) |

Team ID, key ID, and one of the key variables are required. When they are
missing, push delivery is skipped silently; device registration still works.
Debug builds register against the APNs sandbox, release builds against production.

## Diagnosing push setup

`GET /api/v1/app/mobile_devices` returns the signed-in user's registered
devices (tokens masked to their last six characters, never the full token),
their APNs environment, any disabled reason, and `apns_configured`.
`POST /api/v1/app/mobile_devices/test_notification` sends a labelled test push
to only that user's active devices (optionally narrowed with `token`) and
reports `delivered`, `token_rejected`, `failed`, or `error` per device. It
answers `503 apns_not_configured` or `422 no_registered_device` when push cannot
work. The test push deep-links to `/notifications` and creates no notification.
The iOS app's **⋯ → Diagnostics** screen uses both.

## Review card haptics

In the iOS shell, the Review Workspace card drag requests native haptics: a light
selection tick per distance increment crossed (either direction) and a stronger
impact when a card commits left or right. No haptics fire during programmatic
animation or scrolling, when the system reduced-motion preference is on, or when
`localStorage["syrus.haptics"]` is `"off"`. The device's System Haptics setting is
respected, and ordinary browsers do nothing.
