require "shellwords"

module Ruby
  class MinitestGraderType
    include Syrus::Plugin::GraderType

    DEFAULT_TIMEOUT_MINUTES = 15
    DEFAULT_CHANGED_FILES = [
      "*.rb",
      "**/*.rb",
      "*.gemspec",
      "Gemfile",
      "Gemfile.lock",
      "Rakefile",
      "test/**/*.rb"
    ].freeze
    DEFAULT_TEST_PATHS = [ "test" ].freeze

    def self.type_name
      "minitest"
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
        grade_step(name: full_name, run: full_command, phases: landing_phases, mode: "full", junit_output: junit_output("full", full_name), when_files_changed: configured_scope),
        grade_step(name: focused_name, run: focused_command, phases: review_phases, mode: "focused", junit_output: junit_output("focused", focused_name), when_files_changed: focused_scope),
        grade_step(name: ci_name, run: ci_command, phases: ci_phases, mode: "ci", junit_output: junit_output("ci", ci_name), when_files_changed: configured_scope)
      ]
    end

    private

    attr_reader :config, :default_failures

    def full_name
      config["name"].to_s.strip.presence || "minitest"
    end

    def focused_name
      "#{full_name}-focused"
    end

    def ci_name
      "#{full_name}-ci"
    end

    def landing_phases
      configured_phases & %w[landing promotion]
    end

    def review_phases
      configured_phases.include?("review") ? %w[review] : []
    end

    def ci_phases
      configured_phases.include?("ci") ? %w[ci] : []
    end

    def configured_phases
      raw = config["phases"]
      phases =
        case raw
        when nil then SyrusYml::DEFAULT_GRADE_PHASES
        when String then [ raw ]
        else Array(raw)
        end
      phases.map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def required?
      return true unless config.key?("required")

      ActiveModel::Type::Boolean.new.cast(config["required"])
    end

    def timeout_minutes(mode)
      raw = mode_timeout_minutes(mode)
      return DEFAULT_TIMEOUT_MINUTES if raw.blank?

      minutes = Integer(raw)
      raise ArgumentError, "timeout_minutes must be positive" unless minutes.positive?

      [ minutes, 90 ].min
    rescue ArgumentError
      raise ArgumentError, "timeout_minutes must be a positive integer"
    end

    def mode_timeout_minutes(mode)
      nested = config["timeouts"].is_a?(Hash) ? config["timeouts"].stringify_keys[mode] : nil
      config["#{mode}_timeout_minutes"].presence || nested.presence || config["timeout_minutes"]
    end

    def failures
      config["failures"].to_s.strip.presence || "allow_inherited"
    end

    def configured_scope
      patterns = Array(config["when_files_changed"]).map(&:to_s).map(&:strip).reject(&:empty?)
      patterns.presence || DEFAULT_CHANGED_FILES
    end

    def focused_scope
      configured_scope
    end

    def project_path
      config["_syrus_project_path"].to_s.strip.presence
    end

    def project_relative(path)
      path = path.to_s
      return path if project_path.blank? || path.start_with?("#{project_path}/")

      "#{project_path}/#{path}"
    end

    def configured_deps
      raw = config["deps"] || config["dependencies"]
      refs =
        case raw
        when nil then []
        when String then [ raw ]
        else Array(raw)
        end
      refs.map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def description_for(mode)
      configured = config["description"].to_s.strip.presence
      return configured if configured

      case mode
      when "focused" then "Focused Minitest test files selected from changed Ruby tests."
      when "ci" then "Minitest suite in CI mode."
      else "Minitest suite."
      end
    end

    def display_name_for(mode)
      configured = mode_display_name(mode)
      return configured if configured

      case mode
      when "focused" then "Minitest (focused)"
      when "ci" then "Minitest (CI)"
      else "Minitest"
      end
    end

    def mode_display_name(mode)
      nested = config["display_names"].is_a?(Hash) ? config["display_names"].stringify_keys[mode] : nil
      config["#{mode}_display_name"].to_s.strip.presence || nested.to_s.strip.presence || config["display_name"].to_s.strip.presence
    end

    def base_retry
      SyrusYml::BaseRetry.new(strategy: "full_command", command: nil)
    end

    def junit_output(mode, name)
      configured = mode_junit_output(mode)
      return if configured.blank?

      configured == true ? ".syrus/grade-output/#{artifact_name(name)}-junit.xml" : configured
    end

    def mode_junit_output(mode)
      nested = config["junit_outputs"].is_a?(Hash) ? config["junit_outputs"].stringify_keys[mode] : nil
      value = config["#{mode}_junit_output"].presence || nested.presence || config["junit_output"]
      return true if value == true

      value.to_s.strip.presence
    end

    def artifact_name(name)
      return name if project_path.blank?

      "#{project_path.tr('/', '-')}-#{name}"
    end

    def test_paths
      raw = config["paths"] || config["test_paths"] || DEFAULT_TEST_PATHS
      Array(raw).map(&:to_s).map(&:strip).reject(&:empty?).map { |path| project_relative(path) }
    end

    def full_command
      configured_command("full") || auto_command(paths: test_paths)
    end

    def ci_command
      configured_command("ci") || configured_command("full") || auto_command(paths: test_paths)
    end

    def focused_command
      configured = configured_command("focused")
      command = configured || auto_focused_command
      <<~BASH
        #{setup_prefix} &&
        ruby -e #{Shellwords.escape(focused_selector_ruby)} > .syrus/minitest-focused-files &&
        if [ ! -s .syrus/minitest-focused-files ]; then echo "No focused Minitest files matched changed Ruby test files"; exit 0; fi &&
        #{command}
      BASH
    end

    def configured_command(mode)
      value = config["#{mode}_command"].to_s.strip.presence
      value ||= config["command"].to_s.strip.presence if mode == "full"
      value
    end

    def auto_command(paths:)
      rendered_paths = Shellwords.join(paths)
      command = <<~BASH.squish
        #{database_prepare_command}
        if [ -x #{rails_bin} ]; then
          RAILS_ENV=${RAILS_ENV:-test} #{rails_bin} test #{rendered_paths};
        elif [ -f #{rakefile_path} ]; then
          #{rake_command};
        else
          bundle exec ruby -I#{test_load_path} #{rendered_paths};
        fi
      BASH

      "#{setup_prefix} && #{command}"
    end

    def auto_focused_command
      <<~BASH.squish
        #{database_prepare_command}
        if [ -x #{rails_bin} ]; then
          RAILS_ENV=${RAILS_ENV:-test} #{rails_bin} test $(cat .syrus/minitest-focused-files);
        else
          bundle exec ruby -I#{test_load_path} $(cat .syrus/minitest-focused-files);
        fi
      BASH
    end

    def database_prepare_command
      return "" unless database_prepare?

      %(if [ -x #{rails_bin} ] && [ -f #{database_config_path} ]; then RAILS_ENV=test #{rails_bin} db:test:prepare; fi &&)
    end

    def database_prepare?
      value = config.fetch("database_prepare", "auto")
      return true if value.to_s == "auto"

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def setup_prefix
      %(export BUNDLE_PATH="$PWD/vendor/bundle" BUNDLE_APP_CONFIG="$PWD/.bundle"; bundle check || bundle install --jobs "${BUNDLE_INSTALL_JOBS:-1}")
    end

    def rails_bin
      Shellwords.escape(project_relative("bin/rails"))
    end

    def rakefile_path
      Shellwords.escape(project_relative("Rakefile"))
    end

    def database_config_path
      Shellwords.escape(project_relative("config/database.yml"))
    end

    def test_load_path
      Shellwords.escape(project_relative("test"))
    end

    def rake_command
      return "bundle exec rake test" if project_path.blank?

      "cd #{Shellwords.escape(project_path)} && bundle exec rake test"
    end

    def focused_selector_ruby
      <<~'RUBY'.sub("__SYRUS_SCOPE__", focused_scope.inspect).sub("__SYRUS_PROJECT_PATH__", project_path.to_s.inspect)
        base = %w[origin/main origin/master main master].find { |ref| system("git", "rev-parse", "--verify", "#{ref}^{commit}", out: File::NULL, err: File::NULL) }
        exit 0 unless base
        scope = __SYRUS_SCOPE__
        project_path = __SYRUS_PROJECT_PATH__
        relative = ->(path) { project_path.empty? ? path : path.delete_prefix("#{project_path}/") }
        matches_scope = ->(path) { scope.empty? || scope.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_DOTMATCH) } }
        changed = `git diff --name-only --diff-filter=ACMR #{base}...HEAD -- "*.rb"`.lines.map(&:strip)
        project_matches = ->(path) { project_path.empty? || path.start_with?("#{project_path}/") }
        tests = changed.select do |path|
          rel = relative.call(path)
          project_matches.call(path) && matches_scope.call(rel) && rel.start_with?("test/") && rel.end_with?("_test.rb") && File.exist?(path)
        end
        puts tests.uniq.sort
      RUBY
    end

    def grade_step(name:, run:, phases:, mode:, junit_output:, when_files_changed: nil)
      SyrusYml::GradeStep.new(
        name: name,
        display_name: display_name_for(mode),
        run: run,
        ci: nil,
        phases: phases,
        description: description_for(mode),
        required: required?,
        timeout_minutes: timeout_minutes(mode),
        when_files_changed: when_files_changed,
        junit_output: junit_output,
        failures: failures,
        base_retry: base_retry,
        deps: configured_deps,
        metadata: {
          "grader_type" => self.class.type_name,
          "grader_framework" => "minitest",
          "grader_mode" => mode,
          "result_outputs" => result_outputs(junit_output),
          "coverage_outputs" => [],
          "filter_capabilities" => {
            "changed_files" => mode == "focused",
            "failed_cases" => junit_output.present?,
            "ci" => mode == "ci",
            "coverage" => false
          }
        }
      )
    end

    def result_outputs(junit_output)
      return [] if junit_output.blank?

      [ { "artifact" => junit_output, "format" => "junit" } ]
    end
  end
end
