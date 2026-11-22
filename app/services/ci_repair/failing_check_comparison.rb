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
      if checks.any?
        names = checks.flat_map { |check| check_names(check) }
        # A grader-run record stores no CI results (ci_failed_checks nil), so
        # an empty CI list there means "not read yet", not "CI passed". Until
        # the base's own CI result arrives, take CI failures from the newest
        # record that has one -- otherwise main's own red checks read as
        # introduced by every PR built on it.
        names += newest_ci_failure_names unless checks.any? { |check| ci_evidence?(check) }
        return normalize(names)
      end

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

    def ci_evidence?(check)
      !check.ci_failed_checks.nil?
    end

    def newest_ci_failure_names
      latest = MainBranchHealthCheck.where(
        repository_id: job.repository_id,
        branch: job.effective_base_branch
      ).where.not(ci_failed_checks: nil).order(id: :desc).first
      Array(latest&.ci_failed_checks)
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
