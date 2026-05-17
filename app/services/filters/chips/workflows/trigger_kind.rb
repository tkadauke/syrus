module Filters
  module Chips
    module Workflows
      class TriggerKind < EnumColumn
        filter_name "trigger_kind"
        label "Trigger"
        column :trigger_kind
        values(*Workflow::TRIGGER_KINDS)
      end
    end
  end
end
