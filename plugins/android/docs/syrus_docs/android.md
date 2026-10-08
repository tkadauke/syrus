# Android

The `android` plugin (`plugins/android/`) provides Android project awareness
on top of the generic Java/Kotlin foundation. It is default-ON, disableable,
category `platform_delivery`, `prepare_priority: 47`, and depends on `java`
and `kotlin`.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects Android Gradle Plugin declarations (`com.android.application`, `com.android.library`, `com.android.test`, dynamic feature and asset-pack plugins), Android Kotlin plugin declarations, `com.android.tools.build:gradle` buildscript classpath entries, and conventional `AndroidManifest.xml` paths. It returns no prepare command by detection alone, so generic Linux workers do not invent project-specific Android Gradle work. It reuses `.java-version` as the JVM version file and adds Android Gradle, `adb`, emulator, `sdkmanager`, and `avdmanager` command-span labels for worker-health diagnostics. |
| `:step_environment` | Forwards `ANDROID_HOME` and `ANDROID_SDK_ROOT` from the worker image into prepare/grader subprocesses and computes per-workspace `ANDROID_USER_HOME`, `ANDROID_PREFS_ROOT`, and `ANDROID_AVD_HOME` under `.syrus/android`. This keeps SDK installation global while Android user state, repositories, and AVD metadata stay scoped to the workflow workspace. |
| `:grader_type` | Expands `type: android-assemble`, `type: android-unit-test`, `type: android-instrumented-test`, and `type: android-managed-device` into wrapper-aware Gradle graders. Generated steps declare Linux execution capabilities, use Android source/manifest/Gradle file scopes, aggregate Android/JUnit XML reports when present, and expose package, report, managed-device, and log paths in grader metadata. |
| `:runtime_session_provider` | Adds the `android_emulator` Coding Mode Runtime Session provider. It starts an isolated emulator/AVD, builds and installs APKs through Gradle/ADB, launches apps, captures PNG frames, inspects the UI hierarchy, pages logcat, and delivers lease-gated touch/key/text input through the standard Runtime UI. |
| `:prompt_injector` | Tells agents to keep Java/Kotlin/JVM conventions in the Java/Kotlin plugins, treat Android Gradle Plugin, SDK, emulator/device, artifact, and runtime behavior as Android-owned, run Android work on Linux execution capabilities, and use Runtime Sessions' provider-neutral visual frame/input contract for live emulator viewing and control. |
| `:review_criteria_provider` | Adds review criteria for declared worker capabilities, APK/AAB variant/signing distinctions, and avoiding Android-specific bypasses around Runtime Session visual frame/input. |

## Architecture boundary

Java and Kotlin own generic JVM conventions: JDK selection, Gradle/Maven
wrappers, Kotlin/JVM signals, test graders, and JVM review guidance. Android
owns Android Gradle Plugin, Android SDK availability, Gradle Managed Devices,
emulators, physical devices, APK/AAB artifacts, mobile signing/variant
behavior, and mobile runtime behavior.

Android execution uses Linux capabilities. Do not introduce an `os: android`
target for Android work; workers that can build or run Android should advertise
Linux plus the relevant Android SDK/emulator/device capabilities.

Interactive Android support is owned by the `android_emulator` Runtime Session
provider. The provider implements the existing `:runtime_session_provider`
interface and publishes frames and input through Syrus's provider-neutral visual
Runtime path, the same operator/agent control path used by other visual
providers. Android does not add separate emulator-only UI plumbing for live
viewing or input.

## Detection and prepare behavior

The detector recognizes:

- Android Gradle Plugin IDs such as `com.android.application`,
  `com.android.library`, `com.android.test`, `com.android.dynamic-feature`,
  and `com.android.asset-pack`.
- Android Gradle Plugin buildscript classpaths such as
  `com.android.tools.build:gradle`.
- Kotlin Android plugin declarations such as `kotlin("android")` and
  `org.jetbrains.kotlin.android`.
- Conventional Android manifests such as `app/src/main/AndroidManifest.xml`.
- Conventional Android resource and instrumented-test layouts such as
  `app/src/main/res` and `app/src/androidTest`.

