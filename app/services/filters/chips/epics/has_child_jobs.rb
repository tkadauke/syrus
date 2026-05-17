module Filters
  module Chips
    module Epics
      class HasChildJobs < BooleanExists
        filter_name "has_child_jobs"
        label "Has child jobs"

        def apply
          apply_exists("EXISTS (SELECT 1 FROM jobs WHERE jobs.epic_id = epics.id)")
        end
      end
    end
  end
end
