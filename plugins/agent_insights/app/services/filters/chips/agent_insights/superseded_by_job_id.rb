module Filters
  module Chips
    module AgentInsights
      class SupersededByJobId < FkColumn
        filter_name "superseded_by_job_id"
        label "Superseded by job ID"
        column :superseded_by_job_id
      end
    end
  end
end
