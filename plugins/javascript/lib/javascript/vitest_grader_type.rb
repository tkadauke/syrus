require "shellwords"

module JavaScript
  class VitestGraderType
    include Syrus::Plugin::GraderType

    DEFAULT_TIMEOUT_MINUTES = 15
    DEFAULT_CHANGED_FILES = [
      "**/*.js",
      "**/*.jsx",
      "**/*.ts",
      "**/*.tsx",
      "*.js",
      "*.jsx",
      "*.ts",
      "*.tsx",
      "package.json",
      "package-lock.json",
      "pnpm-lock.yaml",
      "yarn.lock",
      "vitest.config.*",
      "vite.config.*",
      "tsconfig.json"
    ].freeze
    DEFAULT_TEST_PATHS = [
      "app/frontend",
      "src",
      "test",
      "tests",
      "__tests__"
    ].freeze

    def self.type_name
      "vitest"
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
        grade_step(name: full_name, run: full_command, phases: landing_phases, mode: "full", junit_output: junit_output(full_name), when_files_changed: configured_scope),
        grade_step(name: focused_name, run: focused_command, phases: review_phases, mode: "focused", junit_output: junit_output(focused_name), when_files_changed: focused_scope),
        grade_step(name: ci_name, run: ci_command, phases: ci_phases, mode: "ci", junit_output: junit_output(ci_name), when_files_changed: configured_scope)
      ]
    end

    private

    attr_reader :config, :default_failures

    def full_name
      config["name"].to_s.strip.presence || "vitest"
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
      config["failures"].to_s.strip.presence || default_failures
    end

    def configured_scope
      patterns = Array(config["when_files_changed"]).map(&:to_s).map(&:strip).reject(&:empty?)
      patterns.presence || DEFAULT_CHANGED_FILES
    end

    def focused_scope
      configured_scope
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
      when "focused" then "Focused Vitest tests selected from changed JavaScript and TypeScript files."
      when "ci" then "Vitest suite in CI mode."
      else "Vitest suite."
      end
    end

    def base_retry
      SyrusYml::BaseRetry.new(strategy: "plugin", command: nil)
    end

    def coverage?
      ActiveModel::Type::Boolean.new.cast(config.fetch("coverage", false))
    end

    def typecheck?
      return true unless config.key?("typecheck")

      value = config["typecheck"]
      return true if value.to_s == "auto"

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def max_workers
      raw = config["max_workers"].to_s.strip.presence
      raw || "${VITEST_MAX_WORKERS:-2}"
    end

    def junit_output(name)
      ".syrus/grade-output/#{name}-junit.xml"
    end

    def full_command
      vitest_command(
        junit_output: junit_output(full_name),
        coverage: coverage?,
        include_typecheck: typecheck?,
        args: [ "run", *test_paths ]
      )
    end

    def ci_command
      vitest_command(
        junit_output: junit_output(ci_name),
        coverage: coverage?,
        include_typecheck: typecheck?,
        args: [ "run", *test_paths ]
      )
    end

    def test_paths
      raw = config["paths"] || config["test_paths"] || DEFAULT_TEST_PATHS
      Array(raw).map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def focused_command
      <<~BASH.squish
        #{setup_prefix} &&
        ruby -e #{Shellwords.escape(focused_selector_ruby)} > .syrus/vitest-focused-files &&
        if [ ! -s .syrus/vitest-focused-files ]; then echo "No focused Vitest files matched changed JavaScript/TypeScript files"; exit 0; fi &&
        #{vitest_command(junit_output: junit_output(focused_name), coverage: false, include_typecheck: false, args: [ "related", "--run", "--passWithNoTests", "$(cat .syrus/vitest-focused-files)" ], shell_expand_args: true, skip_setup: true)}
      BASH
    end

    def vitest_command(junit_output:, coverage:, include_typecheck:, args:, shell_expand_args: false, skip_setup: false)
      junit_dir = Shellwords.escape(File.dirname(junit_output))
      junit = Shellwords.escape(junit_output)
      static_args = shell_expand_args ? args.join(" ") : Shellwords.join(args)
      coverage_args = coverage ? " --coverage" : ""
      command = <<~BASH.squish
        export VITE_CONFIG_NATIVE_IGNORE_WARNING="${VITE_CONFIG_NATIVE_IGNORE_WARNING:-true}" &&
        mkdir -p #{junit_dir} &&
        rm -f #{junit} &&
        #{typecheck_command(include_typecheck)}
        run_vitest #{static_args}#{coverage_args} --maxWorkers #{max_workers} --reporter=default --reporter=junit --outputFile.junit=#{junit}
      BASH
      skip_setup ? command : "#{setup_prefix} && #{command}"
    end

    def setup_prefix
      <<~BASH.squish
        if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile;
        elif [ -f yarn.lock ]; then yarn install --frozen-lockfile;
        elif [ -f package-lock.json ]; then npm ci;
        elif [ ! -d node_modules ]; then npm install;
        fi;
        run_package_script() {
          if [ -f pnpm-lock.yaml ]; then pnpm run "$@";
          elif [ -f yarn.lock ]; then yarn run "$@";
          else npm run "$@";
          fi
        };
        run_vitest() {
          if [ -x ./node_modules/.bin/vitest ]; then ./node_modules/.bin/vitest "$@";
          else npx vitest "$@";
          fi
        }
      BASH
    end

    def typecheck_command(include_typecheck)
      return "" unless include_typecheck

      <<~BASH.squish
        if [ -f package.json ] && node -e 'const s=require("./package.json").scripts||{}; process.exit(s.typecheck ? 0 : 1)' >/dev/null 2>&1; then
          run_package_script typecheck;
        fi &&
      BASH
    end

    def focused_selector_ruby
      scope_literal = focused_scope.inspect
      <<~RUBY
        base = %w[origin/main origin/master main master].find { |ref| system("git", "rev-parse", "--verify", "\#{ref}^{commit}", out: File::NULL, err: File::NULL) }
        exit 0 unless base
        scope = #{scope_literal}
        matches_scope = ->(path) { scope.empty? || scope.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_DOTMATCH) } }
        changed = `git diff --name-only --diff-filter=ACMR \#{base}...HEAD -- "*.js" "*.jsx" "*.ts" "*.tsx"`.lines.map(&:strip)
        puts changed.uniq.sort.select { |path| File.exist?(path) && matches_scope.call(path) }
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
        deps: configured_deps,
        metadata: {
          "grader_type" => self.class.type_name,
          "grader_framework" => "vitest",
          "grader_mode" => mode,
          "result_outputs" => [ { "artifact" => junit_output, "format" => "junit" } ],
          "coverage_outputs" => coverage? ? [ { "artifact" => "coverage/lcov.info", "format" => "lcov" } ] : [],
          "filter_capabilities" => {
            "changed_files" => mode == "focused",
            "failed_cases" => true,
            "ci" => mode == "ci",
            "coverage" => coverage?,
            "typecheck" => typecheck?
          }
        }
      )
    end
  end
end
