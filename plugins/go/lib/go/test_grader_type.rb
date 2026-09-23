require "shellwords"

module Go
  class TestGraderType
    include Syrus::Plugin::GraderType

    DEFAULT_TIMEOUT_MINUTES = 5
    DEFAULT_CHANGED_FILES = [
      "**/*.go",
      "go.mod",
      "go.sum",
      "Makefile"
    ].freeze

    def self.type_name
      "go-test"
    end

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
          junit_output: nil,
          failures: failures,
          base_retry: nil,
          deps: deps,
          metadata: {
            "grader_type" => self.class.type_name,
            "grader_framework" => "go",
            "grader_mode" => "test",
            "filter_capabilities" => {
              "changed_files" => false,
              "failed_cases" => false,
              "ci" => phases.include?("ci"),
              "coverage" => false
            }
          }
        )
      ]
    end

    private

    attr_reader :config, :default_failures

    def name
      config["name"].to_s.strip.presence || "go-tests"
    end

    def project_path
      config["_syrus_project_path"].to_s.strip.presence
    end

    def module_path
      raw = config["path"].presence || Array(config["paths"]).first.presence || "."
      raw.to_s.strip.presence || "."
    end

    def command
      prefix = "mise exec go@1.26.5 --"
      return "#{prefix} go test ./..." if root_module?

      "#{prefix} sh -c #{single_quote("cd #{Shellwords.escape(root_relative_module_path)} && go test ./...")}"
    end

    def root_module?
      project_path.blank? && module_path == "."
    end

    def root_relative_module_path
      return module_path if project_path.blank? || module_path.start_with?("#{project_path}/")
      return project_path if module_path == "."

      "#{project_path}/#{module_path}"
    end

    def single_quote(value)
      "'#{value.to_s.gsub("'", "'\\\\''")}'"
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

    def description
      config["description"].to_s.strip.presence || "Go test suite."
    end

    # Single-mode grader type -- a project-label prefix is applied later by
    # TargetGraph::GradePlan.
    def display_name
      config["display_name"].to_s.strip.presence || "Go test"
    end

    def required?
      return true unless config.key?("required")

      ActiveModel::Type::Boolean.new.cast(config["required"])
    end

    def timeout_minutes
      raw = config["timeout_minutes"].presence
      return DEFAULT_TIMEOUT_MINUTES if raw.blank?

      minutes = Integer(raw)
      raise ArgumentError, "timeout_minutes must be positive" unless minutes.positive?

      [ minutes, 90 ].min
    rescue ArgumentError
      raise ArgumentError, "timeout_minutes must be a positive integer"
    end

    def failures
      config["failures"].to_s.strip.presence || default_failures
    end

    def scope
      patterns = Array(config["when_files_changed"]).map(&:to_s).map(&:strip).reject(&:empty?)
      patterns = patterns.presence || DEFAULT_CHANGED_FILES
      return patterns if module_path == "."

      patterns.map { |pattern| "#{module_path}/#{pattern}" }
    end

    def deps
      raw = config["deps"] || config["dependencies"]
      refs =
        case raw
        when nil then []
        when String then [ raw ]
        else Array(raw)
        end
      refs.map(&:to_s).map(&:strip).reject(&:empty?)
    end
  end
end
