require "java/jvm_test_grader_type"

module Java
  class GradleGraderType < JvmTestGraderType
    def self.type_name
      "gradle"
    end

    private

    def framework
      "gradle"
    end

    def default_name
      "gradle-test"
    end

    def default_display_name
      "Gradle tests"
    end

    def test_command
      "if [ -x ./gradlew ]; then ./gradlew --no-daemon #{Shellwords.join(tasks)}; else gradle --no-daemon #{Shellwords.join(tasks)}; fi"
    end

    def tasks
      shell_array(config["tasks"] || config["task"]).presence || [ "test" ]
    end

    def default_report_paths
      [
        "build/test-results/test",
        "*/build/test-results/test",
        "build/test-results/*",
        "*/build/test-results/*"
      ]
    end
  end
end
