module Filters
  module Chips
    module Jobs
      # "Has children" = some other Job points at this one as its
      # parent_job_id. Uses an EXISTS subquery via where(id: ...).
      class HasChildJobs < Base
        filter_name "has_child_jobs"
        label "Has children"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          with_children = Job.where.not(parent_job_id: nil).select(:parent_job_id)
          case op
          when :is_true  then scope.where(id: with_children)
          when :is_false then scope.where.not(id: with_children)
          else unsupported_op!
          end
        end
      end
    end
  end
end
