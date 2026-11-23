# Push notifications

## How it works

1. After Syrus loads, the app asks for notification permission and registers
   with APNs, receiving a device token.
2. The app posts the token to `POST /api/v1/app/push_devices` by running a
   `fetch` inside the web view, so the request carries the signed-in session
   cookie and CSRF token. Rails stores a `PushDevice` tied to the user and the
   session; signing out destroys the session and the device with it.
   `DELETE /api/v1/app/push_devices/:id` and
   `DELETE /api/v1/app/push_devices/destroy_by_token` (`token` param) remove it.
3. When `NotificationService` creates a notification (respecting the user's
   notification preferences), `PushNotificationDeliveryJob` sends it to each
   active device over APNs. APNs "unregistered" responses disable the device;
   transient failures retry with backoff.
4. Tapping a notification opens its `syrus.path` (for example `/jobs/42`) in the
   web view. Only paths on the connected server are accepted.

## Server prerequisites (cannot be exercised in CI)

Create an APNs auth key (Apple Developer > Keys > Apple Push Notifications
service) and set on the Syrus server:

| Variable | Value |
|---|---|
| `SYRUS_APNS_KEY_ID` | Key ID of the `.p8` key |
| `SYRUS_APNS_TEAM_ID` | Apple Developer Team ID |
| `SYRUS_APNS_BUNDLE_ID` | App bundle ID (`dev.syrus.ios` unless you change it) |
| `SYRUS_APNS_PRIVATE_KEY` | Contents of the `.p8` file (`\n` escapes allowed) |

Without all four, delivery is skipped and nothing is enqueued.

## App prerequisites

- A paid Apple Developer account, an App ID with Push Notifications enabled and
  a provisioning profile; set the team in Xcode.
- Push does not work in the Simulator for real APNs delivery. Test on a device.
  Debug builds register as `sandbox` (entitlement `aps-environment:
  development`); Release builds register as `production`. Change the
  entitlement to `production` for App Store/TestFlight builds.

## What is verified locally

Rails: registration/removal endpoints, model, payload, APNs client (JWT and
response classification against a fake transport) and job enqueueing are
covered by specs. iOS: URL parsing, persistence, navigation policy, token
encoding, registration scripts and coordinator behavior are unit tested. Real
APNs delivery and the permission prompt need a device and credentials.
