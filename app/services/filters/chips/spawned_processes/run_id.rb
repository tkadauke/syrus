module Filters
  module Chips
    module SpawnedProcesses
      class RunId < Base
        filter_name "run_id"
        label "Run ID"
        bucket :string
        operators :is

        def apply
          case op
          when :is then scope.where(run_id: value)
          else unsupported_op!
          end
        end
      end
    end
  end
end