The detector intentionally returns `[]` from `prepare_commands`. SDK packages
are now available in the shared Linux worker image, but project-owned Android
Gradle tasks vary too much for detection alone to invent a safe prepare
command. This still lets RepoPluginDetector, Admin -> Plugins suggestions,
prompt context, review criteria, and future Android-specific typed
graders/providers recognize the repository.

## Typed Android graders

Android typed graders run through Gradle on Linux workers. They prefer a
repository wrapper (`./gradlew`) and fall back to `gradle`. Every generated
step declares:

```yaml
capabilities:
  os: linux
```

Available types:

| Type | Default Gradle task | Default JUnit/report behavior |
|---|---|---|
| `android-assemble` | `assembleDebug` | No JUnit output by default; records APK, AAB, mapping, and report directories in metadata. |
| `android-unit-test` | `testDebugUnitTest` | Aggregates `build/test-results/testDebugUnitTest` and `test*UnitTest` XML reports into `.syrus/grade-output/<name>-junit.xml`. |
| `android-instrumented-test` | `connectedDebugAndroidTest` | Aggregates connected Android test XML reports and records connected test result/report directories. |
| `android-managed-device` | `allDevicesCheck` | Aggregates Gradle Managed Device XML reports and records managed-device result, report, and additional-output directories. |

Common options: `name`, `display_name`, `tasks`/`task`, `phases`, `required`,
`timeout_minutes`, `deps`, `when_files_changed`, `junit_output`, `report_paths`,
`artifact_paths`, and `log_paths`. `android-managed-device` also accepts
`devices`/`device` plus `variant`; when devices are supplied and no explicit
tasks are configured, it generates Gradle tasks such as
`pixel2api30DebugAndroidTest`. Use explicit `tasks:` when the repository names
managed-device tasks differently.

Single Android app:

```yaml
grade:
  - type: android-assemble
    tasks: [assembleDebug]
  - type: android-unit-test
    tasks: [testDebugUnitTest]
  - type: android-managed-device
    tasks: [allDevicesCheck]
    phases: [landing, ci]
    timeout_minutes: 60
```

Android monorepo project:

```yaml
project:
  id: android-app
  label: Android app
  kind: application
  capabilities:
    os: linux

grade:
  - type: android-assemble
    name: android-assemble
    tasks: [assembleDebug]
  - type: android-unit-test
    name: android-unit
    tasks: [testDebugUnitTest]
  - type: android-instrumented-test
    name: android-connected
    tasks: [connectedDebugAndroidTest]
    phases: [ci]
    timeout_minutes: 45
```

## Worker SDK baseline

The worker image installs a pinned Linux Android SDK baseline under
`/opt/android-sdk`: Android command-line tools, platform-tools, emulator,
`platforms;android-36`, `build-tools;36.0.0`, and accepted SDK licenses.
`ANDROID_HOME` and `ANDROID_SDK_ROOT` point at that shared SDK. The plugin's
step environment keeps mutable Android user state in the current workflow
workspace:

```text
ANDROID_USER_HOME=<workspace>/.syrus/android
ANDROID_PREFS_ROOT=<workspace>/.syrus/android
ANDROID_AVD_HOME=<workspace>/.syrus/android/avd
```

Do not use this plugin to choose JDKs, Gradle versions, Maven, or Kotlin/JVM
settings. Those remain Java/Kotlin plugin and repository-wrapper concerns.

## Toolchain diagnostic

`Android::ToolchainDiagnostic.call` returns a hash suitable for Android grader
and runtime-provider checks. It reports:

- SDK root env and whether the SDK directory exists.
- Installed package readiness for command-line tools, platform-tools, emulator,
  the selected platform SDK, and selected build-tools.
- Accepted-license presence.
- `sdkmanager`, `avdmanager`, `adb`, `emulator`, `java`, `javac`, and `gradle`
  command availability and version summaries.
- JVM facts read through Java support, including the shared `.java-version`
  convention.
- Emulator runtime prerequisites: `/dev/kvm` existence/read/write access, CPU
  virtualization flags, and `emulator -accel-check` output when the emulator
  command is available.

Missing commands or emulator acceleration failures are reported in the payload
rather than raised as plugin load errors. Android typed graders and runtime
providers should use that diagnostic to produce actionable failure messages.

## Emulator host and container prerequisites

SDK install alone is enough for local unit tests, lint, APK/AAB assembly, and
other non-emulator Gradle tasks. Emulator-backed graders and Runtime Sessions
also require host and container support:

