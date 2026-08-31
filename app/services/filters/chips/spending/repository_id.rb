module Filters
  module Chips
    module Spending
      class RepositoryId < Base
        filter_name "repository_id"
        label "Repository"
        bucket :fk
        operators :is, :is_not, :is_one_of, :is_none_of

        def apply
          relation = scope.joins(:job)
          case op
          when :is         then relation.where(jobs: { repository_id: value })
          when :is_not     then relation.where.not(jobs: { repository_id: value })
          when :is_one_of  then relation.where(jobs: { repository_id: Array(value) })
          when :is_none_of then relation.where.not(jobs: { repository_id: Array(value) })
          else unsupported_op!
          end
        end
      end
    end
  end
end
