module Filters
  module Chips
    module AgentActivity
      class Window < DateColumn
        filter_name "window"
        label "Time window"
        column :started_at
        operators :within_last, :between
      end
    end
  end
end