- The Linux host must expose hardware virtualization (`vmx` or `svm`) and KVM.
- The worker container must be allowed to access `/dev/kvm` with read/write
  permissions. In Docker Compose that usually means adding a worker device
  mapping such as `/dev/kvm:/dev/kvm`. In Kubernetes it usually means a node
  with KVM plus a runtime class, device plugin, or security policy that exposes
  `/dev/kvm` to the worker pod.
- Nested virtualization must be enabled when the host itself is a VM.
- The container must have enough memory and disk for emulator system images,
  snapshots, and Gradle output.

When these prerequisites are absent, Android builds that do not launch an
emulator can still pass. Emulator-backed work usually fails with messages such
as `x86 emulation currently requires hardware acceleration`, `KVM is required
to run this AVD`, `/dev/kvm: Permission denied`, or an
`emulator -accel-check` diagnostic reporting unavailable acceleration.

## Runtime Sessions

Coding Mode can start a live Android emulator with provider
`android_emulator`. The provider keeps SDK installation global but runtime
state local to the workspace:

- AVD/user state lives under `.syrus/android`.
- Session metadata records the AVD name, emulator serial, process id, and
  emulator log path for debugging.
- Missing `adb`/`emulator`/`avdmanager`, unavailable KVM or accelerator support,
  AVD creation failures, boot timeouts, install failures, frame refresh
  failures, and app launch failures are surfaced as Runtime Session errors.

The generic Runtime Session tools and Runtime panel drive the provider:

- `runtime_start` creates or reuses an AVD, starts the emulator, and waits for
  `sys.boot_completed`.
- `runtime_build_or_reload` runs a Gradle task, defaulting to `assembleDebug`,
  finds the newest APK under Android Gradle output directories, and installs it
  with `adb install -r`.
- `runtime_launch` starts an explicit package/activity with `am start`, or a
  package launcher intent with `monkey`.
- `runtime_snapshot` captures `adb exec-out screencap -p`, files the PNG as
  chat media, and stamps `latest_frame_url`/`latest_frame_at` so the standard
  visual Runtime UI can render the frame. When a refresh fails after a previous
  frame exists, the provider returns the stale latest-frame fallback and the
  refresh warning.
- `runtime_inspect` returns the `uiautomator` XML hierarchy.
- `runtime_input` requires the normal Runtime Control Lease before translating
  touch/pointer taps and swipes, keyboard/device buttons, and text input to
  `adb shell input`.
- `runtime_logs` pages `adb logcat -d -v time`.
- `runtime_stop` asks the emulator to exit and terminates the remembered
  process. Sessions can opt into AVD deletion on stop through metadata.

Android runtime evidence uses the same provider-neutral Runtime Session shape
as other visual providers:

- Snapshots and `runtime_capture_artifact` return `kind: android_screenshot`,
  `content_type: image/png`, the captured byte count, the chat-media
  `document_id`, stable `file_path`/`preview_url` media links,
  `latest_frame_url`, and `latest_frame_at`. The stable media links are what
  historical chat tool cards render for the captured artifact; the latest-frame
  URL is the standard mutable Runtime Session frame endpoint for the live
  Runtime panel.
- Latest-frame metadata is stamped on the `RuntimeSession`, including frame
  dimensions when the PNG header can be read. Pointer input can use normalized
  coordinates from the visual panel, which the provider scales back to the
  captured Android frame dimensions.
- Logs return `{ entries, cursor }` from `adb logcat -d -v time`, matching the
  generic paged Runtime log card shape.
- Input returns `{ delivered: true, event }` on success or provider-neutral
  error codes such as `lease_required`, `unsupported_input`, and
  `input_failed`.
- Structural inspection currently supports only the Android UIAutomator
  hierarchy (`kind: android_uiautomator`, `xml`, `bytes`). DOM inspection,
  browser accessibility snapshots, and other browser-only inspection modes are
  intentionally unsupported by this provider; callers should treat the
  provider capability metadata as the source of available modes.

## Future Android-owned work

Android-specific follow-up work should stay inside this plugin wherever
possible:

- Android lint typed graders and richer APK/AAB artifact display.
- Richer app/package discovery for projects whose manifests omit the package
  because it is supplied by the Android Gradle Plugin namespace.
