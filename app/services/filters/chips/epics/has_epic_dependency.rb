module Filters
  module Chips
    module Epics
      class HasEpicDependency < BooleanExists
        filter_name "has_epic_dependency"
        label "Has epic dependency"

        def apply
          apply_exists(<<~SQL.squish)
            EXISTS (
              SELECT 1
              FROM epic_dependencies
              INNER JOIN epics dependency_epics ON dependency_epics.id = epic_dependencies.depends_on_epic_id
              WHERE epic_dependencies.epic_id = epics.id
                AND dependency_epics.state != 'done'
            )
          SQL
        end
      end
    end
  end
end
