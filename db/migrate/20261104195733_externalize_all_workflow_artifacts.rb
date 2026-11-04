class ExternalizeAllWorkflowArtifacts < ActiveRecord::Migration[8.1]
  class MigrationWorkflow < ActiveRecord::Base
    self.table_name = "workflows"
  end

  class MigrationArtifactValue < ActiveRecord::Base
    self.table_name = "workflow_artifact_values"
  end

  def up
    MigrationWorkflow.reset_column_information
    MigrationArtifactValue.reset_column_information

    MigrationWorkflow.where.not(artifacts: [ nil, "", "{}" ]).find_each do |workflow|
      artifacts = parse_json(workflow.artifacts)
      next if artifacts.empty?

      MigrationWorkflow.transaction do
        now = Time.current
        artifacts.each do |key, value|
          entry = MigrationArtifactValue.find_or_initialize_by(workflow_id: workflow.id, key: key)
          next unless entry.new_record?

          entry.update!(value: JSON.generate(value), created_at: now, updated_at: now)
        end
        workflow.update_columns(artifacts: JSON.generate({}))
      end
    end
  end

  def down
    MigrationWorkflow.reset_column_information
    MigrationArtifactValue.reset_column_information

    MigrationWorkflow.find_each do |workflow|
      external = MigrationArtifactValue.where(workflow_id: workflow.id).to_h do |entry|
        [ entry.key, parse_json(entry.value) ]
      end
      next if external.empty?

      inline = parse_json(workflow.artifacts)
      workflow.update_columns(artifacts: JSON.generate(inline.merge(external)))
    end
  end

  private

  def parse_json(value)
    value.is_a?(String) ? JSON.parse(value) : value.to_h
  end
end
