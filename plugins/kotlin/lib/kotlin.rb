require "java"
require "kotlin/prepare_detector"
require "kotlin/prompt_context"
require "kotlin/review_criteria_provider"

module Kotlin
  extend Syrus::PluginApi

  syrus_plugin "kotlin" do
    experimental true
    description "Kotlin/JVM intelligence: Kotlin source and Gradle Kotlin DSL detection, JVM prepare reuse, and Kotlin-aware review guidance"
    long_description "Kotlin layers Kotlin/JVM language awareness on top of the generic Java plugin. It detects Kotlin source files, Kotlin scripts, Gradle Kotlin DSL files, Kotlin JVM Gradle plugin declarations, and conventional Kotlin source/test layouts, while reusing Java's Gradle/JUnit grader machinery and JDK guidance.\n\nUse it for Kotlin/JVM services, CLIs, libraries, and mixed-language repositories with Kotlin components. Kotlin Multiplatform, native/iOS targets, Android Gradle Plugin behavior, Android SDK setup, emulators, and devices are intentionally outside this first pass."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/kotlin.svg"
    author "Thomas Kadauke"
    category "language"
    depends_on [ "java" ]
    prepare_priority 46

    suggests_enabling "Kotlin/JVM repositories get Kotlin source detection, Gradle Kotlin DSL guidance, and Java Gradle/JUnit grader reuse." do |signals|
      signals.repositories_detecting("kotlin")
    end

    provides prepare_detector: "Kotlin::PrepareDetector",
             prompt_injector: "Kotlin::PromptContext",
             review_criteria_provider: "Kotlin::ReviewCriteriaProvider"
  end
end
