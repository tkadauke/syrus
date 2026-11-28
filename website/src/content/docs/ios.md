---
title: iOS App
description: Build, sign, and ship the Syrus iOS shell to TestFlight with signing material supplied from your own environment.
---

# iOS App

The Syrus iOS app is a native shell that loads your Syrus instance in a web
view and receives push notifications. The project lives under `ios/` in the
Syrus repository and is generated from `ios/project.yml` with XcodeGen.

## Simulator builds

Simulator builds and tests are unsigned and need no Apple account:

```sh
cd ios
make generate
make test
```

## Signing and TestFlight

No signing material is committed to the repository. The bundle identifier
defaults to `app.syrus.ios`; your Apple team, an optional bundle-id override,
and an App Store Connect API key come from your own environment.

1. Create an App ID with the Push Notifications capability and an App Store
   Connect API key (App Manager access). Create the app record in App Store
   Connect.
2. Export your settings:

   ```sh
   export SYRUS_IOS_TEAM_ID=ABCDE12345
   export ASC_KEY_PATH=$HOME/.appstoreconnect/AuthKey_XXXX.p8
   export ASC_KEY_ID=XXXXXXXXXX
   export ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
   # optional: SYRUS_IOS_BUNDLE_ID, SYRUS_IOS_BUILD_NUMBER
   ```

3. Run `make archive` to produce a signed Release archive, `make export` for
   an `.ipa`, or `make upload` to send the build to TestFlight.

Debug builds use the APNs sandbox environment and Release builds use
production. The app bundles a privacy manifest declaring no tracking. For
configuring the server side of push delivery (APNs key and team), see
`ios/README.md` in the repository.

## Versioning and release automation

The marketing version is set in `ios/project.yml`; the build number defaults
to the commit count of the checked-out ref (override with
`SYRUS_IOS_BUILD_NUMBER`), so the same commit always produces the same number.
Pull requests that touch `ios/` run an unsigned simulator build and test job on
macOS. Authorized operators can trigger the **iOS Release** GitHub Actions
workflow to archive, export, or upload to TestFlight, with signing credentials
supplied as repository secrets. Build logs are retained as artifacts; secrets
are never printed. To roll back, expire the build in App Store Connect and
re-release the last good commit with a higher build number.
