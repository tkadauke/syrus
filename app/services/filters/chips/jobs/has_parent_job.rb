module Filters
  module Chips
    module Jobs
      # "Has a parent" = stacked on another Job's branch.
      class HasParentJob < Base
        filter_name "has_parent_job"
        label "Has parent"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          case op
          when :is_true  then scope.where.not(parent_job_id: nil)
          when :is_false then scope.where(parent_job_id: nil)
          else unsupported_op!
          end
        end
      end
    end
  end
end
