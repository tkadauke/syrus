module Filters
  module Chips
    module Jobs
      class LatestWorkflowTriggerKind < Base
        filter_name "latest_workflow_trigger_kind"
        label "Latest workflow trigger"
        bucket :enum
        operators :is, :is_not, :is_one_of, :is_none_of
        # Read the registry on every call so every registered trigger kind is
        # selectable. A hardcoded list once omitted half the kinds, and a
        # load-time copy kept a disabled plugin's kinds and missed ones
        # registered later.
        def self.values(*list)
          return super if list.any?

          Workflow::TriggerKind.values
        end

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
