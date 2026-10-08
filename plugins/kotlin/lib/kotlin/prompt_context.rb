module Kotlin
  # Light :prompt_injector for Kotlin/JVM repositories. It points agents at
  # JVM/Gradle conventions without claiming Android or Multiplatform behavior.
  class PromptContext
    PROMPT = <<~TEXT.freeze
      This repository may include Kotlin/JVM code. Treat `build.gradle.kts`,
      `settings.gradle.kts`, `src/main/kotlin`, and `src/test/kotlin` as JVM
      project signals, prefer project Gradle wrappers (`./gradlew`) when
      present, and use the repository's declared JDK and Kotlin Gradle plugin
      versions instead of assuming global toolchain versions are correct.
      Kotlin Multiplatform, native/iOS targets, Android Gradle Plugin, Android
      SDK, emulator, device, and runtime behavior are outside generic
      Kotlin/JVM handling.
    TEXT

    def self.call(repository:, job:)
      new.call(repository: repository, job: job)
    end

    def call(repository:, job:)
      PROMPT
    end
  end
end
