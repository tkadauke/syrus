class RetireCiFailureWorkflows < ActiveRecord::Migration[8.1]
  class MigrationWorkflow < ActiveRecord::Base
    self.table_name = "workflows"

    has_many :migration_steps, class_name: "RetireCiFailureWorkflows::MigrationStep", foreign_key: :workflow_id
  end

  class MigrationStep < ActiveRecord::Base
    self.table_name = "steps"

    belongs_to :migration_workflow, class_name: "RetireCiFailureWorkflows::MigrationWorkflow", foreign_key: :workflow_id
    has_many :migration_runs, class_name: "RetireCiFailureWorkflows::MigrationRun", foreign_key: :step_id
  end

  class MigrationRun < ActiveRecord::Base
    self.table_name = "runs"
  end

  REASON = "superseded_by_grade".freeze

  def up
    now = Time.current

    MigrationWorkflow.where(trigger_kind: "ci_failure", state: %w[ queued running ]).find_each do |workflow|
      workflow.transaction do
        workflow.migration_steps.where(state: %w[ queued running ]).find_each do |step|
          step.migration_runs.where(state: %w[ queued running awaiting_operator ]).update_all(
            state: "cancelled",
            finished_at: now,
            updated_at: now
          )

          step.update!(
            state: "cancelled",
            finished_at: now
          )
        end

        workflow.update!(
          state: "cancelled",
          finished_at: now,
          artifacts: artifacts_with_reason(workflow.artifacts)
        )
      end
    end
  end

  def down
    # Historical ci_failure rows are intentionally left as-is.
  end

  private

  def artifacts_with_reason(raw)
    artifacts =
      if raw.present?
        JSON.parse(raw)
      else
        {}
      end

    artifacts.merge("cancellation_reason" => REASON).to_json
  rescue JSON::ParserError
    { "cancellation_reason" => REASON }.to_json
  end
end
