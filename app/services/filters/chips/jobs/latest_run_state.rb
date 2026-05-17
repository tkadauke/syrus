module Filters
  module Chips
    module Jobs
      # State of the latest Run on each Job — answers "is something
      # going wrong / has it just succeeded / is awaiting me?" The
      # subquery picks the most recent run per job; same shape
      # LatestWorkflowState uses.
      class LatestRunState < Base
        filter_name "latest_run_state"
        label "Latest run state"
        bucket :enum
        operators :is, :is_not, :is_one_of, :is_none_of
        values "queued", "running", "succeeded", "failed", "cancelled", "awaiting_operator"

        def apply
          case op
          when :is        then scope.where(id: latest_job_ids(Array(value)))
          when :is_one_of then scope.where(id: latest_job_ids(Array(value)))
          when :is_not    then scope.where.not(id: latest_job_ids(Array(value)))
          when :is_none_of then scope.where.not(id: latest_job_ids(Array(value)))
          else unsupported_op!
          end
        end

        private

        def latest_job_ids(states)
          Run.where(state: states)
             .where(<<~SQL.squish)
               runs.id = (
                 SELECT latest_runs.id FROM runs latest_runs
                 WHERE latest_runs.job_id = runs.job_id
                 ORDER BY latest_runs.created_at DESC, latest_runs.id DESC
                 LIMIT 1
               )
             SQL
             .select(:job_id)
        end
      end
    end
  end
end
