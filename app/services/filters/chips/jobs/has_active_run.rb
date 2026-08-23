module Filters
  module Chips
    module Jobs
      class HasActiveRun < Base
        filter_name "has_active_run"
        label "Has active run"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          active = Run.active_job_ids.to_set
          case op
          when :is_true  then scope.where(id: active)
          when :is_false then scope.where.not(id: active)
          else unsupported_op!
          end
        end
      end
    end
  end
end
