module Filters
  module Chips
    module Epics
      class ChildProgressPercent < ChildJobCount
        filter_name "child_progress_percent"
        label "Child progress"

        private

        def metric_sql
          success = Epic::MERGED_JOB_CLOSURE_REASONS.map { |reason| scope.connection.quote(reason) }.join(", ")
          "CASE WHEN COUNT(jobs.id) = 0 THEN 0 ELSE (100 * SUM(CASE WHEN jobs.closure_reason IN (#{success}) THEN 1 ELSE 0 END) / COUNT(jobs.id)) END"
        end
      end
    end
  end
end
