require "set"

module Maintenance
  class RepairStaleParsedPendingDependenciesOnNonIssueJobs
    Result = Data.define(:removed_count, :restarted_job_ids)

    def self.call
      new.call
    end

    def call
      removed_count = 0
      affected_open_job_ids = Set.new
      run_counts_before_cleanup = {}

      resolvable_proposal_dependencies.find_each do |dependency|
        job = dependency.job
        proposal = dependency.unresolved_chat_proposal
        track_affected_open_job!(job, affected_open_job_ids, run_counts_before_cleanup)

        dependency.resolve!(depends_on_job: proposal.job)
        Rails.logger.info(
          "[JobDependencyRepair] resolved pending proposal dependency " \
          "job_id=#{job.id} unresolved_ref=#{proposal.slug} depends_on_job_id=#{proposal.job_id}"
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn(
          "[JobDependencyRepair] failed to resolve pending proposal dependency " \
          "job_id=#{dependency.job_id} unresolved_ref=#{dependency.unresolved_slug}: #{e.message}"
        )
      end

      stale_parsed_dependencies.find_each do |dependency|
        next if dependency.referenced_epic

        job = dependency.job
        ref = dependency.unresolved_slug
        track_affected_open_job!(job, affected_open_job_ids, run_counts_before_cleanup)

        Rails.logger.info(
          "[JobDependencyRepair] removed stale parsed pending dependency " \
          "job_id=#{job.id} unresolved_ref=#{ref}"
        )
        dependency.destroy!
        removed_count += 1
      end

      stale_proposal_dependencies.find_each do |dependency|
        job = dependency.job
        ref = dependency.unresolved_slug
        track_affected_open_job!(job, affected_open_job_ids, run_counts_before_cleanup)

        Rails.logger.info(
          "[JobDependencyRepair] removed stale pending proposal dependency " \
          "job_id=#{job.id} unresolved_ref=#{ref}"
        )
        dependency.destroy!
        removed_count += 1
      end

      restarted_job_ids = restart_affected_jobs(affected_open_job_ids, run_counts_before_cleanup)
      Result.new(removed_count:, restarted_job_ids:)
    end

    private

    def track_affected_open_job!(job, affected_open_job_ids, run_counts_before_cleanup)
      return unless job.open?

      affected_open_job_ids << job.id
      run_counts_before_cleanup[job.id] ||= job.runs.count
    end

    def stale_parsed_dependencies
      JobDependency
        .pending
        .parsed
        .joins(:job)
        .where.not(jobs: { kind: "issue" })
        .where(unresolved_chat_proposal_id: nil)
        .where.not(unresolved_owner: nil)
        .where.not(unresolved_repo: nil)
        .where.not(unresolved_number: nil)
    end

    def resolvable_proposal_dependencies
      JobDependency
        .pending
        .joins(:unresolved_chat_proposal)
        .where.not(chat_proposals: { job_id: nil })
    end

    def stale_proposal_dependencies
      JobDependency
        .pending
        .left_joins(:unresolved_chat_proposal)
        .where.not(unresolved_chat_proposal_id: nil)
        .where(
          "chat_proposals.id IS NULL OR chat_proposals.state IN (?) OR " \
          "(chat_proposals.state = ? AND chat_proposals.job_id IS NULL)",
          %w[rejected withdrawn],
          "confirmed"
        )
    end

    def restart_affected_jobs(job_ids, run_counts_before_cleanup)
      restarted = []

      Job.where(id: job_ids.to_a).find_each do |job|
        started = job.start_pending_workflows_if_dependencies_satisfied!
        restarted << job.id if started || job.runs.count > run_counts_before_cleanup.fetch(job.id, 0)
      end

      restarted
    end
  end
end
