module Filters
  module Chips
    module SpendingReport
      class TriggerKind < EnumColumn
        filter_name "trigger_kind"
        label "Trigger"
        column :trigger_kind
        values(*(Run::TRIGGER_KINDS - %w[resume]))
      end
    end
  end
end
