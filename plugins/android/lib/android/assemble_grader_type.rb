require "android/gradle_grader_type"

module Android
  class AssembleGraderType < GradleGraderType
    DEFAULT_TIMEOUT_MINUTES = 30

    def self.type_name
      "android-assemble"
    end

    private

    def default_name = "android-assemble"
    def default_display_name = "Android assemble"
    def grader_mode = "assemble"
    def default_tasks = [ "assembleDebug" ]

    def default_artifact_paths
      [
        "build/outputs/apk",
        "*/build/outputs/apk",
        "build/outputs/bundle",
        "*/build/outputs/bundle",
        "build/outputs/mapping",
        "*/build/outputs/mapping"
      ]
    end

    def default_log_paths
      [
        "build/reports",
        "*/build/reports"
      ]
    end
  end
end
