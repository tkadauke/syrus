class CreateWorkflowArtifactValues < ActiveRecord::Migration[8.1]
  EXTERNALIZED_KEYS = %w[
    adversarial_review_iterations
    iterations
    typed_artifacts
    visual_review_iterations
  ].freeze

  class MigrationWorkflow < ActiveRecord::Base
    self.table_name = "workflows"
  end

  class MigrationArtifactValue < ActiveRecord::Base
    self.table_name = "workflow_artifact_values"
  end

  def up
    unless table_exists?(:workflow_artifact_values)
      create_table :workflow_artifact_values do |t|
        t.references :workflow, null: false, foreign_key: { on_delete: :cascade }
        t.string :key, null: false
        t.text :value, limit: 16.megabytes - 1, null: false
        t.timestamps
      end
    end
    unless index_exists?(:workflow_artifact_values, [ :workflow_id, :key ], unique: true)
      add_index :workflow_artifact_values, [ :workflow_id, :key ], unique: true
    end

    backfill_artifacts
  end

  def backfill_artifacts
    MigrationWorkflow.reset_column_information
    MigrationArtifactValue.reset_column_information
    MigrationWorkflow.where.not(artifacts: [ nil, "", "{}" ]).find_each do |workflow|
      artifacts = parse_json(workflow.artifacts)
      external = artifacts.slice(*EXTERNALIZED_KEYS)
      next if external.empty?

      now = Time.current
      external.each do |key, value|
        entry = MigrationArtifactValue.find_or_initialize_by(workflow_id: workflow.id, key: key)
        entry.update!(value: JSON.generate(value), created_at: entry.created_at || now, updated_at: now)
      end
    end
  end

  def down
    return unless table_exists?(:workflow_artifact_values)

    MigrationArtifactValue.find_each do |artifact_value|
      workflow = MigrationWorkflow.find_by(id: artifact_value.workflow_id)
      next unless workflow

      artifacts = parse_json(workflow.artifacts)
      artifacts[artifact_value.key] = parse_json(artifact_value.value)
      workflow.update_columns(artifacts: JSON.generate(artifacts))
    end
    drop_table :workflow_artifact_values
  end

  private

  def parse_json(value)
    value.is_a?(String) ? JSON.parse(value) : value.to_h
  end
end
