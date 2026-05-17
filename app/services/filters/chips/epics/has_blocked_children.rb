module Filters
  module Chips
    module Epics
      class HasBlockedChildren < Predicate
        filter_name "has_blocked_children"
        label "Has blocked children"

        private

        def matching_ids
          Job.where(id: blocked_job_ids).where.not(epic_id: nil).select(:epic_id)
        end

        def blocked_job_ids
          successful = Job.closed_threads.where(closure_reason: Job::SUCCESSFUL_CLOSURE_REASONS)
          JobDependency.pending
                       .or(JobDependency.resolved.where.not(depends_on_job_id: successful.select(:id)))
                       .select(:job_id)
        end
      end
    end
  end
end
