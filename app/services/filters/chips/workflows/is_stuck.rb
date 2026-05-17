module Filters
  module Chips
    module Workflows
      class IsStuck < Base
        filter_name "is_stuck"
        label "Is stuck"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          stuck_ids = scope.model.where(state: "running")
                           .where(id: stale_latest_run_workflow_ids)
                           .select(:id)

          case op
          when :is_true  then scope.where(id: stuck_ids)
          when :is_false then scope.where.not(id: stuck_ids)
          else unsupported_op!
          end
        end

        private

        def stale_latest_run_workflow_ids
          cutoff = Run::STALE_HEARTBEAT_THRESHOLD.ago
          Run.joins(:step)
             .where("runs.last_heartbeat_at < ?", cutoff)
             .where(<<~SQL.squish)
               runs.id = (
                 SELECT latest_runs.id FROM runs latest_runs
                 INNER JOIN steps latest_steps ON latest_steps.id = latest_runs.step_id
                 WHERE latest_steps.workflow_id = steps.workflow_id
                 ORDER BY latest_runs.created_at DESC, latest_runs.id DESC
                 LIMIT 1
               )
             SQL
             .select("steps.workflow_id")
        end
      end
    end
  end
end
