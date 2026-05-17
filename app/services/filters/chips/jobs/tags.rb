module Filters
  module Chips
    module Jobs
      # Tags are a has-many; the operator set is the standard collection
      # vocabulary. `contains_all` is a GROUP BY + HAVING so multi-tag
      # filters don't fight with each other via repeated joins.
      class Tags < Base
        filter_name "tags"
        label "Tags"
        bucket :collection
        operators :contains_any, :contains_all, :contains_none, :is_empty, :is_not_empty

        def apply
          ids = Array(value).map(&:to_i).reject(&:zero?)
          case op
          when :contains_any  then contains_any(ids)
          when :contains_all  then contains_all(ids)
          when :contains_none then contains_none(ids)
          when :is_empty      then scope.where.missing(:job_tags)
          when :is_not_empty  then scope.where(id: Job.joins(:job_tags).select(:id))
          else unsupported_op!
          end
        end

        private

        def contains_any(ids)
          return scope if ids.empty?

          scope.joins(:job_tags).where(job_tags: { tag_id: ids }).distinct
        end

        def contains_all(ids)
          return scope if ids.empty?

          # HAVING-style: only jobs that join to every requested tag.
          # Distinct count of matching tag_ids must equal the set size.
          matching_ids = Job.joins(:job_tags)
                            .where(job_tags: { tag_id: ids })
                            .group(:id)
                            .having("COUNT(DISTINCT job_tags.tag_id) = ?", ids.size)
                            .select(:id)
          scope.where(id: matching_ids)
        end

        def contains_none(ids)
          return scope if ids.empty?

          tagged = Job.joins(:job_tags).where(job_tags: { tag_id: ids }).select(:id)
          scope.where.not(id: tagged)
        end
      end
    end
  end
end
