module Filters
  module Chips
    module Workflows
      class TriggerKind < EnumColumn
        filter_name "trigger_kind"
        label "Trigger"
        column :trigger_kind
        values "initial", "pr_comment", "ci_failure", "retry", "manual", "rebase", "resume"
      end
    end
  end
end
