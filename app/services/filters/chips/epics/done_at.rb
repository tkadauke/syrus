module Filters
  module Chips
    module Epics
      class DoneAt < DateColumn
        filter_name "done_at"
        label "Done"
        column :done_at
      end
    end
  end
end
