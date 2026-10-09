---
title: Android app
description: Build, run, and automate the first-party Syrus Android app.
---

The Syrus repository includes a first-party Android app in `android/`. The app
uses the existing Syrus app API rather than an Android-specific backend:
operators enter a Syrus instance URL and an API token, the app verifies the
token with `GET /api/v1/app/bootstrap`, and it loads recent Jobs with
`GET /api/v1/app/jobs`.

## Local development

Run a local Syrus backend, then launch the Android app in an emulator. Android
emulators reach the host machine at `http://10.0.2.2:3000`; use an API token
from the web app's Credentials page.

```sh
cd android
gradle --no-daemon :app:assembleDebug
gradle --no-daemon :app:testDebugUnitTest
```

If this project later has a Gradle wrapper, prefer `./gradlew --no-daemon`
with the same tasks. Production or shared instances should use HTTPS; cleartext
HTTP is only configured for emulator loopback development hosts.

## Automation

`android/.syrus.yml` declares the Android app as a nested Syrus project. It
uses the bundled Android plugin's typed graders for debug assembly, local unit
tests, and CI-only connected device tests. Live emulator inspection uses the
generic Runtime Session panel with provider `android_emulator`, package
`dev.syrus.android`, and Gradle task `:app:assembleDebug`.
