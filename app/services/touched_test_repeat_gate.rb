require "fileutils"
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
  Result = Data.define(:ran, :consistent, :reason, :grader_name, :command, :files, :repeats, :pass_count, :fail_count) do
    def inconsistent? = ran && !consistent
  end

  LOCKS_MUTEX = Mutex.new
  LOCKS = Hash.new { |locks, key| locks[key] = Mutex.new }

  DEFAULT_REPEATS = 5
  TIMEOUT_SECONDS = 10.minutes

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
    outcomes = with_workspace_lock { Array.new(@repeats) { run_once(command) } }
    pass_count = outcomes.count(&:itself)
    fail_count = outcomes.size - pass_count
    # This gate detects flakiness, not every possible focused-rerun mismatch.
    # If the repeat command always passes or always fails, the repeats agree;
    # mixed outcomes are the actionable day-one flake signal.
    consistent = pass_count.zero? || fail_count.zero?

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
      return command.to_s.strip if command.to_s.strip.present?
    rescue StandardError => e
      @log.call("[flaky_gate:#{grader_name}] focused_test_command #{provider} declined with #{e.class}: #{e.message}")
    end
    nil
  end

  def run_once(command)
    status = nil
    Timeout.timeout(TIMEOUT_SECONDS) do
      _output, status = Open3.capture2e(@env, "bash", "-c", command, chdir: @workspace_path)
    end
    status&.success? || false
  rescue Timeout::Error
    @log.call("[flaky_gate:#{grader_name}] repeat run timed out after #{TIMEOUT_SECONDS.to_i}s")
    false
  end

  def with_workspace_lock
    lock_dir = File.join(@workspace_path, ".syrus")
    FileUtils.mkdir_p(lock_dir)
    lock_path = File.join(lock_dir, "touched_test_repeat_gate.lock")
    mutex_for(lock_path).synchronize do
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) if lock
      end
    end
  end

  def mutex_for(lock_path)
    LOCKS_MUTEX.synchronize { LOCKS[lock_path] }
  end

  def grader_name = @grader_step.details.to_h["name"].to_s
  def grader_command = @grader_step.details.to_h["command"].to_s

  def skipped(reason)
    Result.new(
      ran: false, consistent: true, reason: reason, grader_name: grader_name, command: nil,
      files: @touched_files, repeats: 0, pass_count: 0, fail_count: 0
    )
  end
end
