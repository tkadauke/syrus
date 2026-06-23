module Filters
  module Chips
    module Epics
      class HasEpicDependency < BooleanExists
        filter_name "has_epic_dependency"
        label "Has epic dependency"

        def apply
          apply_exists(<<~SQL.squish, Job::SUCCESSFUL_CLOSURE_REASONS)
            EXISTS (
              SELECT 1
              FROM epic_dependencies
              LEFT JOIN epics dependency_epics ON dependency_epics.id = epic_dependencies.depends_on_epic_id
              LEFT JOIN jobs dependency_jobs ON dependency_jobs.id = epic_dependencies.depends_on_job_id
              WHERE epic_dependencies.epic_id = epics.id
                AND (
                  (
                    epic_dependencies.depends_on_epic_id IS NOT NULL
                    AND dependency_epics.state != 'done'
                  )
                  OR (
                    epic_dependencies.depends_on_job_id IS NOT NULL
                    AND (
                      dependency_jobs.id IS NULL
                      OR dependency_jobs.state != 'closed'
                      OR dependency_jobs.closure_reason NOT IN (?)
                    )
                  )
                )
            )
          SQL
        end
      end
    end
  end
end
