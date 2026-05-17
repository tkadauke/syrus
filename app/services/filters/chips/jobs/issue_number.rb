module Filters
  module Chips
    module Jobs
      class IssueNumber < NumberColumn
        filter_name "issue_number"
        label "Issue number"
        column :issue_number
      end
    end
  end
end
