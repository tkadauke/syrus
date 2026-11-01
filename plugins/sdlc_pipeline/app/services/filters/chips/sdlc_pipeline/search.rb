module Filters
  module Chips
    module SdlcPipeline
      class Search < Base
        filter_name "search"
        label "Search"
        bucket :string
        operators :contains
        free_text_search true

        def apply
          unsupported_op! unless op == :contains
          pattern = "%#{Job.sanitize_sql_like(value.to_s.strip)}%"
          scope.left_joins(:epic).where(
            "jobs.issue_title LIKE :pattern OR CAST(jobs.id AS CHAR) LIKE :pattern OR " \
            "CAST(jobs.issue_number AS CHAR) LIKE :pattern OR epics.title LIKE :pattern OR CAST(epics.id AS CHAR) LIKE :pattern",
            pattern: pattern
          )
        end
      end
    end
  end
end
