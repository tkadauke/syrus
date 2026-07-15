module Filters
  module Chips
    module Jobs
      # Discriminates between user-facing jobs (issue, cron, direct) and
      # system/infrastructure jobs (main_grader). Most predefined smart
      # folders include a `job_type: user` chip so infrastructure jobs
      # stay out of the operator's normal view; the "All jobs" link and
      # user-created folders without this chip will surface all kinds.
      class JobType < Base
        filter_name "job_type"
        label "Job type"
        bucket :enum
        operators :is, :is_not

        SYSTEM_KINDS = %w[main_grader].freeze
        USER_KINDS = (Job::KINDS - SYSTEM_KINDS).freeze

        values "user", "system"

        def apply
          case op
          when :is
            case value.to_s
            when "user"   then scope.where(kind: USER_KINDS)
            when "system" then scope.where(kind: SYSTEM_KINDS)
            else scope
            end
          when :is_not
            case value.to_s
            when "user"   then scope.where(kind: SYSTEM_KINDS)
            when "system" then scope.where(kind: USER_KINDS)
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
