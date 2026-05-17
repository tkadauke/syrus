module Filters
  module Chips
    module Workflows
      class JobId < FkColumn
        filter_name "job_id"
        label "Job"
        column :job_id
      end
    end
  end
end
