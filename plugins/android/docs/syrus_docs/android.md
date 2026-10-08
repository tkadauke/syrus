# Android

The `android` plugin (`plugins/android/`) provides Android project awareness
on top of the generic Java/Kotlin foundation. It is default-ON, disableable,
category `platform_delivery`, `prepare_priority: 47`, and depends on `java`
and `kotlin`.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects Android Gradle Plugin declarations (`com.android.application`, `com.android.library`, `com.android.test`, dynamic feature and asset-pack plugins), Android Kotlin plugin declarations, `com.android.tools.build:gradle` buildscript classpath entries, and conventional `AndroidManifest.xml` paths. It returns no prepare command in this scaffold so generic Linux workers do not run SDK/emulator work before Android worker capabilities exist. It reuses `.java-version` as the JVM version file and adds Android Gradle, `adb`, emulator, `sdkmanager`, and `avdmanager` command-span labels for worker-health diagnostics. |
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

Interactive Android support should be a Runtime Session provider. The provider
should implement the existing `:runtime_session_provider` interface and publish
frames and input through Syrus's provider-neutral visual Runtime path, the same
operator/agent control path used by other visual providers. Android should not
add separate emulator-only UI plumbing for live viewing or input.

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

The detector intentionally returns `[]` from `prepare_commands`. That keeps
the scaffold safe on generic workers while still letting RepoPluginDetector,
Admin -> Plugins suggestions, prompt context, review criteria, and future
Android-specific typed graders/providers recognize the repository.

## Future Android-owned work

Android-specific follow-up work should stay inside this plugin wherever
possible:

- Android Gradle Plugin typed graders, including unit-test, lint, assemble,
  connected-test, and Gradle Managed Device conventions.
- Android SDK and emulator/device capability checks for Linux workers.
- APK/AAB artifact discovery and display.
- A runtime provider that launches an emulator/device session and feeds visual
  frames plus touch/key/text input through the generic Runtime Session
  contract.
