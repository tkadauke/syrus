module Filters
  module Chips
    module Epics
      class HasBlockedChildren < BooleanExists
        filter_name "has_blocked_children"
        label "Has blocked children"

        def apply
          apply_exists(<<~SQL.squish, Job::SUCCESSFUL_CLOSURE_REASONS)
            EXISTS (
              SELECT 1
              FROM jobs child_jobs
              INNER JOIN job_dependencies ON job_dependencies.job_id = child_jobs.id
              LEFT JOIN jobs dependency_jobs ON dependency_jobs.id = job_dependencies.depends_on_job_id
              LEFT JOIN epics dependency_epics ON dependency_epics.id = job_dependencies.depends_on_epic_id
              WHERE child_jobs.epic_id = epics.id
                AND (
                  (
                    job_dependencies.depends_on_job_id IS NULL
                    AND job_dependencies.depends_on_epic_id IS NULL
                  )
                  OR (
                    job_dependencies.depends_on_job_id IS NOT NULL
                    AND (
                      dependency_jobs.id IS NULL
                      OR dependency_jobs.state != 'closed'
                      OR dependency_jobs.closure_reason NOT IN (?)
                    )
                  )
                  OR (
                    job_dependencies.depends_on_epic_id IS NOT NULL
                    AND (
                      dependency_epics.id IS NULL
                      OR dependency_epics.state != 'done'
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
