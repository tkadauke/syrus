module Filters
  module Chips
    module AgentInsights
      class UserId < FkColumn
        filter_name "user_id"
        label "User"
        column :user_id

        def apply
          relation = scope.joins(:job)
          case op
          when :is then relation.where(jobs: { user_id: value })
          when :is_not then relation.where.not(jobs: { user_id: value })
          when :is_one_of then relation.where(jobs: { user_id: Array(value) })
          when :is_none_of then relation.where.not(jobs: { user_id: Array(value) })
          when :is_set then relation.where.not(jobs: { user_id: nil })
          when :is_unset then relation.where(jobs: { user_id: nil })
          else unsupported_op!
          end
        end
      end
    end
  end
end
