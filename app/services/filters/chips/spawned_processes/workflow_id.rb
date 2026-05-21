module Filters
  module Chips
    module SpawnedProcesses
      class WorkflowId < Base
        filter_name "workflow_id"
        label "Workflow ID"
        bucket :string
        operators :is

        def apply
          case op
          when :is then scope.where(workflow_id: value)
          else unsupported_op!
          end
        end
      end
    end
  end
end
