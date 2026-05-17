module Filters
  module Chips
    module Epics
      class State < EnumColumn
        filter_name "state"
        label "State"
        column :state
        values(*Epic::STATES)
      end
    end
  end
end
