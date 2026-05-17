module Filters
  module Chips
    module Jobs
      class Title < StringColumn
        filter_name "title"
        label "Title"
        column :issue_title
      end
    end
  end
end
