# Kotlin

The `kotlin` plugin (`plugins/kotlin/`) provides Kotlin/JVM language awareness
for services, CLIs, libraries, and mixed-language repositories with Kotlin
components. It is default-ON, disableable, category `language`, depends on the
`java` plugin, and uses `prepare_priority: 46` so Java's generic JVM detection
remains the shared build-tool layer.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects `.kt`, `.kts`, `build.gradle.kts`, `settings.gradle.kts`, Kotlin JVM Gradle plugin declarations, and conventional Kotlin source/test paths (`src/main/kotlin`, `src/test/kotlin`). It delegates concrete prepare commands to `Java::PrepareDetector`, so Gradle and Maven wrapper behavior stays centralized in the Java plugin. Android, Kotlin Android, Kotlin Multiplatform, and Kotlin native markers are intentionally skipped. |
| `:prompt_injector` | Adds Kotlin/JVM guidance for implementation agents: prefer project Gradle wrappers, respect repository-declared JDK and Kotlin Gradle plugin versions, and keep Android/KMP/native behavior out of the generic Kotlin path. |
| `:review_criteria_provider` | Adds Kotlin/JVM review criteria for swallowed coroutine cancellation and unsafe null assertions at external boundaries. |

## Prepare behavior

Kotlin does not add a second Gradle or Maven command implementation. When a
Kotlin/JVM project is detected, `Kotlin::PrepareDetector.prepare_commands`
returns the Java plugin's wrapper-aware prepare commands:

- Gradle: `./gradlew --no-daemon testClasses` when `gradlew` is present,
  otherwise `gradle --no-daemon testClasses`.
- Maven: `./mvnw -B test-compile` when `mvnw` is present, otherwise
  `mvn -B test-compile`.

Kotlin source-only layouts are detected for suggestions and review guidance,
but they do not invent a prepare command without a Gradle or Maven signal.

## Typed graders

Kotlin/JVM projects use the Java plugin's `type: gradle` typed grader:

```yaml
grade:
  - type: gradle
    tasks: [test]
```

The shared Java/JVM grader scope includes Kotlin source and script files:
`**/*.kt`, `**/*.kts`, `src/main/kotlin/**/*`, and `src/test/kotlin/**/*`.
The generated command still prefers `./gradlew` and aggregates standard Gradle
JUnit XML reports into one Syrus `junit_output` file.

### Mixed Java/Kotlin monorepo example

Place this in the JVM project's nested `.syrus.yml`:

```yaml
project:
  id: billing-api
  label: Billing API
  kind: service

grade:
  - type: gradle
    name: billing-tests
    tasks: [test]
    when_files_changed:
      - "src/main/java/**/*"
      - "src/main/kotlin/**/*"
      - "src/test/java/**/*"
      - "src/test/kotlin/**/*"
      - "src/main/resources/**/*"
      - "src/test/resources/**/*"
      - "build.gradle.kts"
      - "settings.gradle.kts"
      - "gradle/**/*"
      - "gradlew"
```

## Boundary with Android and Kotlin Multiplatform

Kotlin owns generic JVM language conventions only. Kotlin Multiplatform,
native/iOS targets, Android Gradle Plugin behavior, Kotlin Android plugin
behavior, Android SDK setup, emulator/device requirements, and Android runtime
concerns are intentionally out of scope for this first pass. Those projects
need Android or platform-specific plugins so SDK/device assumptions do not
leak into generic Kotlin/JVM work.

## Self-suggestion

`suggests_enabling` nudges an admin who has not enabled `kotlin` yet when
`signals.repositories_detecting("kotlin")` reports repositories whose file
layout matched the plugin's own detector.
