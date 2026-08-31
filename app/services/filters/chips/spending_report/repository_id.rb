module Filters
  module Chips
    module SpendingReport
      class RepositoryId < FkColumn
        filter_name "repository_id"
        label "Repository"
        column :repository_id

        def apply
          joined_scope = scope.joins(:job)
          case op
          when :is then joined_scope.where(jobs: { repository_id: value })
          when :is_not then joined_scope.where.not(jobs: { repository_id: value })
          when :is_one_of then joined_scope.where(jobs: { repository_id: Array(value) })
          when :is_none_of then joined_scope.where.not(jobs: { repository_id: Array(value) })
          when :is_set then joined_scope.where.not(jobs: { repository_id: nil })
          when :is_unset then joined_scope.where(jobs: { repository_id: nil })
          else unsupported_op!
          end
        end
      end
    end
  end
end
