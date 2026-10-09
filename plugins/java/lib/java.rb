require "java/prepare_detector"
require "java/prompt_context"
require "java/review_criteria_provider"
require "java/gradle_grader_type"
require "java/maven_grader_type"

module Java
  extend Syrus::PluginApi

  syrus_plugin "java" do
    experimental true
    description "Java/JVM-generic intelligence: Gradle/Maven wrapper-aware prepare and grader detection, JDK prompt guidance, and JVM review criteria"
    long_description "Java provides language-level support for generic JVM repositories. It detects Maven, Gradle, wrapper scripts, and conventional Java source layouts, prepares Gradle and Maven projects with wrapper-aware commands, expands Gradle/Maven typed graders, and reminds agents to prefer project-owned build tooling.\n\nUse it for Java services, CLIs, libraries, and mixed-language repositories with generic JVM components. Android-specific Gradle Plugin, SDK, emulator, device, and runtime behavior belong in the Android plugin so generic Java support stays portable."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/java.svg"
    author "Thomas Kadauke"
    category "language"
    prepare_priority 45

    suggests_enabling "Java/JVM repositories get Gradle and Maven prepare/grader support with wrapper-aware commands and generic JDK guidance." do |signals|
      signals.repositories_detecting("java")
    end

    provides prepare_detector: "Java::PrepareDetector",
             prompt_injector: "Java::PromptContext",
             review_criteria_provider: "Java::ReviewCriteriaProvider",
             grader_type: [ "Java::GradleGraderType", "Java::MavenGraderType" ]
  end
end
