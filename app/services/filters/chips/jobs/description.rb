module Filters
  module Chips
    module Jobs
      class Description < FullTextStringColumn
        filter_name "description"
        label "Description"
        column :issue_body
      end
    end
  end
end
