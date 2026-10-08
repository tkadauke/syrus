require "android/gradle_grader_type"

module Android
  class UnitTestGraderType < GradleGraderType
    DEFAULT_TIMEOUT_MINUTES = 25

    def self.type_name
      "android-unit-test"
    end

    private

    def default_name = "android-unit-test"
    def default_display_name = "Android unit tests"
    def grader_mode = "unit_test"
    def default_tasks = [ "testDebugUnitTest" ]

    def default_report_paths
      [
        "build/test-results/testDebugUnitTest",
        "*/build/test-results/testDebugUnitTest",
        "build/test-results/test*UnitTest",
        "*/build/test-results/test*UnitTest"
      ]
    end

    def default_log_paths
      [
        "build/reports/tests",
        "*/build/reports/tests"
      ]
    end
  end
end
