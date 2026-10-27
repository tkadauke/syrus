# java

`java` is a Syrus plugin gem that bundles generic Java/JVM intelligence into a
single plugin registration. It lives at `plugins/java/` inside the Syrus
repository and applies to Java services, CLIs, libraries, and mixed-language
repositories with JVM components.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects Gradle files (`build.gradle`, `build.gradle.kts`, `settings.gradle`, `settings.gradle.kts`, `gradlew`), Maven files (`pom.xml`, `mvnw`, `.mvn/wrapper/maven-wrapper.properties`), and conventional Java source/test paths (`src/main/java`, `src/test/java`). Gradle projects prepare with `./gradlew --no-daemon testClasses` when the wrapper is present, otherwise `gradle --no-daemon testClasses`. Maven projects prepare with `./mvnw -B test-compile` when the wrapper is present, otherwise `mvn -B test-compile`. Source-only Java layouts are detectable but do not add a prepare command. |
| `:grader_type` | Expands `type: gradle` and `type: maven` into wrapper-aware test graders. Gradle defaults to `test`; Maven defaults to `test`. Both aggregate standard JUnit XML report directories into one Syrus `junit_output` file when reports exist. |
| `:prompt_injector` | Reminds agents to prefer project wrappers and the repository-declared JDK version instead of assuming the system JDK is correct. |
| `:review_criteria_provider` | Seeds a default adversarial-review checklist item — "Flag swallowed InterruptedException without restoring interrupt status" — when a generic Java/JVM signal is present. |

## Typed grader examples

Java library using Gradle:

```yaml
grade:
  - type: gradle
    tasks: [test]
```

Java service using Maven:

```yaml
grade:
  - type: maven
    goals: [verify]
```

Mixed-language monorepo with a nested JVM project:

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
      - "src/test/java/**/*"
      - "build.gradle.kts"
      - "gradle/**/*"
      - "gradlew"
```

## Boundary

This plugin owns generic JVM build/test conventions: JDK selection, Gradle and
Maven wrapper usage, and conventional Java source layouts. It does not exclude
mobile-platform Gradle layouts any more -- a Gradle project is just a Gradle
project. Platform-specific SDK, device, and runtime concerns belong in a plugin
that also ships a worker advertising the matching capability.

## Loading the plugin

The plugin registers itself via a Rails engine `to_prepare` hook once
`gem "java", path: "plugins/java"` is bundled — no manual registration call
is needed.

## Running tests

From the repo root:

```sh
bin/rspec plugins/java/spec
```
