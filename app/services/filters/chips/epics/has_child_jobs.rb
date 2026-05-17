module Filters
  module Chips
    module Epics
      class HasChildJobs < Predicate
        filter_name "has_child_jobs"
        label "Has child Jobs"

        private

        def matching_ids
          Job.where.not(epic_id: nil).select(:epic_id)
        end
      end
    end
  end
end
