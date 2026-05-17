module Filters
  module Chips
    module Epics
      class HasOpenChildren < BooleanExists
        filter_name "has_open_children"
        label "Has open children"

        def apply
          apply_exists("EXISTS (SELECT 1 FROM jobs WHERE jobs.epic_id = epics.id AND jobs.state = ?)", "open")
        end
      end
    end
  end
end
