module Filters
  module Chips
    module Epics
      class HasEpicDependency < Predicate
        filter_name "has_epic_dependency"
        label "Has Epic dependency"

        private

        def matching_ids
          EpicDependency.where.not(depends_on_epic_id: Epic.where(state: "done").select(:id)).select(:epic_id)
        end
      end
    end
  end
end
