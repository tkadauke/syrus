module Filters
  module Chips
    module Memories
      class RepositoryId < Base
        filter_name "repository_id"
        label "Repository"
        bucket :fk
        operators :is, :is_not, :is_one_of, :is_none_of

        def apply
          case op
          when :is
            scope.where(scope: "repository", scope_id: value)
          when :is_not
            scope.where.not(scope: "repository", scope_id: value)
          when :is_one_of
            scope.where(scope: "repository", scope_id: Array(value))
          when :is_none_of
            scope.where.not(scope: "repository", scope_id: Array(value))
          else
            unsupported_op!
          end
        end
      end
    end
  end
end
