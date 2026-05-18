module Filters
  module Chips
    module Workflows
      class JobId < FkColumn
        filter_name "job_id"
        label "Job"
        column :job_id
        typeahead true
      end
    end
  end
end
