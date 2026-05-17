module Filters
  module Chips
    module Workflows
      class FailureReason < StringColumn
        filter_name "failure_reason"
        label "Failure reason"
        column :failure_reason
      end
    end
  end
end
