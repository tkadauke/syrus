module Filters
  module Chips
    module AgentActivity
      class Status < EnumColumn
        filter_name "status"
        label "Status"
        column :state
        operators :is_one_of
        values "queued", "running", "succeeded", "failed", "cancelled", "skipped"
      end
    end
  end
end
