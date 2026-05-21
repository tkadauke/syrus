module Filters
  module Chips
    module AdminQueue
      class FailedSince < DateColumn
        filter_name "failed_since"
        label "Failed since"
        column :created_at
        operators :within_last
      end
    end
  end
end
