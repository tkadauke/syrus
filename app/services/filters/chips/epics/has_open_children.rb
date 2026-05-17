module Filters
  module Chips
    module Epics
      class HasOpenChildren < Predicate
        filter_name "has_open_children"
        label "Has open children"

        private

        def matching_ids
          Job.open_threads.where.not(epic_id: nil).select(:epic_id)
        end
      end
    end
  end
end
