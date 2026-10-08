# kotlin

`kotlin` is a Syrus plugin gem that layers Kotlin/JVM language awareness on top
of the generic Java plugin. It lives at `plugins/kotlin/` inside the Syrus
repository and applies to Kotlin/JVM services, CLIs, libraries, and
mixed-language repositories with Kotlin components.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects Kotlin source files (`.kt`), Kotlin scripts (`.kts`), Gradle Kotlin DSL files (`build.gradle.kts`, `settings.gradle.kts`), Kotlin JVM Gradle plugin declarations, and conventional Kotlin source/test paths (`src/main/kotlin`, `src/test/kotlin`). It depends on the Java plugin and reuses Java's Gradle/Maven prepare commands instead of duplicating build-tool command logic. |
| `:prompt_injector` | Reminds agents to treat Kotlin paths and Gradle Kotlin DSL files as JVM project signals, prefer `./gradlew`, and use repository-declared JDK/Kotlin Gradle plugin versions. |
| `:review_criteria_provider` | Adds Kotlin/JVM review criteria for swallowed coroutine cancellation and unsafe null assertions at external boundaries. |

## Typed grader examples

Kotlin/JVM projects use the Java plugin's Gradle typed grader:

```yaml
grade:
  - type: gradle
    tasks: [test]
```

Mixed Java/Kotlin monorepo with a nested JVM project:

```yaml
project:
  id: api
  label: API service
  kind: service

grade:
  - type: gradle
    name: api-tests
    tasks: [test]
    when_files_changed:
      - "src/main/java/**/*"
      - "src/main/kotlin/**/*"
      - "src/test/java/**/*"
      - "src/test/kotlin/**/*"
      - "build.gradle.kts"
      - "settings.gradle.kts"
      - "gradle/**/*"
      - "gradlew"
```

## Boundary with Android and Kotlin Multiplatform

This plugin owns only generic Kotlin/JVM conventions: Kotlin source-layout
detection, Gradle Kotlin DSL signals, Kotlin JVM plugin detection, and reuse of
Java's JVM prepare/grader machinery. Kotlin Multiplatform, native/iOS targets,
Android Gradle Plugin behavior, Android SDK setup, emulator/device
requirements, and Android runtime concerns are intentionally out of scope.

## Loading the plugin

The plugin registers itself via a Rails engine `to_prepare` hook once
`gem "kotlin", path: "plugins/kotlin"` is bundled. It depends on the bundled
`java` plugin.

## Running tests

From the repo root:

```sh
bin/rspec plugins/kotlin/spec plugins/java/spec/gradle_grader_type_spec.rb
```
