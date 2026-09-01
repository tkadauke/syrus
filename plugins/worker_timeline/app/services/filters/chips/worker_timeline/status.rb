module Filters
  module Chips
    module WorkerTimeline
      class Status < EnumColumn
        filter_name "status"
        label "Status"
        column :state
        operators :is_one_of
        values "queued", "running", "succeeded", "failed", "cancelled"
      end
    end
  end
end
