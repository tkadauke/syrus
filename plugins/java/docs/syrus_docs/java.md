# Java

The `java` plugin (`plugins/java/`) provides generic Java/JVM intelligence for
services, CLIs, libraries, and mixed-language repositories with JVM components.
It is default-ON, disableable, category `language`, `prepare_priority: 45`.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects Gradle files (`build.gradle`, `build.gradle.kts`, `settings.gradle`, `settings.gradle.kts`, `gradlew`), Maven files (`pom.xml`, `mvnw`, `.mvn/wrapper/maven-wrapper.properties`), and conventional Java source/test paths (`src/main/java`, `src/test/java`). Gradle wins when both Gradle and Maven signals are present. Wrapper commands are preferred over system tools. Source-only Java layouts are detectable but do not add a prepare command. Also declares `.java-version` as the `mise` version file and labels common Gradle, Maven, `java -version`, and `javac` command spans for worker-health diagnostics. |
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

## Boundary with Android

Java owns generic JVM conventions: JDK selection, Maven, Gradle, wrapper
usage, and source-layout detection. Android owns Android Gradle Plugin,
Android SDK setup, emulator/device requirements, APK/runtime behavior, and
other mobile-platform concerns. Keep Android-specific preparation or review
guidance out of this generic plugin.

## Self-suggestion

`suggests_enabling` nudges an admin who has not enabled `java` yet when
`signals.repositories_detecting("java")` reports repositories whose file
layout matched the plugin's own detector.

## What this plugin intentionally does NOT provide

No Android prepare or runtime handling. A Gradle project can be a plain JVM
project or an Android project; Android-specific behavior needs the Android
plugin so SDK and device assumptions do not leak into generic Java work.

No custom `:preview_provider`. Java has no single language-level server
convention; Spring Boot, Dropwizard, Quarkus, Micronaut, and command-line apps
all differ. Repositories that need previews should declare an explicit
`.syrus.yml` preview command or use a framework-specific plugin.
