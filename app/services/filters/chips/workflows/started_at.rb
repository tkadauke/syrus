module Filters
  module Chips
    module Workflows
      class StartedAt < DateColumn
        filter_name "started_at"
        label "Started"
        column :started_at
      end
    end
  end
end
