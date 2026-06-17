module Filters
  module Chips
    module Jobs
      class HasLandingFailure < Base
        filter_name "has_landing_failure"
        label "Has landing failure"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          failed_landing = Job.open_threads.where.not(landing_failure_reason: nil).select(:id)

          case op
          when :is_true  then scope.where(id: failed_landing)
          when :is_false then scope.where.not(id: failed_landing)
          else unsupported_op!
          end
        end
      end
    end
  end
end
