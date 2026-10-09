# Android App

Syrus includes a first-party Android app under `android/`. The app is a
separate Android Gradle project, not part of the Rails/Vite frontend or the
desktop app.

## MVP contract

- Package/application id: `dev.syrus.android`.
- Authentication: the app uses the existing app API bearer token convention,
  `Authorization: Bearer <api_token>`, matching the CLI and app API docs.
- Initial API surface: `GET /api/v1/app/bootstrap` identifies the signed-in
  user, and `GET /api/v1/app/jobs?limit=<n>&state=all&include_active_work=true`
  loads a compact recent Job list including Jobs with active runtime work. The
  MVP does not add Android-only backend endpoints.
- Local emulator development uses `http://10.0.2.2:3000` to reach a Rails
  server running on the host. Cleartext HTTP is allowed only for emulator
  loopback hostnames in the Android network security config.

## Automation

The nested `android/.syrus.yml` project declares Linux execution capabilities
and uses Android plugin typed graders:

- `android-assemble` runs `:app:assembleDebug`.
- `android-unit` runs `:app:testDebugUnitTest`.
- `android-connected` runs `:app:connectedDebugAndroidTest` in CI phases.

Agents and operators should use the Android plugin's `android_emulator`
Runtime Session provider for live visual inspection and input. Build/reload
should run `:app:assembleDebug`, install the debug APK, and launch
`dev.syrus.android`.

## Source layout

Kotlin app code lives under
`android/app/src/main/kotlin/dev/syrus/android/`. Java model types live under
`android/app/src/main/java/dev/syrus/android/model/`. Keep network/API code in
`data`, screen/controller code in `ui`, and cross-language data models in
`model` so future MVP Jobs can add screens without re-deciding the project
shape.
