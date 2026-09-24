require "open3"
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
  Result = Data.define(
    :ran, :consistent, :reason, :grader_name, :command, :normal_command,
    :files, :repeats, :pass_count, :fail_count, :runs, :env
  ) do
    def inconsistent? = ran && !consistent
  end

  DEFAULT_REPEATS = 5
  TIMEOUT_SECONDS = 10.minutes
  OUTPUT_INLINE_BYTES = 8 * 1024
  DIAGNOSTIC_ENV_KEYS = %w[
    RAILS_ENV COVERAGE BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_USER_HOME
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

    @log.call("[flaky_gate:#{grader_name}] rerunning #{@touched_files.join(', ')} #{@repeats}x: #{redacted_command(command)}")
    outcomes = Array.new(@repeats) { run_once(command) }
    pass_count = outcomes.count { |outcome| outcome.fetch("passed") }
    fail_count = outcomes.size - pass_count
    # The owning grader's normal command already passed immediately before
    # this check. Any failed focused rerun therefore disagrees with an observed
    # pass, including the important case where every repeat fails.
    consistent = fail_count.zero?
    reason = classify_outcome(outcomes, consistent: consistent)

    @log.call("[flaky_gate:#{grader_name}] #{pass_count}/#{outcomes.size} passed (#{reason})")

    Result.new(
      ran: true,
      consistent: consistent,
      reason: reason,
      grader_name: grader_name,
      command: redacted_command(command),
      normal_command: redacted_command(grader_command),
      files: @touched_files,
      repeats: outcomes.size,
      pass_count: pass_count,
      fail_count: fail_count,
      runs: outcomes,
      env: diagnostic_env
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
      return command.to_s.strip if command.to_s.strip.present?
    rescue StandardError => e
      @log.call("[flaky_gate:#{grader_name}] focused_test_command #{provider} declined with #{e.class}: #{e.message}")
    end
    nil
  end

  def run_once(command)
    status = nil
    output = +""
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Timeout.timeout(TIMEOUT_SECONDS) do
      output, status = Open3.capture2e(repeat_env, "bash", "-c", command, chdir: @workspace_path)
    end
    diagnostic_for(status: status, output: output, duration_s: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)
  rescue Timeout::Error
    @log.call("[flaky_gate:#{grader_name}] repeat run timed out after #{TIMEOUT_SECONDS.to_i}s")
    diagnostic_for(status: nil, output: "[flaky_gate] timed out after #{TIMEOUT_SECONDS.to_i}s\n", timed_out: true, duration_s: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)
  end

  def grader_name = @grader_step.details.to_h["name"].to_s
  def grader_command = @grader_step.details.to_h["command"].to_s

  def diagnostic_for(status:, output:, timed_out: false, duration_s:)
    {
      "passed" => status&.success? || false,
      "exit_status" => status&.exitstatus,
      "timed_out" => timed_out,
      "duration_s" => duration_s.round(3),
      "output" => output_tail(output)
    }
  end

  def classify_outcome(outcomes, consistent:)
    return "repeat_run_consistent" if consistent

    timed_out_consistently = outcomes.all? { |outcome| outcome.fetch("timed_out") }
    return "focused_command_timed_out_consistently" if timed_out_consistently

    failed = outcomes.reject { |outcome| outcome.fetch("passed") }
    statuses = failed.map { |outcome| outcome["exit_status"] }.compact.uniq
    return "focused_command_invalid" if failed.size == outcomes.size && (statuses & [ 126, 127 ]).any?
    return "focused_command_failed_consistently" if failed.size == outcomes.size

    "repeat_run_inconsistent"
  end

  def repeat_env
    @repeat_env ||= @env.merge(grader_inline_env)
  end

  def grader_inline_env
    Shellwords.split(grader_command).each_with_object({}) do |token, env|
      match = token.match(/\A([A-Z_][A-Z0-9_]*)=(.*)\z/)
      next unless match

      key = match[1]
      next unless DIAGNOSTIC_ENV_KEYS.include?(key)

      env[key] = expand_inline_env_value(key, match[2])
    end
  rescue ArgumentError => e
    @log.call("[flaky_gate:#{grader_name}] could not parse grader env assignments: #{e.message}")
    {}
  end

  def expand_inline_env_value(key, value)
    default_match = value.match(/\A\$\{#{Regexp.escape(key)}:-(.*)\}\z/)
    return (@env[key].presence || default_match[1]) if default_match

    value.gsub("${PWD}", @workspace_path).gsub("$PWD", @workspace_path)
  end

  def diagnostic_env
    DIAGNOSTIC_ENV_KEYS.each_with_object({}) do |key, env|
      value = repeat_env[key]
      env[key] = redact_env_value(key, value) if value.present?
    end
  end

  def redact_env_value(key, value)
    return "[REDACTED]" if key.match?(/TOKEN|PASSWORD|SECRET|KEY/i)

    value.to_s
  end

  def output_tail(output)
    text = output.to_s
    text = text.safe_byteslice(-OUTPUT_INLINE_BYTES, OUTPUT_INLINE_BYTES) if text.bytesize > OUTPUT_INLINE_BYTES
    text
      .to_s
      .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
  end

  def redacted_command(command)
    command.to_s.gsub(/(token|password|secret|key)=\S+/i, '\1=[REDACTED]')
  end

  def skipped(reason)
    Result.new(
      ran: false, consistent: true, reason: reason, grader_name: grader_name,
      command: nil, normal_command: redacted_command(grader_command),
      files: @touched_files, repeats: 0, pass_count: 0, fail_count: 0,
      runs: [], env: diagnostic_env
    )
  end
end
