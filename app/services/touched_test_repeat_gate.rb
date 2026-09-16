require "open3"
require "timeout"

# Reruns the touched test files TouchedTestFiles finds a few extra times, in
# the current workspace at the current HEAD, and reports whether the results
# agreed -- the repeat-run flakiness gate for newly added or modified tests
# (EPIC-362). A brand-new or freshly-modified test has no run history yet, so
# Adjudicators::KnownFlakyFailure -- which only has signal once a test has
# failed at least twice across real workflows -- cannot tell a test that is
# flaky from day one apart from a genuinely stable one. This asks the
# question directly, once, before the PR merges.
#
# Deliberately outside ProcessRunner/SpawnedProcess, the same tradeoff
# BaseRevisionRetry already accepts: this is an internal grading-adjacent
# check on top of a grader Step that already passed, not the tracked grader
# Step itself.
class TouchedTestRepeatGate
  Result = Data.define(:ran, :consistent, :reason, :grader_name, :command, :files, :repeats, :pass_count, :fail_count) do
    def inconsistent? = ran && !consistent
  end

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
    return skipped("no_focused_command") if command.blank?

    @log.call("[flaky_gate:#{grader_name}] rerunning #{@touched_files.join(', ')} #{@repeats}x: #{command}")
    outcomes = Array.new(@repeats) { run_once(command) }
    pass_count = outcomes.count(&:itself)
    fail_count = outcomes.size - pass_count
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

  # Reuses the same :focused_test_command extension point BaseRevisionRetry
  # uses to build a "just these failed tests" command -- the touched files are
  # passed in the same failed_cases shape (a file_path per entry) a real
  # failure list would use, so each language plugin's own filtering (e.g.
  # Ruby::FocusedTestCommand only claims *_spec.rb paths) naturally scopes the
  # command to the files it understands.
  def focused_command
    Syrus::PluginRegistry.providers_for(:focused_test_command).each do |provider|
      command = provider.command_for(
        grader_name: grader_name,
        grader_command: grader_command,
        failed_cases: @touched_files.map { |path| { "file_path" => path } },
        base_retry: @grader_step.details.to_h["base_retry"]
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

  def grader_name = @grader_step.details.to_h["name"].to_s
  def grader_command = @grader_step.details.to_h["command"].to_s

  def skipped(reason)
    Result.new(
      ran: false, consistent: true, reason: reason, grader_name: grader_name, command: nil,
      files: @touched_files, repeats: 0, pass_count: 0, fail_count: 0
    )
  end
end
