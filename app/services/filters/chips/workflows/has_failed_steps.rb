module Filters
  module Chips
    module Workflows
      class HasFailedSteps < Base
        filter_name "has_failed_steps"
        label "Has failed steps"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          failed_step_workflows = Step.where(state: "failed").select(:workflow_id)
          case op
          when :is_true  then scope.where(id: failed_step_workflows)
          when :is_false then scope.where.not(id: failed_step_workflows)
          else unsupported_op!
          end
        end
      end
    end
  end
end
