module CoverageAnalysis
  # Counts how many commits touched each file within a recent lookback
  # window — the "recent change frequency" signal Skills::CoverageGapReport
  # weights against raw coverage percentage (per the issue driving that
  # skill: a stable low-coverage file is lower priority than a
  # frequently-changed one). Pure git log parsing; no coverage awareness of
  # its own — see RiskRanking for how the two signals combine.
  class ChangeFrequency
    DEFAULT_LOOKBACK_DAYS = 90

    def self.for(workspace_path, lookback_days: DEFAULT_LOOKBACK_DAYS)
      new(workspace_path, lookback_days: lookback_days).call
    end

    def initialize(workspace_path, lookback_days: DEFAULT_LOOKBACK_DAYS)
      @workspace_path = workspace_path.to_s
      @lookback_days = lookback_days
    end

    # Returns { "path/to/file.rb" => Integer } commit counts for every file
    # touched at least once within the lookback window. `--no-merges` keeps
    # a merge commit's full (often unrelated) file list from inflating
    # every touched file's count. Never raises: a workspace with no git
    # history (or any other git failure) yields an empty hash rather than
    # blowing up the report.
    #
    # Relies on `git log --since`'s normal traversal, which walks from HEAD
    # and stops at the first commit older than the cutoff — correct for
    # real repository history, where commit dates are monotonically
    # non-decreasing along a branch.
    def call
      since = @lookback_days.to_i.days.ago.utc.iso8601

      output = GitRunner.new.run(
        "log", "--no-merges", "--since=#{since}", "--name-only", "--pretty=format:",
        chdir: @workspace_path
      )

      output.each_line.each_with_object(Hash.new(0)) do |line, counts|
        path = line.strip
        counts[path] += 1 unless path.empty?
      end
    rescue GitRunner::GitError => e
      Rails.logger.warn("[CoverageAnalysis::ChangeFrequency] git log failed: #{e.message}")
      {}
    end
  end
end
