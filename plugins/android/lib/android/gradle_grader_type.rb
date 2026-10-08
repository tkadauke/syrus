require "shellwords"

module Android
  class GradleGraderType
    include Syrus::Plugin::GraderType

    DEFAULT_TIMEOUT_MINUTES = 30
    DEFAULT_CHANGED_FILES = [
      "**/*.java",
      "**/*.kt",
      "**/*.kts",
      "src/main/**/*",
      "**/src/main/**/*",
      "src/test/**/*",
      "**/src/test/**/*",
      "src/androidTest/**/*",
      "**/src/androidTest/**/*",
      "AndroidManifest.xml",
      "**/AndroidManifest.xml",
      "build.gradle",
      "**/build.gradle",
      "build.gradle.kts",
      "**/build.gradle.kts",
      "settings.gradle",
      "**/settings.gradle",
      "settings.gradle.kts",
      "**/settings.gradle.kts",
      "gradle.properties",
      "**/gradle.properties",
      "gradle/**/*",
      "**/gradle/**/*",
      "gradlew",
      "**/gradlew",
      "gradlew.bat",
      "**/gradlew.bat"
    ].freeze

    def self.grade_steps(config:, default_failures:)
      new(config: config, default_failures: default_failures).grade_steps
    end

    def initialize(config:, default_failures:)
      @config = config.to_h.stringify_keys
      @default_failures = default_failures
    end

    def grade_steps
      [
        SyrusYml::GradeStep.new(
          name: name,
          display_name: display_name,
          run: command,
          ci: nil,
          phases: phases,
          description: description,
          required: required?,
          timeout_minutes: timeout_minutes,
          when_files_changed: scope,
          junit_output: junit_output,
          failures: failures,
          base_retry: nil,
          deps: deps,
          metadata: metadata,
          capabilities: linux_capabilities
        )
      ]
    end

    private

    attr_reader :config, :default_failures

    def default_name = raise NotImplementedError
    def default_display_name = raise NotImplementedError
    def default_description = "#{default_display_name}."
    def grader_mode = raise NotImplementedError
    def default_tasks = raise NotImplementedError
    def default_report_paths = []
    def default_artifact_paths = []
    def default_log_paths = []

    def linux_capabilities
      ::TargetGraph::ExecutionCapabilities.new(os: "linux")
    end

    def name
      config["name"].to_s.strip.presence || default_name
    end

    def display_name
      config["display_name"].to_s.strip.presence || default_display_name
    end

    def description
      config["description"].to_s.strip.presence || default_description
    end

    def command
      "{ #{run_command}; status=$?; #{junit_aggregation_command}; exit $status; }"
    end

    def run_command
      return gradle_command if project_path.blank?

      "(cd #{Shellwords.escape(project_path)} && #{gradle_command})"
    end

    def gradle_command
      "if [ -x ./gradlew ]; then ./gradlew --no-daemon #{Shellwords.join(tasks)}; else gradle --no-daemon #{Shellwords.join(tasks)}; fi"
    end

    def project_path
      config["_syrus_project_path"].to_s.strip.presence
    end

    def tasks
      configured_tasks.presence || default_tasks
    end

    def configured_tasks
      shell_array(config["tasks"] || config["task"])
    end

    def phases
      raw = config["phases"]
      values =
        case raw
        when nil then SyrusYml::DEFAULT_GRADE_PHASES
        when String then [ raw ]
        else Array(raw)
        end
      values.map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def required?
      return true unless config.key?("required")

      ActiveModel::Type::Boolean.new.cast(config["required"])
    end

    def timeout_minutes
      raw = config["timeout_minutes"].presence
      return self.class::DEFAULT_TIMEOUT_MINUTES if raw.blank?

      minutes = Integer(raw)
      raise ArgumentError, "timeout_minutes must be positive" unless minutes.positive?

      [ minutes, SyrusYml::MAX_GRADE_TIMEOUT_MINUTES ].min
    rescue ArgumentError
      raise ArgumentError, "timeout_minutes must be a positive integer"
    end

    def failures
      config["failures"].to_s.strip.presence || default_failures
    end

    def scope
      patterns = shell_array(config["when_files_changed"])
      patterns.presence || DEFAULT_CHANGED_FILES
    end

    def deps
      shell_array(config["deps"] || config["dependencies"])
    end

    def junit_output
      raw = config.fetch("junit_output", junit_default?)
      return nil if raw == false

      configured = raw == true ? nil : raw.to_s.strip.presence
      configured || ".syrus/grade-output/#{artifact_name(name)}-junit.xml"
    end

    def junit_default?
      default_report_paths.any?
    end

    def metadata
      {
        "grader_type" => self.class.type_name,
        "grader_framework" => "android-gradle",
        "grader_mode" => grader_mode,
        "gradle_tasks" => tasks,
        "result_outputs" => result_outputs,
        "coverage_outputs" => [],
        "artifact_paths" => artifact_paths,
        "log_paths" => log_paths,
        "filter_capabilities" => {
          "changed_files" => false,
          "failed_cases" => junit_output.present?,
          "ci" => phases.include?("ci"),
          "coverage" => false
        }
      }
    end

    def result_outputs
      return [] if junit_output.blank?

      [ { "artifact" => junit_output, "format" => "junit" } ]
    end

    def artifact_paths
      configured = shell_array(config["artifact_paths"] || config["artifacts"])
      (configured.presence || default_artifact_paths).map { |path| project_relative(path) }
    end

    def log_paths
      configured = shell_array(config["log_paths"] || config["logs"])
      (configured.presence || default_log_paths).map { |path| project_relative(path) }
    end

    def report_paths
      configured = shell_array(config["report_paths"] || config["junit_paths"] || config["junit_report_paths"])
      (configured.presence || default_report_paths).map { |path| project_relative(path) }
    end

    def project_relative(path)
      return path if project_path.blank? || path.start_with?("#{project_path}/")

      "#{project_path}/#{path}"
    end

    def artifact_name(value)
      prefix = project_path.to_s.tr("/", "-").presence
      [ prefix, value ].compact.join("-")
    end

    def junit_aggregation_command
      return "true" if junit_output.blank?

      output = Shellwords.escape(junit_output)
      paths = shell_glob_args(report_paths)
      file_list = ".syrus/#{artifact_name(name)}-junit-files"
      <<~BASH.squish
        rm -f #{output};
        mkdir -p .syrus;
        mkdir -p #{Shellwords.escape(File.dirname(junit_output))};
        find #{paths} -type f -name '*.xml' 2>/dev/null | sort > #{Shellwords.escape(file_list)} || true;
        if [ -s #{Shellwords.escape(file_list)} ]; then
          { echo '<testsuites>'; while IFS= read -r file; do awk 'NR == 1 && $0 ~ /^<\\?xml/ { next } { print }' "$file"; done < #{Shellwords.escape(file_list)}; echo '</testsuites>'; } > #{output};
        fi
      BASH
    end

    def shell_array(value)
      Array(value).map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def shell_glob_args(paths)
      paths.map { |path| Shellwords.escape(path).gsub("\\*", "*") }.join(" ")
    end
  end
end
