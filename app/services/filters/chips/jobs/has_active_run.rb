module Filters
  module Chips
    module Jobs
      # "Active" matches Run's scope: queued / running.
      class HasActiveRun < Base
        filter_name "has_active_run"
        label "Has active run"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          # Materialized rather than a subquery — see Run.active_job_ids.
          active = Run.active_job_ids
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
