module Filters
  module Chips
    module Epics
      class Number < NumberColumn
        filter_name "number"
        label "Number"
        column :number
        operators :equals, :not_equals, :greater_than, :less_than, :between
      end
    end
  end
end
