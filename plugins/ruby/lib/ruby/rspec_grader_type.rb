require "shellwords"
require "base64"

module Ruby
  class RspecGraderType
    include Syrus::Plugin::GraderType

    DEFAULT_TIMEOUT_MINUTES = 15
    DEFAULT_CHANGED_FILES = [
      "*.rb",
      "**/*.rb",
      "*.gemspec",
      "Gemfile",
      "Gemfile.lock",
      ".rspec",
      ".rspec-local"
    ].freeze
    DEFAULT_RSPEC_PATHS = [ "spec" ].freeze

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
        grade_step(name: full_name, run: full_command, phases: landing_phases, mode: "full", junit_output: junit_output(full_name), when_files_changed: configured_scope),
        grade_step(name: focused_name, run: focused_command, phases: review_phases, mode: "focused", junit_output: junit_output(focused_name), when_files_changed: focused_scope),
        grade_step(name: ci_name, run: ci_command, phases: ci_phases, mode: "ci", junit_output: junit_output(ci_name), when_files_changed: configured_scope)
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
      when "focused" then "Focused RSpec tests selected from changed Ruby files."
      when "ci" then "RSpec suite in CI mode, including CI-only examples when the repository uses that tag policy."
      else "RSpec suite."
      end
    end

    # Mode-aware operator-facing label ("RSpec", "RSpec (focused)", "RSpec
    # (CI)"); a project-label prefix (e.g. "rails plugin: ") is applied later
    # by TargetGraph::GradePlan once the owning project is known. An explicit
    # per-mode or blanket `display_name` config wins over the generated
    # default, mirroring `mode_timeout_minutes`.
    def display_name_for(mode)
      configured = mode_display_name(mode)
      return configured if configured

      case mode
      when "focused" then "RSpec (focused)"
      when "ci" then "RSpec (CI)"
      else "RSpec"
      end
    end

    def mode_display_name(mode)
      nested = config["display_names"].is_a?(Hash) ? config["display_names"].stringify_keys[mode] : nil
      config["#{mode}_display_name"].to_s.strip.presence || nested.to_s.strip.presence || config["display_name"].to_s.strip.presence
    end

    def base_retry
      SyrusYml::BaseRetry.new(strategy: "plugin", command: nil)
    end

    def coverage?
      ActiveModel::Type::Boolean.new.cast(config.fetch("coverage", false))
    end

    def junit_output(name)
      ".syrus/grade-output/#{artifact_name(name)}-junit.xml"
    end

    def json_output(name)
      ".syrus/rspec-json/#{artifact_name(name)}.json"
    end

    def artifact_name(name)
      return name if project_path.blank?

      "#{project_path.tr('/', '-')}-#{name}"
    end

    def full_command
      rspec_command(
        mode: "full",
        junit_output: junit_output(full_name),
        json_output: json_output(full_name),
        coverage: coverage?,
        args: [ *tag_args_for("full"), *rspec_paths ]
      )
    end

    def ci_command
      if parallel_rspec_enabled_for?("ci") && tag_args_for("ci").any?
        return parallel_rspec_command(
          mode: "ci",
          junit_output: junit_output(ci_name),
          json_output: json_output(ci_name),
          coverage: coverage?,
          env: { "RUN_CI_ONLY_SPECS" => "false" },
          args: [ *tag_args_for("full"), *rspec_paths ],
          extra_serial: {
            env: { "RUN_CI_ONLY_SPECS" => "true" },
            args: [ *tag_args_for("ci"), *rspec_paths ],
            json_output: extra_json_output(ci_name, "serial"),
            junit_output: extra_junit_output(ci_name, "serial")
          }
        )
      end

      rspec_command(
        mode: "ci",
        junit_output: junit_output(ci_name),
        json_output: json_output(ci_name),
        coverage: coverage?,
        env: { "RUN_CI_ONLY_SPECS" => "true" },
        args: [ *tag_args_for("ci"), *rspec_paths ]
      )
    end

    def rspec_paths
      raw = config["paths"] || config["spec_paths"] || DEFAULT_RSPEC_PATHS
      Array(raw).map(&:to_s).map(&:strip).reject(&:empty?).map { |path| project_relative(path) }
    end

    def focused_command
      <<~BASH
        #{setup_prefix} &&
        ruby -e #{Shellwords.escape(focused_selector_ruby)} > .syrus/rspec-focused-files &&
        if [ ! -s .syrus/rspec-focused-files ]; then echo "No focused RSpec files matched changed Ruby files"; exit 0; fi &&
        #{rspec_command(mode: "focused", junit_output: junit_output(focused_name), json_output: json_output(focused_name), coverage: false, args: [ *tag_args_for("focused"), "$(cat .syrus/rspec-focused-files)" ], shell_expand_args: true, skip_setup: true)}
      BASH
    end

    def rspec_command(mode:, junit_output:, json_output:, coverage:, env: {}, args: [], shell_expand_args: false, skip_setup: false)
      if parallel_rspec_enabled_for?(mode)
        return parallel_rspec_command(
          mode: mode,
          junit_output: junit_output,
          json_output: json_output,
          coverage: coverage,
          env: env,
          args: args,
          shell_expand_args: shell_expand_args,
          skip_setup: skip_setup
        )
      end

      serial_rspec_command(
        junit_output: junit_output,
        json_output: json_output,
        coverage: coverage,
        env: env,
        args: args,
        shell_expand_args: shell_expand_args,
        skip_setup: skip_setup
      )
    end

    def serial_rspec_command(junit_output:, json_output:, coverage:, env: {}, args: [], shell_expand_args: false, skip_setup: false)
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

    def parallel_rspec_command(mode:, junit_output:, json_output:, coverage:, env: {}, args: [], shell_expand_args: false, skip_setup: false, extra_serial: nil)
      raise ArgumentError, "parallel_rspec cannot use shell-expanded args without exec_args" if shell_expand_args && parallel_exec_args.blank?

      env = {
        "RAILS_ENV" => "${RAILS_ENV:-test}",
        "COVERAGE" => coverage ? "true" : "false",
        "RSPEC_JSON_DIR" => File.dirname(json_output),
        "RSPEC_JUNIT_DIR" => parallel_junit_dir(junit_output),
        "RSPEC_JUNIT_OUTPUT" => junit_output,
        "RSPEC_OUTPUT_PREFIX" => artifact_name(name_for_mode(mode)),
        "RSPEC_JUNIT_PREFIX" => "#{artifact_name(name_for_mode(mode))}-junit",
        "RSPEC_TAG_ARGS" => tag_args_for_env(args)
      }.merge(env)
      env_prefix = env.map { |key, value| "#{key}=#{Shellwords.escape(value.to_s)}" }.join(" ")
      junit_dir = Shellwords.escape(File.dirname(junit_output))
      json_dir = Shellwords.escape(File.dirname(json_output))
      shard_junit_dir = Shellwords.escape(parallel_junit_dir(junit_output))
      junit = Shellwords.escape(junit_output)
      json = Shellwords.escape(json_output)
      output_prefix = Shellwords.escape(artifact_name(name_for_mode(mode)))
      junit_prefix = Shellwords.escape("#{artifact_name(name_for_mode(mode))}-junit")
      parallel_args = [
        *parallel_process_args,
        "--quiet",
        "--runtime-log", parallel_runtime_log(mode),
        *parallel_execution_args(mode, args, json_output: json_output, junit_output: junit_output, shell_expand_args: shell_expand_args)
      ]
      parallel_command = parallel_shell_command(parallel_args, shell_expand_args: shell_expand_args)
      extra_serial_command = extra_serial ? serial_extra_command(extra_serial) : nil
      status_checks = if extra_serial
        <<~BASH.squish
          if [ "$parallel_status" -ne 0 ]; then exit "$parallel_status"; fi
          exit "$serial_status"
        BASH
      else
        %(exit "$parallel_status")
      end

      command = <<~BASH.squish
        mkdir -p #{junit_dir} #{json_dir} #{shard_junit_dir} &&
        rm -f #{junit} #{json} #{shard_junit_dir}/#{junit_prefix}-*.xml #{json_dir}/#{output_prefix}-*.json &&
        #{database_prepare_command}
        #{parallel_prepare_command}
        #{parallel_process_setup}
        set +e;
        #{env_prefix} #{parallel_command};
        parallel_status="$?";
        #{extra_serial_command}
        set -e;
        #{merge_junit_command(shard_junit_dir, junit)};
        #{status_checks}
      BASH
      skip_setup ? command : "#{setup_prefix} && #{command}"
    end

    def parallel_execution_args(mode, args, json_output:, junit_output:, shell_expand_args:)
      if parallel_exec_args.present?
        return [ "--exec-args", parallel_exec_args, *(shell_expand_args ? [ args.last.to_s ] : rspec_paths) ]
      end

      static_args = shell_expand_args ? leading_tag_args(args).join(" ") : Shellwords.join(leading_tag_args(args))
      test_paths = test_path_args(args)
      [
        "--test-options",
        [
          "--format progress",
          "--format json",
          "--out #{Shellwords.escape(parallel_json_output_pattern(json_output, name_for_mode(mode)))}",
          "--format RspecJunitFormatter",
          "--out #{Shellwords.escape(parallel_junit_output_pattern(junit_output, name_for_mode(mode)))}",
          static_args
        ].reject(&:blank?).join(" "),
        *(shell_expand_args ? [] : test_paths.presence || rspec_paths)
      ]
    end

    def parallel_shell_command(parallel_args, shell_expand_args:)
      unless shell_expand_args && parallel_exec_args.present?
        rendered = Shellwords.join(parallel_args).gsub(PARALLEL_PROCESS_PLACEHOLDER) { '"$RSPEC_PARALLEL_PROCESSES"' }
        return "#{parallel_rspec_binary} #{rendered}"
      end

      expandable = parallel_args.last
      quoted = Shellwords.join(parallel_args[0...-1])
      rendered = quoted.gsub(PARALLEL_PROCESS_PLACEHOLDER) { '"$RSPEC_PARALLEL_PROCESSES"' }
      "#{parallel_rspec_binary} #{rendered} #{expandable}"
    end

    def serial_extra_command(extra_serial)
      serial = serial_rspec_command(
        junit_output: extra_serial.fetch(:junit_output),
        json_output: extra_serial.fetch(:json_output),
        coverage: false,
        env: extra_serial.fetch(:env, {}),
        args: extra_serial.fetch(:args),
        skip_setup: true
      )
      "set +e; #{serial}; serial_status=\"$?\";"
    end

    def merge_junit_command(shard_junit_dir, junit)
      encoded_script = Base64.strict_encode64(<<~'RUBY')
        dir, out = ARGV
        files = Dir[File.join(dir, "*.xml")].sort
        exit if files.empty?
        merged = REXML::Document.new("<testsuites/>")
        totals = Hash.new(0)
        files.each do |path|
          doc = begin
            REXML::Document.new(File.read(path))
          rescue StandardError
            next
          end
          next unless doc.root
          suites = doc.root.name == "testsuites" ? doc.root.elements.to_a("testsuite") : [ doc.root ]
          suites.each do |suite|
            %w[tests failures errors skipped].each { |k| totals[k] += suite.attributes[k].to_i }
            totals["time"] += suite.attributes["time"].to_f
            merged.root.add_element(suite.deep_clone)
          end
        end
        exit if merged.root.elements.empty?
        %w[tests failures errors skipped].each { |k| merged.root.add_attribute(k, totals[k].to_s) }
        merged.root.add_attribute("time", format("%.6f", totals["time"]))
        File.write(out, merged.to_s)
      RUBY

      "ruby -rbase64 -rrexml/document -e 'eval(Base64.strict_decode64(ARGV.shift))' #{encoded_script} #{shard_junit_dir} #{junit}"
    end

    def database_prepare_command
      return "" unless database_prepare?

      %(if [ -x bin/rails ] && [ -f config/database.yml ]; then RAILS_ENV=${RAILS_ENV:-test} bin/rails db:test:prepare; fi &&)
    end

    def database_prepare?
      value = config.fetch("database_prepare", "auto")
      return true if value.to_s == "auto"

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def setup_prefix
      %(export BUNDLE_PATH="$PWD/vendor/bundle" BUNDLE_APP_CONFIG="$PWD/.bundle"; bundle check || bundle install --jobs "${BUNDLE_INSTALL_JOBS:-1}")
    end

    def parallel_prepare_command
      command = parallel_config["prepare_command"].to_s.strip
      command.present? ? "#{command} &&" : ""
    end

    def parallel_rspec_enabled_for?(mode)
      raw = config["parallel_rspec"]
      return false if raw.blank?

      return true if raw == true

      if raw.is_a?(Hash)
        enabled = raw.key?("enabled") ? ActiveModel::Type::Boolean.new.cast(raw["enabled"]) : true
        return false unless enabled

        modes = Array(raw["rspec_modes"] || raw["generated_modes"] || raw["modes"] || raw["mode"]).map(&:to_s).map(&:strip).reject(&:empty?)
        return true if modes.empty?

        modes.include?(mode.to_s)
      else
        ActiveModel::Type::Boolean.new.cast(raw)
      end
    end

    def parallel_config
      config["parallel_rspec"].is_a?(Hash) ? config["parallel_rspec"].stringify_keys : {}
    end

    def parallel_rspec_binary
      parallel_config["command"].to_s.strip.presence || "bundle exec parallel_rspec"
    end

    def parallel_exec_args
      parallel_config["exec_args"].to_s.strip.presence
    end

    def parallel_process_args
      [ "-n", PARALLEL_PROCESS_PLACEHOLDER ]
    end

    PARALLEL_PROCESS_PLACEHOLDER = "__SYRUS_RSPEC_PROCESSES__"

    def parallel_process_setup
      configured = parallel_config["processes"].to_s.strip.presence
      commands = [
        'RSPEC_PARALLEL_PROCESSES="${SYRUS_PROCESS_PARALLELISM:-}"',
        "if [ -z \"$RSPEC_PARALLEL_PROCESSES\" ]; then RSPEC_PARALLEL_PROCESSES=#{configured || '$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)'}; fi"
      ]
      commands << "if [ \"$RSPEC_PARALLEL_PROCESSES\" -gt #{configured} ]; then RSPEC_PARALLEL_PROCESSES=#{configured}; fi" if configured
      commands << 'if [ "$RSPEC_PARALLEL_PROCESSES" -lt 1 ]; then RSPEC_PARALLEL_PROCESSES=1; fi'
      "#{commands.join('; ')};"
    end

    def parallel_runtime_log(mode)
      parallel_config["runtime_log"].to_s.strip.presence || ".syrus/parallel_runtime_#{artifact_name(name_for_mode(mode))}.log"
    end

    def parallel_junit_dir(junit_output)
      configured = parallel_config["junit_dir"].to_s.strip.presence
      return configured if configured

      File.join(File.dirname(junit_output), "parallel-#{File.basename(junit_output, ".*")}")
    end

    def parallel_json_output_pattern(json_output, name)
      "#{File.dirname(json_output)}/#{artifact_name(name)}-${TEST_ENV_NUMBER:-1}.json"
    end

    def parallel_junit_output_pattern(junit_output, name)
      "#{parallel_junit_dir(junit_output)}/#{artifact_name(name)}-${TEST_ENV_NUMBER:-1}.xml"
    end

    def name_for_mode(mode)
      case mode.to_s
      when "focused" then focused_name
      when "ci" then ci_name
      else full_name
      end
    end

    def extra_json_output(name, suffix)
      ".syrus/rspec-json/#{artifact_name(name)}-#{suffix}.json"
    end

    def extra_junit_output(name, suffix)
      File.join(File.dirname(junit_output(name)), "parallel-#{File.basename(junit_output(name), ".*")}", "#{artifact_name(name)}-#{suffix}.xml")
    end

    def tag_args_for_env(args)
      leading_tag_args(args).join(" ")
    end

    def leading_tag_args(args)
      tags = []
      index = 0
      while args[index].to_s == "--tag"
        tags << args[index].to_s
        tags << args[index + 1].to_s if args[index + 1].present?
        index += 2
      end
      tags
    end

    def test_path_args(args)
      args.drop(leading_tag_args(args).length)
    end

    def tag_args_for(mode)
      include_tags = tags_for(mode, "include")
      exclude_tags = tags_for(mode, "exclude")
      include_tags.flat_map { |tag| [ "--tag", tag ] } +
        exclude_tags.flat_map { |tag| [ "--tag", "~#{tag}" ] }
    end

    def tags_for(mode, polarity)
      nested = config["tags"].is_a?(Hash) ? config["tags"].deep_stringify_keys : {}
      aliases = mode == "full" ? %w[full fast] : [ mode ]
      values = []
      values.concat(Array(config["#{polarity}_tags"]))
      aliases.each do |name|
        values.concat(Array(config["#{name}_#{polarity}_tags"]))
        values.concat(Array(nested.dig(name, polarity)))
        values.concat(Array(nested["#{name}_#{polarity}"]))
      end
      values.concat(Array(nested[polarity]))

      if polarity == "exclude" && %w[full focused].include?(mode) && values.empty?
        values << "ci_only"
      end

      values.map(&:to_s).map(&:strip).reject(&:empty?).uniq
    end

    def focused_selector_ruby
      <<~'RUBY'.sub("__SYRUS_SCOPE__", focused_scope.inspect).sub("__SYRUS_PROJECT_PATH__", project_path.to_s.inspect)
        base = %w[origin/main origin/master main master].find { |ref| system("git", "rev-parse", "--verify", "#{ref}^{commit}", out: File::NULL, err: File::NULL) }
        exit 0 unless base
        scope = __SYRUS_SCOPE__
        project_path = __SYRUS_PROJECT_PATH__
        prefixed = ->(path) { project_path.empty? ? path : File.join(project_path, path) }
        relative = ->(path) { project_path.empty? ? path : path.delete_prefix("#{project_path}/") }
        matches_scope = ->(path) { scope.empty? || scope.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_DOTMATCH) } }
        changed = `git diff --name-only --diff-filter=ACMR #{base}...HEAD -- "*.rb"`.lines.map(&:strip)
        project_matches = ->(path) { project_path.empty? || path.start_with?("#{project_path}/") }
        specs = changed.select { |path| project_matches.call(path) && matches_scope.call(relative.call(path)) }.flat_map do |path|
          rel = relative.call(path)
          if rel.start_with?("spec/") && rel.end_with?("_spec.rb")
            [ path ]
          else
            stem = rel.sub(/\.rb\z/, "")
            [
              "#{stem}_spec.rb",
              "spec/#{stem}_spec.rb",
              rel.start_with?("app/") ? "spec/#{rel.delete_prefix("app/").sub(/\.rb\z/, "_spec.rb")}" : nil,
              rel.start_with?("lib/") ? "spec/lib/#{rel.delete_prefix("lib/").sub(/\.rb\z/, "_spec.rb")}" : nil
            ].compact.map { |candidate| prefixed.call(candidate) }
          end
        end
        puts specs.uniq.sort.select { |path| File.exist?(path) }
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
