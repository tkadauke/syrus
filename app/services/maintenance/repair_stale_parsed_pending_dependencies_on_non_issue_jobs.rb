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

      stale_dependencies.find_each do |dependency|
        next if dependency.referenced_epic

        job = dependency.job
        ref = dependency.unresolved_slug
        affected_open_job_ids << job.id if job.open?

        Rails.logger.info(
          "[JobDependencyRepair] removed stale parsed pending dependency " \
          "job_id=#{job.id} unresolved_ref=#{ref}"
        )
        dependency.destroy!
        removed_count += 1
      end

      restarted_job_ids = restart_affected_jobs(affected_open_job_ids)
      Result.new(removed_count:, restarted_job_ids:)
    end

    private

    def stale_dependencies
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

    def restart_affected_jobs(job_ids)
      restarted = []

      Job.where(id: job_ids.to_a).find_each do |job|
        restarted << job.id if job.start_pending_workflows_if_dependencies_satisfied!
      end

      restarted
    end
  end
end
