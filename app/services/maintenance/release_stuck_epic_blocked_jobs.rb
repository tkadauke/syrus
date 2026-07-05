module Maintenance
  class ReleaseStuckEpicBlockedJobs
    Result = Data.define(:released_count, :skipped_count)

    def self.call
      new.call
    end

    def call
      released = 0
      skipped = 0

      Job.where(state: "blocked_by_epic").find_each do |job|
        if job.start_pending_workflows_if_dependencies_satisfied!
          Rails.logger.info("[ReleaseStuckEpicBlockedJobs] released job_id=#{job.id}")
          released += 1
        else
          skipped += 1
        end
      rescue StandardError => e
        Rails.logger.error("[ReleaseStuckEpicBlockedJobs] error job_id=#{job.id}: #{e.class}: #{e.message}")
        skipped += 1
      end

      Result.new(released_count: released, skipped_count: skipped)
    end
  end
end
