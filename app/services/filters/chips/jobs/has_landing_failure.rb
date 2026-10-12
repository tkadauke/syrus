module Filters
  module Chips
    module Jobs
      class HasLandingFailure < Base
        filter_name "has_landing_failure"
        label "Has landing failure"
        bucket :boolean
        operators :is_true, :is_false

        def self.failed_landing_scope(base = Job.open_threads)
          base.where.not(landing_failure_reason: nil)
              .where(
                "landing_failure_code IS NULL AND landing_failure_reason NOT LIKE ? OR landing_failure_code != ?",
                "#{LandingQueueReentry::START_BLOCKER_PREFIX}%",
                LandingFailureCode::LANDING_START_BLOCKED
              )
        end

        def apply
          failed_landing = self.class.failed_landing_scope.select(:id)

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
