module Filters
  module Chips
    module Jobs
      class BranchName < StringColumn
        filter_name "branch_name"
        label "Branch name"
        column :branch_name
      end
    end
  end
end
