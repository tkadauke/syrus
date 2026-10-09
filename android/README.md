# Syrus Android

This directory contains the first-party Android app foundation. The MVP keeps
the surface intentionally small: connect to a Syrus instance with an existing
user API token, verify the token through `/api/v1/app/bootstrap`, and load a
compact list of recent Jobs from `/api/v1/app/jobs`, including Jobs with active
runtime work so operators can check live progress from the mobile home screen.

## Project Contract

- Package namespace: `dev.syrus.android`.
- Module layout: `app/src/main/kotlin/dev/syrus/android/{data,ui}` for Kotlin
  app code and `app/src/main/java/dev/syrus/android/model` for simple Java
  model types shared by the API client and UI.
- Authentication: `Authorization: Bearer <api_token>`, matching the web app
  and CLI app API contract. Tokens are entered by the operator and stored in
  private app preferences for the MVP.
- Local instance URL: Android emulators reach the host Rails server at
  `http://10.0.2.2:3000`. Cleartext HTTP is scoped to emulator loopback names
  in `res/xml/network_security_config.xml`; production instances should use
  HTTPS.
- Runtime package: `dev.syrus.android`. The default launcher activity is
  `MainActivity`.

## Local Development

Use the repository's Android worker/toolchain when available. From this
directory:

```sh
gradle --no-daemon :app:assembleDebug
gradle --no-daemon :app:testDebugUnitTest
```

If a Gradle wrapper is later generated for this project, prefer
`./gradlew --no-daemon ...`; Syrus Android graders already prefer a wrapper
when one is present and fall back to `gradle`.

The project declares JDK 17 in `.java-version`, matching the Android Gradle
Plugin baseline used by the worker image.

To exercise the MVP manually:

1. Start the Rails app locally on port 3000.
2. Generate or copy a user API token from the web app's Credentials page.
3. Launch the debug APK in an Android emulator.
4. Enter `http://10.0.2.2:3000` and the API token.

## Automation

`android/.syrus.yml` declares the nested Android app project and uses the
bundled Android plugin's typed graders:

- `android-assemble` runs `:app:assembleDebug`.
- `android-unit` runs `:app:testDebugUnitTest`.
- `android-connected` runs `:app:connectedDebugAndroidTest` only in CI phases.

Visual/runtime inspection should use the generic Runtime Session UI with the
`android_emulator` provider. The runtime can build `:app:assembleDebug`, install
the resulting APK, launch `dev.syrus.android`, capture frames, inspect the
UIAutomator tree, and deliver lease-gated input through the standard visual
Runtime controls.
