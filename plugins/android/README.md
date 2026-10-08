# android

`android` is a bundled Syrus plugin gem for Android project awareness. It
layers on top of the generic `java` and `kotlin` plugins instead of replacing
them: Java/Kotlin own JDK, Gradle, Maven, wrapper, and Kotlin/JVM conventions;
Android owns Android Gradle Plugin, Android SDK, emulator/device, mobile
runtime, and APK/AAB artifact behavior.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects Android Gradle Plugin declarations, Android Kotlin plugin declarations, Android Gradle buildscript classpath entries, and conventional `AndroidManifest.xml` layouts. It intentionally returns no prepare command, so it can safely identify repositories without inventing project-specific Android Gradle work. |
| `:step_environment` | Forwards `ANDROID_HOME`/`ANDROID_SDK_ROOT` from the worker image and scopes mutable Android user and AVD state to `.syrus/android` inside each workflow workspace. |
| `:grader_type` | Expands Android Gradle typed graders for assemble, local unit tests, connected instrumented tests, and Gradle Managed Devices. Generated graders declare Linux execution capabilities and record Android report, package, managed-device, and log paths. |
| `:runtime_session_provider` | Adds the `android_emulator` Runtime Session provider for Coding Mode emulator viewing and control through the standard Runtime UI. |
| `:prompt_injector` | Reminds agents that Android runs on Linux execution capabilities, uses Java/Kotlin for generic JVM conventions, and should use the provider-neutral Runtime Session visual frame/input path for live emulator viewing and control. |
| `:review_criteria_provider` | Adds Android-specific adversarial-review checks for worker capabilities, mobile artifact handling, and runtime input/viewing boundaries. |

## Boundaries

Android uses Linux workers. Syrus does not model Android as `os: android`;
Android SDK installation, Gradle Managed Devices, emulators, physical devices,
APK/AAB packaging, and signing are platform concerns owned by this plugin and
future Android-specific providers.

Generic Java and Kotlin support remain in their plugins. Android repositories
can still use Java/Kotlin source, Gradle wrappers, and JVM metadata, but
Android Gradle Plugin behavior is not claimed by generic JVM detectors.

## Typed graders

Use the Android types in `.syrus.yml` for common Gradle workflows:

```yaml
grade:
  - type: android-assemble
    tasks: [assembleDebug]
  - type: android-unit-test
    tasks: [testDebugUnitTest]
  - type: android-instrumented-test
    tasks: [connectedDebugAndroidTest]
    phases: [ci]
  - type: android-managed-device
    tasks: [allDevicesCheck]
    phases: [landing, ci]
    timeout_minutes: 60
```

`android-managed-device` can also derive tasks from configured devices:

```yaml
grade:
  - type: android-managed-device
    devices: [pixel2api30]
    variant: debug
```

Graders prefer `./gradlew`, fall back to `gradle`, declare `os: linux`, and
aggregate Android/JUnit XML reports when those reports are present.

The shared worker image provides the Android SDK baseline at `/opt/android-sdk`
with command-line tools, platform-tools, emulator, `platforms;android-36`,
`build-tools;36.0.0`, and accepted licenses. `Android::ToolchainDiagnostic.call`
reports SDK packages, command availability, license state, `adb`/emulator
readiness, `/dev/kvm` access, acceleration checks, and Java/Gradle facts read
from JVM support. It reports missing pieces in its payload instead of raising
so graders and runtime providers can render precise operator-facing failures.

Live emulator viewing and control should use Runtime Sessions' visual frame
and input contract. The bundled `android_emulator` provider implements the
generic runtime provider interface and feeds frames/input through that path
rather than adding Android-only UI plumbing.

## Runtime Sessions

Coding Mode can start an Android Runtime Session with provider
`android_emulator`. The provider uses Android SDK tools from the worker
environment, stores mutable AVD/user state under `.syrus/android` in the
workspace, and records emulator metadata such as AVD name, serial, process id,
and emulator log path on the `RuntimeSession`.

Supported operations:

- `runtime_start`: creates or reuses an AVD, starts the emulator, waits for
  `sys.boot_completed`, and reports missing SDK tools, missing KVM/accelerator
  access, AVD creation failures, and boot timeouts as Runtime Session errors.
- `runtime_build_or_reload`: runs a Gradle task (default `assembleDebug`),
  finds the newest APK under Android Gradle output directories, and installs it
  with `adb install -r`.
- `runtime_launch`: launches an explicit package/activity with `am start`, or a
  package launcher intent with `monkey`.
- `runtime_snapshot` and Runtime panel capture: run `adb exec-out screencap -p`,
  file the PNG as chat media, and update `latest_frame_url`/`latest_frame_at`.
  If refresh fails after a previous frame exists, the provider returns the
  latest-frame fallback with the refresh warning.
- `runtime_inspect`: returns the `uiautomator` XML hierarchy.
- `runtime_input`: requires the normal Runtime Control Lease and translates
  touch/pointer taps and swipes, keyboard/device buttons, and text input to
  `adb shell input`.
- `runtime_logs`: pages `adb logcat -d -v time`.
- `runtime_stop`: asks the emulator to exit and terminates the remembered
  process; sessions can opt into AVD deletion on stop through metadata.

## Loading the plugin

The plugin registers itself via a Rails engine `to_prepare` hook once
`gem "android", path: "plugins/android"` is bundled. It depends on the bundled
`java` and `kotlin` plugins so JVM conventions stay available when Android is
enabled.

## Running tests

From the repo root:

```sh
bin/rspec plugins/android/spec spec/dockerfile_spec.rb spec/plugins/plugin_manifest_metadata_spec.rb spec/lib/syrus/plugin/category_spec.rb
```
