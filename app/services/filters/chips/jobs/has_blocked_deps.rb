module Filters
  module Chips
    module Jobs
      # A Job has "blocked deps" when it has at least one JobDependency
      # row that's either pending or resolved-but-the-dep-isn't-merged.
      # Mirrors Filters::Chips::Jobs::Attention#blocked_dependency_ids.
      class HasBlockedDeps < Base
        filter_name "has_blocked_deps"
        label "Has blocked deps"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          successful = Job.closed_threads.where(closure_reason: Job::SUCCESSFUL_CLOSURE_REASONS)
          done_epics = Epic.where(state: "done")
          blocked = JobDependency.pending
                                 .or(JobDependency.resolved.where.not(depends_on_job_id: successful.select(:id)))
                                 .or(JobDependency.where.not(depends_on_epic_id: nil).where.not(depends_on_epic_id: done_epics.select(:id)))
                                 .select(:job_id)
          case op
          when :is_true  then scope.where(id: blocked)
          when :is_false then scope.where.not(id: blocked)
          else unsupported_op!
          end
        end
      end
    end
  end
end
