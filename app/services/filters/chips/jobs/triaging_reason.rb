module Filters
  module Chips
    module Jobs
      class TriagingReason < EnumColumn
        filter_name "triaging_reason"
        label "Triaging reason"
        column :triaging_reason
        values(*Job::TRIAGING_REASONS)
      end
    end
  end
end
