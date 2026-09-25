require "fileutils"
require "open3"
require "pathname"
require "shellwords"
require "timeout"

# Reruns the touched test files TouchedTestFiles finds a few extra times, in
# the current workspace at the current HEAD, and reports whether the results
# agreed -- the repeat-run flakiness gate for newly added or modified tests.
# A brand-new or freshly-modified test has no run history yet, so
# Adjudicators::KnownFlakyFailure -- which only has signal once a test has
# failed at least twice across real workflows -- cannot tell a test that is
# flaky from day one apart from a genuinely stable one. This asks the
# question directly, once, before the PR merges.
#
# The owning grader invokes this before it completes, so distributed grader
# fanout naturally spreads repeat checks across the same worker hosts as the
# normal test commands.
class TouchedTestRepeatGate
  Result = Data.define(:ran, :consistent, :reason, :grader_name, :command, :files, :repeats, :pass_count, :fail_count) do
    def inconsistent? = ran && !consistent
  end

  DEFAULT_REPEATS = 5
  TIMEOUT_SECONDS = 10.minutes
  INHERITED_ENV_NAMES = %w[
    BUNDLE_APP_CONFIG BUNDLE_GEMFILE BUNDLE_PATH
    COVERAGE NODE_ENV RACK_ENV RAILS_ENV RUN_CI_ONLY_SPECS
  ].freeze

  def self.call(...) = new(...).call

  def initialize(grader_step:, touched_files:, workspace_path:, env: {}, repeats: DEFAULT_REPEATS, log: ->(*) { })
    @grader_step = grader_step
    @touched_files = Array(touched_files)
    @workspace_path = workspace_path.to_s
    @env = env
    @repeats = [ repeats.to_i, 1 ].max
    @log = log
  end

  def call
    return skipped("no_touched_files") if @touched_files.empty?

    command = focused_command
    if command.blank?
      @log.call("[flaky_gate:#{grader_name}] no focused rerun command available for #{@touched_files.join(', ')} -- skipping")
      return skipped("no_focused_command")
    end

    @log.call("[flaky_gate:#{grader_name}] rerunning #{@touched_files.join(', ')} #{@repeats}x: #{command}")
    prepare_command = focused_prepare_command
    outcomes = run_repeats(command, prepare_command: prepare_command, isolated: true)
    return skipped("prepare_failed") unless outcomes

    if outcomes.none?
      @log.call("[flaky_gate:#{grader_name}] isolated repeats all failed; retrying without isolated test database identity")
      fallback_outcomes = run_repeats(command, prepare_command: prepare_command, isolated: false)
      return skipped("prepare_failed") unless fallback_outcomes

      outcomes = fallback_outcomes
    end

    pass_count = outcomes.count(&:itself)
    fail_count = outcomes.size - pass_count
    # The owning grader's normal command already passed immediately before
    # this check. Any failed focused rerun therefore disagrees with an observed
    # pass, including the important case where every repeat fails.
    consistent = fail_count.zero?

    @log.call("[flaky_gate:#{grader_name}] #{pass_count}/#{outcomes.size} passed (#{consistent ? 'consistent' : 'inconsistent'})")

    Result.new(
      ran: true,
      consistent: consistent,
      reason: consistent ? "repeat_run_consistent" : "repeat_run_inconsistent",
      grader_name: grader_name,
      command: command,
      files: @touched_files,
      repeats: outcomes.size,
      pass_count: pass_count,
      fail_count: fail_count
    )
  end

  private

  # Deliberately does NOT require the grader to have opted into
  # BaseRevisionRetry's `base_retry: { strategy: plugin }` -- that would make
  # this gate a silent no-op for essentially every repository, since
  # `base_retry` is a separate, rarely-configured opt-in for a different
  # feature (most graders, including this very repo's own `rspec` grader,
  # either have no `base_retry` at all or use a different strategy like
  # `files_as_args`). Honors an explicit `command`/`files_as_args` base_retry
  # when the operator already configured one for this grader -- it already
  # means "here is how to run just these files against this command" -- but
  # otherwise (no base_retry, or strategy `plugin`) asks the
  # :focused_test_command providers directly with a synthesized `plugin`
  # strategy: that extension point's whole contract is "can a language
  # plugin build a file-scoped rerun command for this grader," independent
  # of whatever base_retry BaseRevisionRetry separately uses.
  def focused_command
    case base_retry_strategy
    when "command"
      interpolate_explicit_command(base_retry_config["command"])
    when "files_as_args"
      files_as_args_command
    when "full_command"
      # Rerunning the entire grader command N times would defeat the cost
      # bound this gate exists to keep -- decline rather than fall back to
      # the whole suite.
      nil
    else
      plugin_command
    end
  end

  def base_retry_config
    @base_retry_config ||= @grader_step.details.to_h["base_retry"].to_h.stringify_keys
  end

  def base_retry_strategy
    base_retry_config["strategy"].to_s.presence
  end

  def interpolate_explicit_command(template)
    return nil if template.blank?

    template.to_s
      .gsub("{files}", Shellwords.join(@touched_files))
      .gsub("{failed_count}", @touched_files.size.to_s)
  end

  def files_as_args_command
    return nil if grader_command.blank?

    "#{grader_command} #{Shellwords.join(@touched_files)}"
  end

  def plugin_command
    Syrus::PluginRegistry.providers_for(:focused_test_command).each do |provider|
      command = provider.command_for(
        grader_name: grader_name,
        grader_command: grader_command,
        failed_cases: @touched_files.map { |path| { "file_path" => path } },
        base_retry: { "strategy" => "plugin" }
      )
      if command.to_s.strip.present?
        @focused_command_provider = provider
        return command.to_s.strip
      end
    rescue StandardError => e
      @log.call("[flaky_gate:#{grader_name}] focused_test_command #{provider} declined with #{e.class}: #{e.message}")
    end
    nil
  end

  def focused_prepare_command
    provider = @focused_command_provider
    return nil unless provider&.respond_to?(:prepare_command_for)

    provider.prepare_command_for(
      grader_name: grader_name,
      grader_command: grader_command
    ).to_s.strip.presence
  rescue StandardError => e
    @log.call("[flaky_gate:#{grader_name}] focused_test_command #{provider} prepare declined with #{e.class}: #{e.message}")
    nil
  end

  def run_once(command, extra_env:)
    run_command(command, label: "repeat run", extra_env: extra_env)
  end

  def run_repeats(command, prepare_command:, isolated:)
    Array.new(@repeats) do |index|
      repeat_env = isolated ? repeat_environment(index) : {}
      reset_repeat_database_files!(repeat_env) if isolated
      if prepare_command.present?
        @log.call("[flaky_gate:#{grader_name}] preparing focused repeat #{index + 1}/#{@repeats}: #{prepare_command}")
        return nil unless run_command(prepare_command, label: "prepare command", extra_env: repeat_env)
      end
      run_once(command, extra_env: repeat_env)
    end
  end

  def run_command(command, label:, extra_env: {})
    status = nil
    Timeout.timeout(TIMEOUT_SECONDS) do
      output, status = Open3.capture2e(command_environment.merge(extra_env), "bash", "-c", command, chdir: @workspace_path)
      unless status&.success?
        excerpt = output.to_s.lines.last(20).join.strip
        @log.call("[flaky_gate:#{grader_name}] #{label} failed (exit #{status&.exitstatus || 'unknown'}):\n#{excerpt}")
      end
    end
    status&.success? || false
  rescue Timeout::Error
    @log.call("[flaky_gate:#{grader_name}] #{label} timed out after #{TIMEOUT_SECONDS.to_i}s")
    false
  end

  def grader_name = @grader_step.details.to_h["name"].to_s
  def grader_command = @grader_step.details.to_h["command"].to_s

  def command_environment
    @command_environment ||= @env.to_h.merge(inherited_grader_environment)
  end

  def repeat_environment(index)
    token = "_syrus_flaky_#{Process.pid}_#{index}"
    storage_path = Pathname.new(@workspace_path).join("storage")
    {
      "TEST_ENV_NUMBER" => token,
      "SEARCH_DATABASE_PATH" => storage_path.join("test_search#{token}.sqlite3").to_s
    }
  end

  def reset_repeat_database_files!(repeat_env)
    storage_path = Pathname.new(@workspace_path).join("storage")
    paths = [
      storage_path.join("test#{repeat_env.fetch('TEST_ENV_NUMBER')}.sqlite3"),
      Pathname.new(repeat_env.fetch("SEARCH_DATABASE_PATH"))
    ]

    paths.each do |path|
      next unless path.to_s.start_with?(storage_path.to_s)

      FileUtils.rm_f([ path, "#{path}-wal", "#{path}-shm" ])
    end
  end

  def inherited_grader_environment
    export_arguments = grader_command[/\A\s*export\s+(.+?);/, 1]
    return {} if export_arguments.blank?

    Shellwords.split(export_arguments).each_with_object({}) do |assignment, env|
      name, value = assignment.split("=", 2)
      next unless value && name.in?(INHERITED_ENV_NAMES)

      # Keep the logical checkout path. Immutable grader workspaces may be
      # symlinked into a prepared cache while exposing workspace-local
      # dependency paths at the symlink, so realpath would point Bundler away
      # from the dependencies the owning grader just used successfully.
      env[name] = value.gsub(/\$\{?PWD\}?/, @workspace_path)
    end
  rescue ArgumentError
    {}
  end

  def skipped(reason)
    Result.new(
      ran: false, consistent: true, reason: reason, grader_name: grader_name, command: nil,
      files: @touched_files, repeats: 0, pass_count: 0, fail_count: 0
    )
  end
end
