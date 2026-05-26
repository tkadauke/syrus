module Filters
  module Chips
    module Jobs
      class LatestWorkflowTriggerKind < Base
        filter_name "latest_workflow_trigger_kind"
        label "Latest workflow trigger"
        bucket :enum
        operators :is, :is_not, :is_one_of, :is_none_of
        values "initial", "pr_comment", "ci_failure", "retry", "rebase", "manual", "replay"

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

        def latest_job_ids(kinds)
          Workflow.where(trigger_kind: kinds)
                  .where(<<~SQL.squish)
                    workflows.id = (
                      SELECT latest_workflows.id FROM workflows latest_workflows
                      WHERE latest_workflows.job_id = workflows.job_id
                      ORDER BY latest_workflows.created_at DESC, latest_workflows.id DESC
                      LIMIT 1
                    )
                  SQL
                  .select(:job_id)
        end
      end
    end
  end
end
