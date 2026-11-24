module Filters
  module Chips
    module WorkerTimeline
      class JobType < Syrus::Host::Filters::Chips::Base
        filter_name "job_type"
        label "Job type"
        bucket :enum
        operators :is_one_of
        values({ "value" => "user", "label" => "User" }, { "value" => "system", "label" => "Infrastructure" })

        def apply
          case op
          when :is_one_of
            scope.joins(:job).where(jobs: { kind: job_kinds })
          else
            unsupported_op!
          end
        end

        private

        def job_kinds
          {
            "system" => Syrus::Host::Filters::Chips::Jobs::JobType.system_kinds,
            "user" => Syrus::Host::Filters::Chips::Jobs::JobType.user_kinds
          }.values_at(*Array(value)).flatten.uniq
        end
      end
    end
  end
end
