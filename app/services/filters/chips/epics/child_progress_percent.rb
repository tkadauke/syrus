module Filters
  module Chips
    module Epics
      class ChildProgressPercent < CalculatedNumber
        filter_name "child_progress_percent"
        label "Child progress percent"

        def apply
          apply_expression(<<~SQL.squish)
            (
              SELECT CASE
                WHEN COUNT(*) = 0 THEN 0
                ELSE (100.0 * SUM(CASE WHEN jobs.closure_reason IN ('pr_merged', 'external_pr_merged') THEN 1 ELSE 0 END) / COUNT(*))
              END
              FROM jobs
              WHERE jobs.epic_id = epics.id
            )
          SQL
        end
      end
    end
  end
end
