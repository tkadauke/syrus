module Filters
  module Chips
    module AgentInsights
      class CreatedJobId < FkColumn
        filter_name "created_job_id"
        label "Created job ID"
        column :created_job_id
      end
    end
  end
end
