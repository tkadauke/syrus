module Filters
  module Chips
    module SdlcPipeline
      class JobId < FkColumn
        filter_name "job_id"
        label "Job"
        column :id
      end
    end
  end
end
