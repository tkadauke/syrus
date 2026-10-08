require "java/jvm_test_grader_type"

module Java
  class MavenGraderType < JvmTestGraderType
    def self.type_name
      "maven"
    end

    private

    def framework
      "maven"
    end

    def default_name
      "maven-test"
    end

    def default_display_name
      "Maven tests"
    end

    def test_command
      "if [ -x ./mvnw ]; then ./mvnw -B #{Shellwords.join(goals)}; else mvn -B #{Shellwords.join(goals)}; fi"
    end

    def goals
      shell_array(config["goals"] || config["goal"]).presence || [ "test" ]
    end

    def default_report_paths
      [
        "target/surefire-reports",
        "target/failsafe-reports",
        "*/target/surefire-reports",
        "*/target/failsafe-reports"
      ]
    end
  end
end
