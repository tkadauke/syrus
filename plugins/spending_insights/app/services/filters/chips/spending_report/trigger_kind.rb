module Filters
  module Chips
    module SpendingReport
      class TriggerKind < EnumColumn
        filter_name "trigger_kind"
        label "Trigger"
        column :trigger_kind
        # Resolved per call, not frozen at load: plugins contribute trigger
        # kinds, and a chip list captured at autoload time would never show
        # one enabled afterwards.
        def self.values(*list)
          list.any? ? super : (::Workflow::TriggerKind.values - %w[resume])
        end
      end
    end
  end
end
