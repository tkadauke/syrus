module CiRepair
  class FailingCheckComparison
    def self.call(job:, base_sha:, stacked_parent_fallback: false)
      new(job: job, base_sha: base_sha, stacked_parent_fallback: stacked_parent_fallback).call
    end

    def initialize(job:, base_sha:, stacked_parent_fallback: false)
      @job = job
      @base_sha = base_sha
      @stacked_parent_fallback = stacked_parent_fallback
    end

    def call
      pr_failing = normalize(job.pr_checks_failing_names)
      return nil if pr_failing.empty?

      base_failing = base_failing_check_names
      return nil if base_failing.nil?

      (pr_failing - base_failing).presence
    end

    private

    attr_reader :job, :base_sha, :stacked_parent_fallback

    def base_failing_check_names
      checks = MainBranchHealthCheck.where(
        repository_id: job.repository_id,
        branch: job.effective_base_branch,
        sha: base_sha
      ).to_a
      return normalize(checks.flat_map { |check| check_names(check) }) if checks.any?

      # A stacked base is its parent PR branch, which main-health polling never
      # evaluates. Prefer that parent's check snapshot at the start gate so a
      # failure already red on the parent is not misclassified as introduced.
      # The poller keeps its historical newest-main fallback by leaving this
      # option disabled.
      if stacked_parent_fallback && job.parent_job&.pr_checks_failing_names.present?
        return normalize(job.parent_job.pr_checks_failing_names)
      end

      latest = MainBranchHealthCheck.where(
        repository_id: job.repository_id,
        branch: job.effective_base_branch
      ).order(id: :desc).first
      latest && normalize(check_names(latest))
    end

    def check_names(check)
      Array(check.ci_failed_checks) + Array(check.grader_failed_names)
    end

    def normalize(entries)
      Array(entries).filter_map do |entry|
        entry.is_a?(Hash) ? (entry["name"] || entry[:name]) : entry
      end.map { |name| name.to_s.strip }.reject(&:empty?).uniq
    end
  end
end
