module Filters
  module Chips
    module Jobs
      class HasStartBlockedReason < Base
        filter_name "has_start_blocked_reason"
        label "Start blocked"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          blocked = Workflow.queued
                            .where("artifacts LIKE ?", '%"start_blocked_reason"%')
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
