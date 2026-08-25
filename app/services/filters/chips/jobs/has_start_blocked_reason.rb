module Filters
  module Chips
    module Jobs
      class HasStartBlockedReason < Base
        filter_name "has_start_blocked_reason"
        label "Start blocked"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          blocked = workflow_blocked_job_ids | WorkUnits::Ownership.all_blocked_job_ids.to_a

          case op
          when :is_true  then scope.where(id: blocked)
          when :is_false then scope.where.not(id: blocked)
          else unsupported_op!
          end
        end

        private

        def workflow_blocked_job_ids
          WorkUnits::Ownership
            .legacy_replay_start_blocked_workflows_scope
            .distinct
            .pluck(:job_id)
        end
      end
    end
  end
end
