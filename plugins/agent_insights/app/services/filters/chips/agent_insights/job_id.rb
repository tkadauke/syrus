module Filters
  module Chips
    module AgentInsights
      class JobId < Syrus::Host::Filters::Chips::FkColumn
        filter_name "job_id"
        label "Job"
        column :job_id
      end
    end
  end
end
