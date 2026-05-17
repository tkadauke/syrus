module Filters
  module Chips
    module Jobs
      class PrNumber < NumberColumn
        filter_name "pr_number"
        label "PR number"
        column :pr_number
      end
    end
  end
end
