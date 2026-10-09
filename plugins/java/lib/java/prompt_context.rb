module Java
  # Light :prompt_injector for generic JVM projects. It keeps agents pointed at
  # project-owned wrappers while leaving mobile SDK/device concerns to
  # platform-specific plugins.
  class PromptContext
    PROMPT = <<~TEXT.freeze
      This repository may be a Java or generic JVM project. Prefer project
      wrappers (`./gradlew`, `./mvnw`) when present, and use the repository's
      declared JDK version (`.java-version`, Gradle toolchains, or Maven
      compiler settings) instead of assuming the system JDK is correct.
      Mobile platform Gradle plugins, SDKs, emulators, devices, and runtime
      behavior belong to platform-specific project support rather than generic
      Java handling.
    TEXT

    def self.call(repository:, job:)
      new.call(repository: repository, job: job)
    end

    def call(repository:, job:)
      PROMPT
    end
  end
end
