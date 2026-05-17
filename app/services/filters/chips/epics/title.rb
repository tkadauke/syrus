module Filters
  module Chips
    module Epics
      class Title < StringColumn
        filter_name "title"
        label "Title"
        column :title
      end
    end
  end
end
