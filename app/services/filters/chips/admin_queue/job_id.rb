module Filters
  module Chips
    module AdminQueue
      class JobId < Base
        filter_name "job_id"
        label "Job ID"
        bucket :number
        operators :is

        def apply
          id = Integer(value, exception: false)
          return scope.none unless id

          scope.where(job_id_column => id)
        end

        private

        def job_id_column
          scope.klass == SolidQueue::FailedExecution ? :job_id : :id
        end
      end
    end
  end
end
