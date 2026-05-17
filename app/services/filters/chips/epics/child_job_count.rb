module Filters
  module Chips
    module Epics
      class ChildJobCount < CalculatedNumber
        filter_name "child_job_count"
        label "Child job count"

        def apply
          apply_expression("(SELECT COUNT(*) FROM jobs WHERE jobs.epic_id = epics.id)")
        end
      end
    end
  end
end
