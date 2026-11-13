class BackfillRemainingInlineWorkflowArtifacts < ActiveRecord::Migration[8.1]
  BATCH_SIZE = 200

  class MigrationArtifactValue < ActiveRecord::Base
    self.table_name = "workflow_artifact_values"
  end

  # Copies inline `workflows.artifacts` values that are missing from
  # `workflow_artifact_values`, so the column can be dropped afterwards.
  # Existing side-table rows win: every write since the externalization has
  # gone there, so they are newer than any inline value. Idempotent, and a
  # no-op once the column is gone.
  def up
    return unless column_exists?(:workflows, :artifacts)

    MigrationArtifactValue.reset_column_information
    last_id = 0
    loop do
      # Only rows that still have something to copy are selected, and the
      # (potentially huge) inline column is only read for those rows.
      ids = select_values(<<~SQL.squish)
        SELECT id FROM workflows
        WHERE id > #{last_id} AND artifacts IS NOT NULL AND artifacts NOT IN ('', '{}', 'null')
        ORDER BY id LIMIT #{BATCH_SIZE}
      SQL
      break if ids.empty?

      ids.each { |id| backfill_workflow(id.to_i) }
      last_id = ids.last.to_i
    end
  end

  def down
    # Irreversible by design: the data remains in workflow_artifact_values.
  end

  private

  def backfill_workflow(id)
    raw = select_value("SELECT artifacts FROM workflows WHERE id = #{id}")
    inline = raw.is_a?(String) ? JSON.parse(raw) : raw
    return unless inline.is_a?(Hash) && inline.any?

    existing = MigrationArtifactValue.where(workflow_id: id).pluck(:key)
    now = Time.current
    (inline.keys - existing).each do |key|
      MigrationArtifactValue.create!(workflow_id: id, key: key, value: JSON.generate(inline[key]), created_at: now, updated_at: now)
    rescue ActiveRecord::RecordNotUnique
      next # written concurrently; the side-table value wins
    end
  rescue JSON::ParserError
    nil
  end
end
