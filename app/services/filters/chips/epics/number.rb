module Filters
  module Chips
    module Epics
      class Number < NumberColumn
        filter_name "number"
        label "Number"
        column :number
      end
    end
  end
end
