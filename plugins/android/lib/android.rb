require "java"
require "kotlin"
require "android/prepare_detector"
require "android/prompt_context"
require "android/review_criteria_provider"
require "android/step_environment"
require "android/toolchain_diagnostic"
require "android/emulator_runtime_session_provider"
require "android/gradle_grader_type"
require "android/assemble_grader_type"
require "android/unit_test_grader_type"
require "android/instrumented_test_grader_type"
require "android/managed_device_grader_type"

module Android
  extend Syrus::PluginApi

  syrus_plugin "android" do
    experimental true
    display_name "Android"
    description "Android project intelligence: Android Gradle Plugin detection, SDK environment wiring, " \
                "toolchain diagnostics, Android/JVM prompt guidance, and mobile review criteria"
    long_description "Android layers mobile-platform awareness on top of the bundled Java and Kotlin plugins. " \
                     "It detects Android Gradle Plugin and AndroidManifest layouts, keeps generic " \
                     "JDK/Gradle/Kotlin conventions delegated to Java and Kotlin, and draws the boundary for " \
                     "Android SDK, emulator, device, runtime, and mobile artifact behavior.\n\nAndroid work " \
                     "runs on Linux execution capabilities. Live emulator viewing and control should use " \
                     "Syrus's provider-neutral Runtime Session visual frame and input path rather than " \
                     "Android-specific UI plumbing."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/android.svg"
    author "Thomas Kadauke"
    category "platform_delivery"
    depends_on [ "java", "kotlin" ]
    prepare_priority 47

    suggests_enabling "Android repositories get Android Gradle Plugin detection and Android-specific SDK, " \
                      "emulator, artifact, and runtime guidance layered on JVM support." do |signals|
      signals.repositories_detecting("android")
    end

    provides prepare_detector: "Android::PrepareDetector",
             prompt_injector: "Android::PromptContext",
             review_criteria_provider: "Android::ReviewCriteriaProvider",
             step_environment: "Android::StepEnvironment",
             runtime_session_provider: "Android::EmulatorRuntimeSessionProvider",
             grader_type: [
               "Android::AssembleGraderType",
               "Android::UnitTestGraderType",
               "Android::InstrumentedTestGraderType",
               "Android::ManagedDeviceGraderType"
             ]
  end
end
