# Detects test files added or modified in a Job's diff against its effective
# base branch -- the narrow set TouchedTestRepeatGate reruns a few extra
# times to catch a test that is flaky from the day it was written, as opposed
# to a blanket whole-suite rerun policy.
#
# Deliberately file-granularity, not example-granularity: Ruby::FocusedTestCommand
# (the :focused_test_command provider that turns this file list into an actual
# rerun command) already operates at file granularity, so matching that grain
# here keeps "what gets rerun" predictable from "what changed" without needing
# a per-language AST walk to find the enclosing example for a changed line.
class TouchedTestFiles
  TEST_FILE_PATTERNS = [
    /_spec\.rb\z/,
    /_test\.rb\z/,
    /\.(?:spec|test)\.[jt]sx?\z/,
    /(?:^|\/)test_[^\/]+\.py\z/,
    /_test\.py\z/,
    /_test\.go\z/
  ].freeze

  def self.call(...) = new(...).call

  def initialize(workspace_path:, base_ref:)
    @workspace_path = workspace_path.to_s
    @base_ref = base_ref.to_s
  end

  def call
    return [] if @base_ref.blank?

    diff_entries.select { |entry| test_file?(entry[:path]) }.map { |entry| entry[:path] }.uniq.sort
  end

  private

  # `--name-status` (not `--name-only`) so a deleted spec file can be
  # excluded -- there is nothing to rerun for it, and running it anyway would
  # report a spurious "new flakiness" failure for a file that no longer exists.
  def diff_entries
    output = GitRunner.new.run("diff", "--name-status", "#{@base_ref}...HEAD", chdir: @workspace_path)
    output.split("\n").filter_map do |line|
      status, *paths = line.split("\t")
      next if status.blank? || status.start_with?("D")

      path = paths.last.to_s
      next if path.blank?

      { status: status[0], path: path }
    end
  rescue GitRunner::GitError
    []
  end

  def test_file?(path)
    TEST_FILE_PATTERNS.any? { |pattern| path.match?(pattern) }
  end
end
