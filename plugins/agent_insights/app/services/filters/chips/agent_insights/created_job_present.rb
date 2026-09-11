module Filters
  module Chips
    module AgentInsights
      class CreatedJobPresent < BooleanColumn
        filter_name "created_job_present"
        label "Created job"
        true_scope :with_created_job
        false_scope :without_created_job
      end
    end
  end
end
