module Filters
  module Chips
    module Jobs
      class ClosureReason < EnumColumn
        filter_name "closure_reason"
        label "Closure reason"
        column :closure_reason
        values(*Job::ClosureReason.entries.map { |entry|
          { value: entry.reason, label: entry.reason.humanize, group: entry.category.humanize }
        })

        def self.grouped_values = Job::ClosureReason.grouped_values
      end
    end
  end
end
