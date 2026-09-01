module Filters
  module Chips
    module WorkerTimeline
      class JobType < Base
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
            "system" => Filters::Chips::Jobs::JobType::SYSTEM_KINDS,
            "user" => Filters::Chips::Jobs::JobType::USER_KINDS
          }.values_at(*Array(value)).flatten.uniq
        end
      end
    end
  end
end
