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
          query = value.to_s.strip
          pattern = "%#{Job.sanitize_sql_like(query)}%"
          relation = scope.left_joins(:epic)
          matches = relation.where(
            "jobs.issue_title LIKE :pattern OR CAST(jobs.id AS CHAR) LIKE :pattern OR " \
            "CAST(jobs.issue_number AS CHAR) LIKE :pattern OR epics.title LIKE :pattern OR CAST(epics.id AS CHAR) LIKE :pattern",
            pattern: pattern
          )
          job_ids = query.scan(/\bJOB-(\d+)\b/i).flatten.map(&:to_i).uniq
          epic_numbers = query.scan(/\bEPIC-(\d+)\b/i).flatten.map(&:to_i).uniq
          matches = matches.or(relation.where(jobs: { id: job_ids })) if job_ids.any?
          matches = matches.or(relation.where(epics: { number: epic_numbers })) if epic_numbers.any?
          matches
        end
      end
    end
  end
end
