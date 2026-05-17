module Filters
  module Chips
    module Epics
      class Description < StringColumn
        filter_name "description"
        label "Description"
        column :description
      end
    end
  end
end
