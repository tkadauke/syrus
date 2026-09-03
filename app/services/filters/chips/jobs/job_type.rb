module Filters
  module Chips
    module Jobs
      # Discriminates between user-facing jobs (issue, cron, direct) and
      # system/infrastructure jobs (main_grader, agent_insight, deploy). Most
      # predefined smart folders include a `job_type: user` chip so
      # infrastructure jobs stay out of the operator's normal view; the "All
      # jobs" link and user-created folders without this chip will surface
      # all kinds.
      class JobType < Base
        filter_name "job_type"
        label "Job type"
        bucket :enum
        operators :is, :is_not

        values "user", "system"

        # Resolved per call rather than frozen at load: plugins contribute Job
        # kinds, and an infrastructure kind must not leak into the operator's
        # user-facing lists just because its plugin registered after this class.
        def self.system_kinds = Job::Kind.infrastructure_values
        def self.user_kinds = Job::Kind.user_facing_values

        def apply
          case op
          when :is
            case value.to_s
            when "user"   then scope.where(kind: Job::Kind.user_facing_values)
            when "system" then scope.where(kind: Job::Kind.infrastructure_values)
            else scope
            end
          when :is_not
            case value.to_s
            when "user"   then scope.where(kind: Job::Kind.infrastructure_values)
            when "system" then scope.where(kind: Job::Kind.user_facing_values)
            else scope
            end
          else
            unsupported_op!
          end
        end
      end
    end
  end
end
