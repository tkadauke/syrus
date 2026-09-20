require "shellwords"

module Ruby
  class RspecGraderType
    include Syrus::Plugin::GraderType

    DEFAULT_TIMEOUT_MINUTES = 15
    FOCUSED_CHANGED_FILES = [ "app/**/*.rb", "lib/**/*.rb", "spec/**/*.rb", "plugins/*/app/**/*.rb", "plugins/*/lib/**/*.rb", "plugins/*/spec/**/*.rb" ].freeze

    def self.type_name
      "rspec"
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
        grade_step(name: full_name, run: full_command, phases: landing_phases, mode: "full", junit_output: junit_output(full_name)),
        grade_step(name: focused_name, run: focused_command, phases: review_phases, mode: "focused", junit_output: junit_output(focused_name), when_files_changed: FOCUSED_CHANGED_FILES),
        grade_step(name: ci_name, run: ci_command, phases: ci_phases, mode: "ci", junit_output: junit_output(ci_name))
      ]
    end

    private

    attr_reader :config, :default_failures

    def full_name
      config["name"].to_s.strip.presence || "rspec"
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

    def description_for(mode)
      configured = config["description"].to_s.strip.presence
      return configured if configured

      case mode
      when "focused" then "Focused RSpec tests selected from changed Ruby files."
      when "ci" then "RSpec suite in CI mode, including CI-only examples when the repository uses that tag policy."
      else "RSpec suite."
      end
    end

    def base_retry
      SyrusYml::BaseRetry.new(strategy: "plugin", command: nil)
    end

    def coverage?
      ActiveModel::Type::Boolean.new.cast(config.fetch("coverage", false))
    end

    def junit_output(name)
      ".syrus/grade-output/#{name}-junit.xml"
    end

    def full_command
      rspec_command(
        junit_output: junit_output(full_name),
        json_output: ".syrus/rspec-json/#{full_name}.json",
        coverage: coverage?,
        args: [ "--tag", "~ci_only" ]
      )
    end

    def ci_command
      rspec_command(
        junit_output: junit_output(ci_name),
        json_output: ".syrus/rspec-json/#{ci_name}.json",
        coverage: coverage?,
        env: { "RUN_CI_ONLY_SPECS" => "true" }
      )
    end

    def focused_command
      <<~BASH.squish
        #{setup_prefix} &&
        ruby -e #{Shellwords.escape(focused_selector_ruby)} > .syrus/rspec-focused-files &&
        if [ ! -s .syrus/rspec-focused-files ]; then echo "No focused RSpec files matched changed Ruby files"; exit 0; fi &&
        #{rspec_command(junit_output: junit_output(focused_name), json_output: ".syrus/rspec-json/#{focused_name}.json", coverage: false, args: [ "--tag", "~ci_only", "$(cat .syrus/rspec-focused-files)" ], shell_expand_args: true, skip_setup: true)}
      BASH
    end

    def rspec_command(junit_output:, json_output:, coverage:, env: {}, args: [], shell_expand_args: false, skip_setup: false)
      env = {
        "RAILS_ENV" => "${RAILS_ENV:-test}",
        "COVERAGE" => coverage ? "true" : "false"
      }.merge(env)

      env_prefix = env.map { |key, value| "#{key}=#{value}" }.join(" ")
      static_args = shell_expand_args ? args.join(" ") : Shellwords.join(args)
      junit_dir = Shellwords.escape(File.dirname(junit_output))
      json_dir = Shellwords.escape(File.dirname(json_output))
      junit = Shellwords.escape(junit_output)
      json = Shellwords.escape(json_output)
      command = <<~BASH.squish
        mkdir -p #{junit_dir} #{json_dir} &&
        rm -f #{junit} #{json} &&
        #{database_prepare_command}
        if bundle exec ruby -e 'gem "rspec_junit_formatter"' >/dev/null 2>&1; then
          #{env_prefix} bundle exec rspec --format progress --format json --out #{json} --format RspecJunitFormatter --out #{junit} #{static_args};
        else
          #{env_prefix} bundle exec rspec --format progress --format json --out #{json} #{static_args};
        fi
      BASH
      skip_setup ? command : "#{setup_prefix} && #{command}"
    end

    def database_prepare_command
      return "" unless database_prepare?

      %(if [ -x bin/rails ] && [ -f config/database.yml ]; then bin/rails db:test:prepare; fi &&)
    end

    def database_prepare?
      value = config.fetch("database_prepare", "auto")
      return true if value.to_s == "auto"

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def setup_prefix
      %(export BUNDLE_PATH="$PWD/vendor/bundle" BUNDLE_APP_CONFIG="$PWD/.bundle"; bundle check || bundle install --jobs "${BUNDLE_INSTALL_JOBS:-1}")
    end

    def focused_selector_ruby
      <<~'RUBY'
        base = %w[origin/main origin/master main master].find { |ref| system("git", "rev-parse", "--verify", "#{ref}^{commit}", out: File::NULL, err: File::NULL) }
        exit 0 unless base
        changed = `git diff --name-only --diff-filter=ACMR #{base}...HEAD -- "*.rb"`.lines.map(&:strip)
        specs = changed.filter_map do |path|
          if path.start_with?("spec/") && path.end_with?("_spec.rb")
            path
          elsif path.start_with?("app/")
            "spec/#{path.delete_prefix("app/").sub(/\.rb\z/, "_spec.rb")}"
          elsif path.start_with?("lib/")
            "spec/lib/#{path.delete_prefix("lib/").sub(/\.rb\z/, "_spec.rb")}"
          elsif path.match?(%r{\Aplugins/([^/]+)/app/(.+)\.rb\z})
            "plugins/#{$1}/spec/#{$2}_spec.rb"
          elsif path.match?(%r{\Aplugins/([^/]+)/lib/(.+)\.rb\z})
            "plugins/#{$1}/spec/lib/#{$2}_spec.rb"
          elsif path.match?(%r{\Aplugins/([^/]+)/spec/.+_spec\.rb\z})
            path
          end
        end
        puts specs.uniq.sort.select { |path| File.exist?(path) }
      RUBY
    end

    def grade_step(name:, run:, phases:, mode:, junit_output:, when_files_changed: nil)
      SyrusYml::GradeStep.new(
        name: name,
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
        deps: [],
        metadata: {
          "grader_type" => self.class.type_name,
          "grader_framework" => "rspec",
          "grader_mode" => mode,
          "result_outputs" => [ { "artifact" => junit_output, "format" => "junit" } ],
          "coverage_outputs" => coverage? ? [ { "artifact" => "coverage/.resultset.json", "format" => "simplecov" } ] : [],
          "filter_capabilities" => {
            "changed_files" => mode == "focused",
            "failed_cases" => true,
            "ci" => mode == "ci",
            "coverage" => coverage?
          }
        }
      )
    end
  end
end
