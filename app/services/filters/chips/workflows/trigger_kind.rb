module Filters
  module Chips
    module Workflows
      class TriggerKind < EnumColumn
        filter_name "trigger_kind"
        label "Trigger"
        column :trigger_kind
        values(*(Workflow::TRIGGER_KINDS - %w[resume]))
      end
    end
  end
end
