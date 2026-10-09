require "shellwords"

module Ios
  class BaseGraderType
    include Syrus::Plugin::GraderType

    DEFAULT_CAPABILITIES = {
      "os" => "macos",
      "arch" => "arm64",
      "toolchain" => "xcode",
      "runtime" => "ios_simulator"
    }.freeze

    DEFAULT_TIMEOUT_MINUTES = 45
    DEFAULT_CHANGED_FILES = [
      "**/*.swift",
      "**/*.xcodeproj/**",
      "**/*.xcworkspace/**",
      "Package.swift",
      "Package.resolved",
      "**/Package.swift",
      "**/Package.resolved",
      "Podfile",
      "Podfile.lock",
      "**/Podfile",
      "**/Podfile.lock",
      "Cartfile",
      "Cartfile.resolved",
      "**/*.xcconfig",
      "**/*.plist",
      "**/*.storyboard",
      "**/*.xib",
      "**/*.entitlements"
    ].freeze

    def self.grade_steps(config:, default_failures:)
      new(config: config, default_failures: default_failures).grade_steps
    end

    def initialize(config:, default_failures:)
      @config = config.to_h.deep_stringify_keys
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
          capabilities: capabilities
        )
      ]
    end

    private

    attr_reader :config, :default_failures

    def default_name
      raise NotImplementedError
    end

    def default_display_name
      raise NotImplementedError
    end

    def framework
      raise NotImplementedError
    end

    def command
      raise NotImplementedError
    end

    def name
      config["name"].to_s.strip.presence || default_name
    end

    def display_name
      config["display_name"].to_s.strip.presence || default_display_name
    end

    def description
      config["description"].to_s.strip.presence || "#{default_display_name}."
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
      return DEFAULT_TIMEOUT_MINUTES if raw.blank?

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
      patterns = Array(config["when_files_changed"]).map(&:to_s).map(&:strip).reject(&:empty?)
      patterns.presence || DEFAULT_CHANGED_FILES
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

    def project_path
      config["_syrus_project_path"].to_s.strip.presence
    end

    def project_relative(path)
      path = path.to_s.strip
      return path if project_path.blank? || path == project_path || path.start_with?("#{project_path}/") || path.start_with?("$PWD/") || path.start_with?("/")

      "#{project_path}/#{path}"
    end

    def artifact_name(value = name)
      prefix = project_path.to_s.tr("/", "-").presence
      [ prefix, value ].compact.join("-")
    end

    def junit_output
      raw = config["junit_output"]
      return nil if raw.blank? || raw == false
      return project_relative("build/syrus/junit/#{artifact_name}.xml") if raw == true

      project_relative(raw)
    end

    def result_outputs
      return [] if junit_output.blank?

      [ { "artifact" => junit_output, "format" => "junit" } ]
    end

    def metadata
      {
        "grader_type" => self.class.type_name,
        "grader_framework" => framework,
        "grader_mode" => mode,
        "artifact_outputs" => artifact_outputs,
        "result_outputs" => result_outputs,
        "filter_capabilities" => {
          "changed_files" => false,
          "failed_cases" => junit_output.present?,
          "ci" => phases.include?("ci"),
          "coverage" => false
        }
      }.compact
    end

    def artifact_outputs
      []
    end

    def mode
      "test"
    end

    def capabilities
      raw = config["capabilities"].presence || DEFAULT_CAPABILITIES
      raise ArgumentError, "capabilities must be a mapping" unless raw.is_a?(Hash)

      normalized = TargetGraph::ExecutionCapabilities.new(**raw.deep_symbolize_keys).to_h
      normalized.presence
    rescue ArgumentError => e
      raise ArgumentError, "capabilities.#{e.message}"
    end

    def shell_array(value)
      Array(value).map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def shell_join(values)
      Shellwords.join(values)
    end
  end
end
