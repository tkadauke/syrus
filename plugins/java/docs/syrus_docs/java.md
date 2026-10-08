# Java

The `java` plugin (`plugins/java/`) provides generic Java/JVM intelligence for
services, CLIs, libraries, and mixed-language repositories with JVM components.
It is default-ON, disableable, category `language`, `prepare_priority: 45`.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects Gradle files (`build.gradle`, `build.gradle.kts`, `settings.gradle`, `settings.gradle.kts`, `gradlew`), Maven files (`pom.xml`, `mvnw`, `.mvn/wrapper/maven-wrapper.properties`), and conventional Java source/test paths (`src/main/java`, `src/test/java`). Gradle wins when both Gradle and Maven signals are present. Wrapper commands are preferred over system tools. Source-only Java layouts are detectable but do not add a prepare command. Android Gradle Plugin projects are intentionally not claimed by this generic detector. Also declares `.java-version` as the `mise` version file and labels common Gradle, Maven, `java -version`, and `javac` command spans for worker-health diagnostics. |
| `:grader_type` | Expands `type: gradle` and `type: maven` into wrapper-aware test graders with Java/JVM file scopes, framework/mode metadata, and single-file JUnit aggregation for standard Gradle/Maven XML report directories. |
| `:prompt_injector` | Reminds implementing agents to use project wrappers and repository-declared JDK versions instead of assuming the system JDK is correct. It also documents that Android-specific SDK, emulator, device, and runtime concerns are outside the generic Java boundary. |
| `:review_criteria_provider` | Seeds a default adversarial-review checklist item — "Flag swallowed InterruptedException without restoring interrupt status" — when a generic Java/JVM signal is present. |

## Prepare behavior

Gradle projects run:

```sh
./gradlew --no-daemon testClasses
```

when `gradlew` is present, otherwise:

```sh
gradle --no-daemon testClasses
```

Maven projects run:

```sh
./mvnw -B test-compile
```

when `mvnw` is present, otherwise:

```sh
mvn -B test-compile
```

The commands resolve and compile main/test dependencies without running the
test suite. Repositories with only `src/main/java` or `src/test/java` are still
recognized for suggestions and review guidance, but Syrus does not invent a
build command without a Gradle or Maven signal.

## Typed graders

Gradle projects can use:

```yaml
grade:
  - type: gradle
```

The generated grader runs `./gradlew --no-daemon test` when `gradlew` is
executable, otherwise `gradle --no-daemon test`. Set `task:` or `tasks:` to
override the Gradle tasks:

```yaml
grade:
  - type: gradle
    name: gradle-check
    tasks: [clean, check]
```

Maven projects can use:

```yaml
grade:
  - type: maven
```

The generated grader runs `./mvnw -B test` when `mvnw` is executable,
otherwise `mvn -B test`. Set `goal:` or `goals:` to override the Maven goals:

```yaml
grade:
  - type: maven
    name: maven-verify
    goals: [clean, verify]
```

Both typed graders default `when_files_changed` to Java/JVM source, test,
resource, Gradle, Maven, and wrapper paths. Override `when_files_changed` when
a monorepo project needs a narrower scope. The generated metadata identifies
`grader_type`, `grader_framework`, `grader_mode`, result outputs, and filter
capabilities consistently with other language plugin typed graders.

Gradle and Maven normally write one JUnit XML file per suite. Syrus ingests one
`junit_output` path per grader, so the Java typed graders aggregate standard
report locations into `.syrus/grade-output/<name>-junit.xml` when XML files are
present:

- Gradle: `build/test-results/test`, `*/build/test-results/test`,
  `build/test-results/*`, and `*/build/test-results/*`.
- Maven: `target/surefire-reports`, `target/failsafe-reports`,
  `*/target/surefire-reports`, and `*/target/failsafe-reports`.

Use `report_paths:` (or `junit_paths:` / `junit_report_paths:`) to change the
directories scanned for XML reports, `junit_output:` to change the aggregate
artifact path, or `junit_output: false` to disable ingestion.

### Java library example

```yaml
grade:
  - type: gradle
    tasks: [test]
```

### Java service example

```yaml
grade:
  - type: maven
    goals: [verify]
    timeout_minutes: 30
```

### Mixed-language monorepo example

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
      - "src/test/java/**/*"
      - "src/main/resources/**/*"
      - "src/test/resources/**/*"
      - "build.gradle.kts"
      - "settings.gradle.kts"
      - "gradle/**/*"
      - "gradlew"
```

## Boundary with Android

Java owns generic JVM conventions: JDK selection, Maven, Gradle, wrapper
usage, and source-layout detection. Android owns Android Gradle Plugin,
Android SDK setup, emulator/device requirements, APK/runtime behavior, and
other mobile-platform concerns. Repositories with Android Gradle Plugin markers
or conventional Android manifest paths are skipped by this detector so an
Android plugin can handle SDK setup and Android task selection. Keep
Android-specific preparation or review guidance out of this generic plugin.

## Self-suggestion

`suggests_enabling` nudges an admin who has not enabled `java` yet when
`signals.repositories_detecting("java")` reports repositories whose file
layout matched the plugin's own detector.

## What this plugin intentionally does NOT provide

No Android prepare or runtime handling. A Gradle project can be a plain JVM
project or an Android project; Android-specific behavior needs the Android
plugin so SDK and device assumptions do not leak into generic Java work.
Android Gradle Plugin projects are not detected as generic Java projects.

No custom `:preview_provider`. Java has no single language-level server
convention; Spring Boot, Dropwizard, Quarkus, Micronaut, and command-line apps
all differ. Repositories that need previews should declare an explicit
`.syrus.yml` preview command or use a framework-specific plugin.
