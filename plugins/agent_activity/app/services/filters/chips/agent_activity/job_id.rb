module Filters
  module Chips
    module AgentActivity
      class JobId < FkColumn
        filter_name "job_id"
        label "Job"
        column :job_id

        def apply
          case op
          when :is then scope.where(job_sql(value))
          when :is_one_of then scope.where(job_sql(Array(value)))
          else super
          end
        end

        private

        def job_sql(job_ids)
          ActiveRecord::Base.sanitize_sql_array([
            "agents.resumable_type = 'Run'
             AND EXISTS (
               SELECT 1
               FROM runs
               WHERE runs.id = agents.resumable_id
                 AND runs.job_id IN (?)
             )",
            Array(job_ids)
          ])
        end
      end
    end
  end
end
