module Android
  # Light :prompt_injector for Android repositories. It keeps agents on the
  # shared JVM foundation while naming Android's platform-specific boundary.
  class PromptContext
    PROMPT = <<~TEXT.freeze
      This repository may be an Android project. Treat Android Gradle Plugin
      declarations, AndroidManifest.xml, app/library modules, Android SDK
      setup, emulators, devices, APK/AAB artifacts, and mobile runtime behavior
      as Android-specific concerns layered on top of Java/Kotlin/JVM support.
      Prefer project Gradle wrappers and repository-declared JDK/Kotlin
      versions. Android implementation and emulator work use Linux execution
      capabilities; do not invent an `os: android` target. Live emulator
      viewing and input should go through Syrus Runtime Sessions' generic
      visual frame and input contract rather than Android-specific UI plumbing.
    TEXT

    def self.call(repository:, job:)
      new.call(repository: repository, job: job)
    end

    def call(repository:, job:)
      PROMPT
    end
  end
end
