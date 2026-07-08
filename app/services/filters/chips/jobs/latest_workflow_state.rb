module Filters
  module Chips
    module Jobs
      # State of the Workflow that's currently the latest one on each
      # Job — used by the legacy state=failed/succeeded URL semantics
      # (which were sugar for "open AND latest workflow is failed").
      # The "latest workflow per job" subquery is the same pattern
      # Filters::Chips::Jobs::Attention uses for its presets.
      class LatestWorkflowState < Base
        filter_name "latest_workflow_state"
        label "Latest workflow state"
        bucket :enum
        operators :is, :is_not, :is_one_of, :is_none_of
        values "queued", "running", "succeeded", "failed", "cancelled"

        def apply
          case op
          when :is        then scope.where(id: latest_workflow_job_ids(Array(value)))
          when :is_not    then scope.where.not(id: latest_workflow_job_ids(Array(value)))
          when :is_one_of then scope.where(id: latest_workflow_job_ids(Array(value)))
          when :is_none_of then scope.where.not(id: latest_workflow_job_ids(Array(value)))
          else unsupported_op!
          end
        end

        private

        def latest_workflow_job_ids(states)
          Workflow.where(state: states)
                  .where(<<~SQL.squish)
                    workflows.id = (
                      SELECT latest_workflows.id FROM workflows latest_workflows
                      WHERE latest_workflows.job_id = workflows.job_id
                      ORDER BY (latest_workflows.finished_at IS NULL) DESC, latest_workflows.finished_at DESC, latest_workflows.id DESC
                      LIMIT 1
                    )
                  SQL
                  .select(:job_id)
        end
      end
    end
  end
end
