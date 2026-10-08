require "android/gradle_grader_type"

module Android
  class InstrumentedTestGraderType < GradleGraderType
    DEFAULT_TIMEOUT_MINUTES = 45

    def self.type_name
      "android-instrumented-test"
    end

    private

    def default_name = "android-instrumented-test"
    def default_display_name = "Android instrumented tests"
    def grader_mode = "instrumented_test"
    def default_tasks = [ "connectedDebugAndroidTest" ]

    def default_report_paths
      [
        "build/outputs/androidTest-results/connected",
        "*/build/outputs/androidTest-results/connected",
        "build/outputs/androidTest-results/connected/*",
        "*/build/outputs/androidTest-results/connected/*"
      ]
    end

    def default_artifact_paths
      [
        "build/outputs/androidTest-results/connected",
        "*/build/outputs/androidTest-results/connected",
        "build/reports/androidTests/connected",
        "*/build/reports/androidTests/connected"
      ]
    end

    def default_log_paths
      [
        "build/reports/androidTests/connected",
        "*/build/reports/androidTests/connected"
      ]
    end
  end
end
