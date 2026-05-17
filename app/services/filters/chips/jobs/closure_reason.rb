module Filters
  module Chips
    module Jobs
      class ClosureReason < EnumColumn
        filter_name "closure_reason"
        label "Closure reason"
        column :closure_reason
        values "pr_merged", "external_pr_merged", "pr_approved", "no_changes",
               "abandoned", "superseded", "cancelled", "manual"
      end
    end
  end
end
