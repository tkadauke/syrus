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
