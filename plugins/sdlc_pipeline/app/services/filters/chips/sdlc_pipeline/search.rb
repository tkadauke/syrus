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
          job_ids = canonical_numbers(query, /\bJOB-(\d+)\b/i, model: Job, attribute: :id)
          epic_numbers = canonical_numbers(query, /\bEPIC-(\d+)\b/i, model: Epic, attribute: :number)
          matches = matches.or(relation.where(jobs: { id: job_ids })) if job_ids.any?
          matches = matches.or(relation.where(epics: { number: epic_numbers })) if epic_numbers.any?
          matches
        end

        private

        def canonical_numbers(query, pattern, model:, attribute:)
          type = model.type_for_attribute(attribute.to_s)
          query.scan(pattern).flatten.filter_map do |digits|
            type.serialize(Integer(digits, 10))
          rescue ArgumentError, ActiveModel::RangeError
            nil
          end.uniq
        end
      end
    end
  end
end
